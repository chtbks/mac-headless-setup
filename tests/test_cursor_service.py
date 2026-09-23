"""Check Cursor startup, identity, and repo scope without touching launchd."""

import importlib.machinery
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[1] / "bin/install-cursor-service"
loader = importlib.machinery.SourceFileLoader("cursor_service", str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
service = importlib.util.module_from_spec(spec)
loader.exec_module(service)


class CursorServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.user_home = Path(self.temp.name) / "QA & Test"
        self.roots = [self.user_home / "repo one", self.user_home / "repo two"]
        for root in self.roots:
            root.mkdir(parents=True)
        self.binary = self.user_home / "cursor-agent"
        self.binary.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        self.binary.chmod(0o755)
        self.calls = []
        self.loaded = False

    def launchctl(self, argv, **kwargs):
        self.calls.append(argv[1:])
        if argv[1] == "bootstrap":
            self.loaded = True
        elif argv[1] == "bootout":
            self.loaded = False
        code = 1 if argv[1] == "print" and not self.loaded else 0
        return subprocess.CompletedProcess(argv, code, stdout="", stderr="")

    def install(self, roots=None):
        with patch.object(service.subprocess, "run", side_effect=self.launchctl):
            return service.install(self.user_home, self.binary, "QA & Cursor", self.roots if roots is None else roots)

    def test_long_running_worker_has_restart_policy_and_exact_roots(self):
        destination = self.install()
        job = plistlib.loads(destination.read_bytes())
        self.assertTrue(job["RunAtLoad"])
        self.assertIs(job["KeepAlive"], True)  # Includes normal idle exit code 0.
        self.assertEqual(job["ThrottleInterval"], 30)
        self.assertNotIn("AbandonProcessGroup", job)
        self.assertNotIn("StartInterval", job)
        result = subprocess.run(job["ProgramArguments"], check=True, capture_output=True, text=True)
        self.assertEqual(result.stdout.splitlines(), [
            "worker", "--name", "QA & Cursor", "--data-dir",
            str(self.user_home / ".local/share/cursor-agent/macsetup-worker"),
            "--worker-dir", str(self.roots[0]), "--worker-dir", str(self.roots[1]), "start",
        ])
        self.assertEqual(job["WorkingDirectory"], str(self.roots[0]))
        self.assertEqual(job["EnvironmentVariables"]["HOME"], str(self.user_home))
        self.assertTrue(job["EnvironmentVariables"]["CURSOR_AGENT_WORKER_ID"])
        self.assertEqual(destination.stat().st_mode & 0o777, 0o600)

    def test_rerun_preserves_identity_and_live_process(self):
        destination = self.install()
        original = destination.read_bytes()
        self.calls.clear()
        self.install()
        self.assertEqual(destination.read_bytes(), original)
        self.assertEqual([call[0] for call in self.calls], ["print", "enable", "kickstart"])
        self.assertFalse(any("-k" in call for call in self.calls))

    def test_scope_change_reloads_but_keeps_identity(self):
        destination = self.install()
        first = plistlib.loads(destination.read_bytes())["EnvironmentVariables"]["CURSOR_AGENT_WORKER_ID"]
        self.calls.clear()
        self.install(self.roots[:1])
        new = plistlib.loads(destination.read_bytes())
        self.assertEqual(new["EnvironmentVariables"]["CURSOR_AGENT_WORKER_ID"], first)
        self.assertNotIn(str(self.roots[1]), new["ProgramArguments"])
        self.assertEqual([call[0] for call in self.calls], ["print", "enable", "bootout", "bootstrap"])

    def test_invalid_scope_does_not_install_or_load(self):
        for roots in [[], [self.user_home / "missing"]]:
            with self.assertRaises(ValueError):
                self.install(roots)
        self.assertEqual(self.calls, [])
        self.assertFalse((self.user_home / "Library/LaunchAgents").exists())

    def test_launchd_failure_is_reported(self):
        def fail(argv, **kwargs):
            if argv[1] == "bootstrap":
                raise subprocess.CalledProcessError(5, argv)
            return self.launchctl(argv, **kwargs)

        with patch.object(service.subprocess, "run", side_effect=fail):
            with self.assertRaises(subprocess.CalledProcessError):
                service.install(self.user_home, self.binary, "QA", self.roots)

    def test_independent_workers_preserve_original_and_their_own_identities(self):
        original = self.install()
        before = original.read_bytes()
        paths = []
        with patch.object(service.subprocess, "run", side_effect=self.launchctl):
            for index, service_id in enumerate(["iphone", "chatty-family"]):
                path = service.install(self.user_home, self.binary, service_id,
                                       [self.roots[index]], service_id)
                contents = path.read_bytes()
                service.install(self.user_home, self.binary, service_id,
                                [self.roots[index]], service_id)
                self.assertEqual(path.read_bytes(), contents)
                job = plistlib.loads(contents)
                self.assertEqual(job["WorkingDirectory"], str(self.roots[index]))
                self.assertEqual(job["ProgramArguments"].count("--worker-dir"), 1)
                paths.append(path)
        self.assertEqual(original.read_bytes(), before)
        jobs = [plistlib.loads(p.read_bytes()) for p in [original, *paths]]
        for key in ["Label", "StandardOutPath", "StandardErrorPath"]:
            self.assertEqual(len({job[key] for job in jobs}), 3)
        self.assertEqual(len({job["EnvironmentVariables"]["CURSOR_AGENT_WORKER_ID"] for job in jobs}), 3)
        self.assertEqual(len({job["ProgramArguments"][5] for job in jobs}), 3)

    def test_service_id_cannot_escape_its_directory(self):
        for service_id in ["../bad", "", "bad/name"]:
            with self.assertRaises(ValueError):
                service.install(self.user_home, self.binary, "QA", self.roots, service_id)


if __name__ == "__main__":
    unittest.main()
