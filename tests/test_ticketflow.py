#!/usr/bin/env python3

import argparse
import importlib.machinery
import importlib.util
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "bin" / "ticketflow"
loader = importlib.machinery.SourceFileLoader("ticketflow", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
ticketflow = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = ticketflow
loader.exec_module(ticketflow)


class FakeJira:
    def __init__(self):
        self.project = "chatty-family"
        self.labels = {"MEMS-123": [ticketflow.trigger_label(self.project)]}
        self.acknowledgments = 0
        self.partial_ack_failures = 0
        self.comments = []

    def search_triggered(self):
        return [
            {"key": key, "fields": {"labels": labels}}
            for key, labels in self.labels.items()
            if any(label in ticketflow.LABEL_PROJECTS for label in labels)
        ]

    def get_issue(self, ticket_key):
        return {"key": ticket_key, "fields": {"labels": self.labels[ticket_key]}}

    def acknowledge_launch(self, ticket_key, session_name, project, agent):
        self.acknowledgments += 1
        labels = self.labels[ticket_key]
        watched_label = ticketflow.trigger_label(project)
        launched_label = ticketflow.started_label(project)
        if watched_label in labels:
            labels.remove(watched_label)
        if launched_label not in labels:
            labels.append(launched_label)
        if self.partial_ack_failures:
            self.partial_ack_failures -= 1
            raise ticketflow.TicketflowError("comment request failed")
        self.comments.append((ticket_key, session_name))

    def add_comment(self, ticket_key, text):
        self.comments.append((ticket_key, text))


class FakeLauncher:
    def __init__(self, failures=0):
        self.failures = failures
        self.calls = []

    def launch(self, project, display_name, prompt_path, agent="claude"):
        self.calls.append((project, agent, display_name, prompt_path.read_text()))
        if self.failures:
            self.failures -= 1
            raise ticketflow.TicketflowError("launcher token=should-not-leak")
        return {
            "status": "running",
            "agent": agent,
            "display_name": display_name,
            "tmux_session": f"claude-{display_name}",
            "worktree": "managed-by-claude",
        }


class TicketflowTestCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        workspace = root / "workspace"
        (workspace / "chatty-family").mkdir(parents=True)
        launcher_path = root / "spawn-session.sh"
        launcher_path.touch(mode=0o700)
        self.settings = ticketflow.Settings(
            home=root,
            workspace=workspace,
            state_dir=root / "state",
            database_path=root / "state" / "ticketflow.sqlite3",
            prompt_dir=root / "state" / "prompts",
            jira_base_url="https://chatbookstown.atlassian.net",
            jira_email="qa@example.com",
            jira_api_token="secret",
            launcher_path=launcher_path,
        )
        self.poll_args = argparse.Namespace(once=True, dry_run=False)

    def tearDown(self):
        self.temporary.cleanup()

    def run_poll(self, jira, launcher):
        with (
            mock.patch.object(ticketflow, "JiraClient", return_value=jira),
            mock.patch.object(ticketflow, "Launcher", return_value=launcher),
        ):
            self.assertEqual(ticketflow.command_poll(self.poll_args, self.settings), 0)

    def latest(self):
        return ticketflow.Store(self.settings.database_path).latest_auto("MEMS-123")


class NormalizationAndPromptTests(TicketflowTestCase):
    def test_normalizes_any_key_but_manual_mapping_supports_known_projects(self):
        self.assertEqual(ticketflow.normalize_ticket("mems-123"), "MEMS-123")
        self.assertEqual(
            ticketflow.normalize_ticket(
                "https://chatbookstown.atlassian.net/browse/MEMS-123?focusedCommentId=1"
            ),
            "MEMS-123",
        )
        self.assertEqual(ticketflow.normalize_ticket("other-1"), "OTHER-1")
        self.assertEqual(ticketflow.project_for_ticket("MEMS-123"), "chatty-family")
        self.assertEqual(ticketflow.project_for_ticket("IOSP-123"), "iphone")
        self.assertEqual(ticketflow.project_for_ticket("FC-123"), "fluttershy")
        self.assertEqual(ticketflow.project_for_ticket("COR-123"), "backend")
        with self.assertRaises(ticketflow.TicketflowError):
            ticketflow.project_for_ticket("OTHER-1")

    def test_watched_label_selects_project_independent_of_ticket_key(self):
        for project, label in ticketflow.PROJECT_LABELS.items():
            issue = {"key": "ANY-1", "fields": {"labels": [label]}}
            self.assertEqual(ticketflow.project_for_issue(issue), project)
        issue = {"key": "ANY-1", "fields": {"labels": ["josh-artemis"]}}
        issue["fields"]["labels"].append("josh-backend")
        with self.assertRaises(ticketflow.TicketflowError):
            ticketflow.project_for_issue(issue)

    def test_agent_label_selects_agent_and_defaults_to_claude(self):
        self.assertEqual(
            ticketflow.agent_for_issue({"fields": {"labels": ["josh-backend"]}}),
            "claude",
        )
        for agent in ("claude", "cursor", "codex"):
            issue = {"fields": {"labels": ["josh-backend", agent]}}
            self.assertEqual(ticketflow.agent_for_issue(issue), agent)
        with self.assertRaises(ticketflow.TicketflowError):
            ticketflow.agent_for_issue(
                {"key": "ANY-1", "fields": {"labels": ["cursor", "codex"]}}
            )

    def test_manual_and_automatic_prompts_route_to_distinct_flows(self):
        manual = ticketflow.build_prompt(self.settings, "MEMS-123", "manual")
        automatic = ticketflow.build_prompt(self.settings, "MEMS-123", "auto")
        self.assertIn("/cb-all", manual)
        self.assertNotIn("/cb-auto-ticket", manual)
        self.assertIn("/cb-auto-ticket", automatic)
        self.assertIn("/caveman full", automatic)
        self.assertIn("Never run /cb-cleanup", manual)

    def test_manual_dry_run_does_not_create_state(self):
        args = argparse.Namespace(ticket="MEMS-123", dry_run=True, agent="claude")
        with mock.patch("builtins.print"):
            ticketflow.command_start(args, self.settings)
        self.assertFalse(self.settings.database_path.exists())

    def test_launcher_passes_selected_agent_to_spawn_session(self):
        prompt = self.settings.state_dir / "prompt.txt"
        prompt.parent.mkdir(parents=True)
        prompt.write_text("work\n")
        completed = mock.Mock(
            returncode=0,
            stderr="",
            stdout=json.dumps(
                {
                    "status": "running",
                    "agent": "cursor",
                    "display_name": "COR-1",
                }
            ),
        )

        with mock.patch.object(ticketflow.subprocess, "run", return_value=completed) as run:
            ticketflow.Launcher(
                self.settings.launcher_path, self.settings.workspace
            ).launch("backend", "COR-1", prompt, "cursor")

        command = run.call_args.args[0]
        self.assertEqual(command[1:3], ["--agent", "cursor"])
        self.assertEqual(command[-2:], ["backend", "COR-1"])

    def test_jql_uses_enhanced_search_and_ten_item_pages(self):
        client = ticketflow.JiraClient("https://example.atlassian.net", "email", "token")
        requests = []

        def request(method, path, body=None):
            requests.append((method, path, body))
            if len(requests) == 1:
                return {"issues": [{"key": "MEMS-1"}], "nextPageToken": "next"}
            return {"issues": [{"key": "MEMS-2"}]}

        client._request = request
        self.assertEqual([issue["key"] for issue in client.search_triggered()], ["MEMS-1", "MEMS-2"])
        self.assertTrue(all(path == "/rest/api/3/search/jql" for _, path, _ in requests))
        self.assertTrue(all(body["maxResults"] == 10 for _, _, body in requests))
        jql = requests[0][2]["jql"]
        self.assertNotIn("project =", jql)
        for label in ticketflow.LABEL_PROJECTS:
            self.assertIn(f'"{label}"', jql)
        self.assertEqual(requests[1][2]["nextPageToken"], "next")

    def test_jira_acknowledgment_consumes_trigger_label_idempotently(self):
        client = ticketflow.JiraClient("https://example.atlassian.net", "email", "token")
        requests = []
        project = "iphone"
        labels = [ticketflow.trigger_label(project)]

        def request(method, path, body=None):
            requests.append((method, path, body))
            if method == "GET":
                return {"fields": {"labels": list(labels)}}
            if method == "PUT":
                labels.remove(ticketflow.trigger_label(project))
                labels.append(ticketflow.started_label(project))
            return None

        client._request = request
        client.acknowledge_launch("IOSP-123", "IOSP-123", project, "cursor")
        client.acknowledge_launch("IOSP-123", "IOSP-123", project, "cursor")

        puts = [body for method, _, body in requests if method == "PUT"]
        self.assertEqual(len(puts), 1)
        self.assertEqual(
            puts[0]["update"]["labels"],
            [{"remove": "josh-iphone"}, {"add": "josh-iphone-started"}],
        )
        comments = [body for method, _, body in requests if method == "POST"]
        self.assertIn("cursor session", comments[0]["body"]["content"][0]["content"][0]["text"])


class PollIntegrationTests(TicketflowTestCase):
    def test_label_selects_launcher_project_independent_of_ticket_key(self):
        jira = FakeJira()
        jira.project = "artemis"
        jira.labels = {"MISC-42": [ticketflow.trigger_label(jira.project)]}
        launcher = FakeLauncher()

        self.run_poll(jira, launcher)

        self.assertEqual(launcher.calls[0][0], "artemis")
        run = ticketflow.Store(self.settings.database_path).latest_auto("MISC-42")
        self.assertEqual(run["project"], "artemis")

    def test_agent_label_selects_launcher_and_persists_for_retries(self):
        jira = FakeJira()
        jira.labels["MEMS-123"].append("codex")
        launcher = FakeLauncher(failures=1)

        self.run_poll(jira, launcher)
        run = self.latest()
        self.assertEqual(run["agent"], "codex")
        self.assertEqual(launcher.calls[0][1], "codex")

        jira.labels["MEMS-123"].remove("codex")
        ticketflow.Store(self.settings.database_path).update(run["id"], next_attempt_at=0)
        self.run_poll(jira, launcher)

        self.assertEqual(launcher.calls[1][1], "codex")

    def test_new_label_launches_and_acknowledges_exactly_once(self):
        jira = FakeJira()
        launcher = FakeLauncher()
        self.run_poll(jira, launcher)
        self.run_poll(jira, launcher)

        self.assertEqual(len(launcher.calls), 1)
        self.assertEqual(self.latest()["state"], "acknowledged")
        self.assertNotIn(ticketflow.trigger_label(jira.project), jira.labels["MEMS-123"])
        self.assertIn(ticketflow.started_label(jira.project), jira.labels["MEMS-123"])

    def test_acknowledgment_failure_never_duplicates_launch(self):
        jira = FakeJira()
        jira.partial_ack_failures = 1
        launcher = FakeLauncher()
        self.run_poll(jira, launcher)
        self.assertEqual(self.latest()["state"], "launched")

        ticketflow.Store(self.settings.database_path).update(
            self.latest()["id"], next_attempt_at=0
        )
        self.run_poll(jira, launcher)

        self.assertEqual(len(launcher.calls), 1)
        self.assertEqual(jira.acknowledgments, 2)
        self.assertEqual(self.latest()["state"], "acknowledged")

    def test_launch_failures_retry_then_require_manual_retry(self):
        jira = FakeJira()
        launcher = FakeLauncher(failures=10)
        for attempt in range(4):
            self.run_poll(jira, launcher)
            run = self.latest()
            if attempt < 3:
                self.assertEqual(run["state"], "retrying")
                ticketflow.Store(self.settings.database_path).update(
                    run["id"], next_attempt_at=0
                )

        run = self.latest()
        self.assertEqual(len(launcher.calls), 4)
        self.assertEqual(run["state"], "failed")
        self.assertEqual(run["attempt_count"], 4)
        self.assertEqual(run["failure_reported"], 1)
        self.assertIn("token=<redacted>", run["last_error"])
        self.assertEqual(len(jira.comments), 1)

    def test_retry_schedule_is_one_five_and_fifteen_minutes(self):
        store = ticketflow.Store(self.settings.database_path)
        run = store.create_run("MEMS-123", "jira-poller", "auto", "chatty-family")
        launcher = FakeLauncher(failures=10)
        with mock.patch.object(ticketflow, "now_epoch", return_value=1_000):
            expected_times = [1_060, 1_300, 1_900]
            for expected in expected_times:
                run = ticketflow.launch_run(self.settings, store, launcher, run)
                self.assertEqual(run["state"], "retrying")
                self.assertEqual(run["next_attempt_at"], expected)
                run = store.update(run["id"], next_attempt_at=0)

    def test_readding_consumed_label_creates_a_new_run(self):
        jira = FakeJira()
        launcher = FakeLauncher()
        self.run_poll(jira, launcher)
        jira.labels["MEMS-123"].append(ticketflow.trigger_label(jira.project))
        self.run_poll(jira, launcher)

        rows = ticketflow.Store(self.settings.database_path).list_runs("MEMS-123")
        self.assertEqual(len(launcher.calls), 2)
        self.assertEqual(len(rows), 2)
        self.assertTrue(all(row["state"] == "acknowledged" for row in rows))

    def test_retry_resets_only_terminal_automatic_run(self):
        store = ticketflow.Store(self.settings.database_path)
        run = store.create_run("MEMS-123", "jira-poller", "auto", "chatty-family")
        store.update(run["id"], state="failed", attempt_count=4, last_error="nope")
        args = argparse.Namespace(ticket="MEMS-123")
        with mock.patch("builtins.print"):
            ticketflow.command_retry(args, self.settings)
        reset = self.latest()
        self.assertEqual(reset["state"], "retrying")
        self.assertEqual(reset["attempt_count"], 0)

    def test_existing_database_is_migrated_with_repository_mapping(self):
        database = self.settings.database_path
        database.parent.mkdir(parents=True)
        connection = sqlite3.connect(database)
        connection.executescript(
            """
            CREATE TABLE runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ticket_key TEXT NOT NULL,
                source TEXT NOT NULL,
                mode TEXT NOT NULL,
                state TEXT NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                next_attempt_at INTEGER,
                display_name TEXT NOT NULL,
                prompt_path TEXT,
                session_json TEXT,
                last_error TEXT,
                failure_reported INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            INSERT INTO runs (
                ticket_key, source, mode, state, display_name, created_at, updated_at
            ) VALUES ('MEMS-9', 'jira-poller', 'auto', 'failed', 'MEMS-9', 1, 1);
            """
        )
        connection.close()

        run = ticketflow.Store(database).latest_auto("MEMS-9")

        self.assertEqual(run["project"], "chatty-family")
        self.assertEqual(run["agent"], "claude")


if __name__ == "__main__":
    unittest.main()
