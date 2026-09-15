"""Verify the installed startup job, without changing the real login session."""

import importlib.machinery
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[1] / "bin/install-codex-service"
loader = importlib.machinery.SourceFileLoader("codex_service", str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
service = importlib.util.module_from_spec(spec)
loader.exec_module(service)


class CodexServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.user_home = Path(self.temp.name) / "QA & Test"
        self.user_home.mkdir()
        self.codex_home = self.user_home / ".codex"
        self.codex = self.user_home / "codex"
        self.codex.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        self.codex.chmod(0o755)
        self.loaded = False
        self.calls = []

    def launchctl(self, argv, **kwargs):
        self.calls.append(argv[1:])
        action = argv[1]
        if action == "bootstrap":
            self.loaded = True
        elif action == "bootout":
            self.loaded = False
        code = 1 if action == "print" and not self.loaded else 0
        return subprocess.CompletedProcess(argv, code, stdout="", stderr="")

    def install(self):
        with patch.object(service.subprocess, "run", side_effect=self.launchctl):
            return service.install(self.user_home, self.codex_home, self.codex)

    def test_startup_job_can_run_without_a_shell_or_repo(self):
        plist_path = self.install()
        with plist_path.open("rb") as stream:
            job = plistlib.load(stream)
        self.assertTrue(job["RunAtLoad"])
        self.assertEqual(job["StartInterval"], 60)
        self.assertTrue(job["AbandonProcessGroup"])
        self.assertNotIn("KeepAlive", job)
        self.assertEqual(job["EnvironmentVariables"]["HOME"], str(self.user_home))
        self.assertEqual(job["EnvironmentVariables"]["CODEX_HOME"], str(self.codex_home))
        self.assertEqual(job["WorkingDirectory"], str(self.user_home))
        result = subprocess.run(job["ProgramArguments"], check=True, capture_output=True, text=True)
        self.assertEqual(result.stdout.splitlines(), ["remote-control", "start", "--json"])
        self.assertEqual(plist_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual([c[0] for c in self.calls], ["print", "enable", "bootstrap"])

    def test_rerun_does_not_unload_a_healthy_job(self):
        self.install()
        self.calls.clear()
        self.install()
        self.assertEqual([c[0] for c in self.calls], ["print", "enable", "kickstart"])
        self.assertFalse(any("-k" in c for c in self.calls))

    def test_changed_binary_reloads_the_job(self):
        self.install()
        self.calls.clear()
        new_binary = self.user_home / "new codex"
        new_binary.symlink_to(self.codex)
        with patch.object(service.subprocess, "run", side_effect=self.launchctl):
            plist_path = service.install(self.user_home, self.codex_home, new_binary)
        job = plistlib.loads(plist_path.read_bytes())
        self.assertEqual(job["ProgramArguments"][0], str(new_binary))
        self.assertEqual([c[0] for c in self.calls], ["print", "enable", "bootout", "bootstrap"])

    def test_launchd_failure_is_reported(self):
        def fail(argv, **kwargs):
            if argv[1] == "bootstrap":
                raise subprocess.CalledProcessError(5, argv)
            return self.launchctl(argv, **kwargs)

        with patch.object(service.subprocess, "run", side_effect=fail):
            with self.assertRaises(subprocess.CalledProcessError):
                service.install(self.user_home, self.codex_home, self.codex)


if __name__ == "__main__":
    unittest.main()
