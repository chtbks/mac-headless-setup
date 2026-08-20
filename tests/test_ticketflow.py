#!/usr/bin/env python3

import argparse
import importlib.machinery
import importlib.util
import json
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
        self.labels = {"MEMS-123": [ticketflow.TRIGGER_LABEL]}
        self.acknowledgments = 0
        self.partial_ack_failures = 0
        self.comments = []

    def search_triggered(self):
        return [
            {"key": key, "fields": {"labels": labels}}
            for key, labels in self.labels.items()
            if ticketflow.TRIGGER_LABEL in labels
        ]

    def get_issue(self, ticket_key):
        return {"key": ticket_key, "fields": {"labels": self.labels[ticket_key]}}

    def acknowledge_launch(self, ticket_key, session_name):
        self.acknowledgments += 1
        labels = self.labels[ticket_key]
        if ticketflow.TRIGGER_LABEL in labels:
            labels.remove(ticketflow.TRIGGER_LABEL)
        if ticketflow.STARTED_LABEL not in labels:
            labels.append(ticketflow.STARTED_LABEL)
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

    def launch(self, project, display_name, prompt_path):
        self.calls.append((project, display_name, prompt_path.read_text()))
        if self.failures:
            self.failures -= 1
            raise ticketflow.TicketflowError("launcher token=should-not-leak")
        return {
            "status": "running",
            "agent": "claude",
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
    def test_normalizes_key_and_url_and_rejects_unmapped_projects(self):
        self.assertEqual(ticketflow.normalize_ticket("mems-123"), "MEMS-123")
        self.assertEqual(
            ticketflow.normalize_ticket(
                "https://chatbookstown.atlassian.net/browse/MEMS-123?focusedCommentId=1"
            ),
            "MEMS-123",
        )
        with self.assertRaises(ticketflow.TicketflowError):
            ticketflow.normalize_ticket("OTHER-1")

    def test_manual_and_automatic_prompts_route_to_distinct_flows(self):
        manual = ticketflow.build_prompt(self.settings, "MEMS-123", "manual")
        automatic = ticketflow.build_prompt(self.settings, "MEMS-123", "auto")
        self.assertIn("/cb-all", manual)
        self.assertNotIn("/cb-auto-ticket", manual)
        self.assertIn("/cb-auto-ticket", automatic)
        self.assertIn("same remote session", automatic)
        self.assertIn("Never run /cb-cleanup", manual)

    def test_manual_dry_run_does_not_create_state(self):
        args = argparse.Namespace(ticket="MEMS-123", dry_run=True)
        with mock.patch("builtins.print"):
            ticketflow.command_start(args, self.settings)
        self.assertFalse(self.settings.database_path.exists())

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
        self.assertIn("labels = \"agent-dev\"", requests[0][2]["jql"])
        self.assertEqual(requests[1][2]["nextPageToken"], "next")

    def test_jira_acknowledgment_consumes_trigger_label_idempotently(self):
        client = ticketflow.JiraClient("https://example.atlassian.net", "email", "token")
        requests = []
        labels = [ticketflow.TRIGGER_LABEL]

        def request(method, path, body=None):
            requests.append((method, path, body))
            if method == "GET":
                return {"fields": {"labels": list(labels)}}
            if method == "PUT":
                labels.remove(ticketflow.TRIGGER_LABEL)
                labels.append(ticketflow.STARTED_LABEL)
            return None

        client._request = request
        client.acknowledge_launch("MEMS-123", "MEMS-123")
        client.acknowledge_launch("MEMS-123", "MEMS-123")

        puts = [body for method, _, body in requests if method == "PUT"]
        self.assertEqual(len(puts), 1)
        self.assertEqual(
            puts[0]["update"]["labels"],
            [{"remove": "agent-dev"}, {"add": "agent-dev-started"}],
        )


class PollIntegrationTests(TicketflowTestCase):
    def test_new_label_launches_and_acknowledges_exactly_once(self):
        jira = FakeJira()
        launcher = FakeLauncher()
        self.run_poll(jira, launcher)
        self.run_poll(jira, launcher)

        self.assertEqual(len(launcher.calls), 1)
        self.assertEqual(self.latest()["state"], "acknowledged")
        self.assertNotIn(ticketflow.TRIGGER_LABEL, jira.labels["MEMS-123"])
        self.assertIn(ticketflow.STARTED_LABEL, jira.labels["MEMS-123"])

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
        run = store.create_run("MEMS-123", "jira-poller", "auto")
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
        jira.labels["MEMS-123"].append(ticketflow.TRIGGER_LABEL)
        self.run_poll(jira, launcher)

        rows = ticketflow.Store(self.settings.database_path).list_runs("MEMS-123")
        self.assertEqual(len(launcher.calls), 2)
        self.assertEqual(len(rows), 2)
        self.assertTrue(all(row["state"] == "acknowledged" for row in rows))

    def test_retry_resets_only_terminal_automatic_run(self):
        store = ticketflow.Store(self.settings.database_path)
        run = store.create_run("MEMS-123", "jira-poller", "auto")
        store.update(run["id"], state="failed", attempt_count=4, last_error="nope")
        args = argparse.Namespace(ticket="MEMS-123")
        with mock.patch("builtins.print"):
            ticketflow.command_retry(args, self.settings)
        reset = self.latest()
        self.assertEqual(reset["state"], "retrying")
        self.assertEqual(reset["attempt_count"], 0)


if __name__ == "__main__":
    unittest.main()
