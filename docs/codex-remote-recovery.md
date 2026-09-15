# Codex remote projects after a Mac restart

## What failed on 2026-09-15

After the host rebooted into macOS 27.0 (26A428), remote projects could no
longer connect. SSH still accepted connections on port 22, and the system
Tailscale daemon had started successfully. `codex login status` still reported
a ChatGPT login. The missing component was the **Codex remote app-server**:

```text
$ codex app-server daemon version
Error: failed to connect to .../.codex/app-server-control/app-server-control.sock
Caused by: No such file or directory (os error 2)
```

The old setup ran `codex remote-control start` once. There was no Codex job in
`~/Library/LaunchAgents`, so nothing restarted that process after boot/login.
Opening the desktop app started its own local app-server; that did not restore
the separately enrolled CLI remote host. The evidence establishes a missing
startup configuration, not an authentication failure or an OS-update regression.

CLI 0.154.0's `codex app-server daemon bootstrap --remote-control` restored
access immediately and reported `backend: "pid"`. On this Mac it did **not**
install a launchd job. Its durable settings and self-updating installation alone
therefore do not provide startup after reboot.

## Install or repair

Run as the host's normal macOS user, with that account logged in. No sudo is
needed. From this repo:

```bash
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
./bin/install-codex-service
codex remote-control start --json
```

The final command should report `"status":"connected"` and
`"timedOut":false`. Existing saved projects should reconnect to the same host.
Keep the existing connection on the client; a restart does not require deleting
projects, pairing again, or signing out.

The regular `56-codex` setup module now also installs the job. For an already
provisioned machine, bypass the previous completion marker:

```bash
MACSETUP_FORCE=1 ./setup.sh --only 56-codex
```

The direct installer above avoids the full setup runner's general sudo prompt.
It requires Python 3 only during installation; the installed job invokes Codex
directly and has no dependency on this repo's location or Python at startup.

## Startup and recovery behavior

Installed job: `~/Library/LaunchAgents/ai.chatbooks.codex-remote-control.plist`.

- `RunAtLoad` starts remote access when the user's login session loads.
- `StartInterval=60` retries after a missing daemon or delayed network access.
  The command is idempotent and leaves an already running daemon running.
- `AbandonProcessGroup=true` lets the spawned daemon outlive the short startup
  command. `KeepAlive` is omitted because the command exits after starting the
  daemon; repeatedly restarting the command would create a tight loop.
- An absolute, stable Codex path is used without resolving its symlink to a
  versioned release. The existing `~/.local/bin/codex` installation can update.
- `HOME`, `CODEX_HOME`, the working directory, and PATH are explicit. The job
  uses the same host identity and credentials as the installing user.
- Reinstalling an unchanged job does not unload it or kill an in-flight start.
  No periodic stop/restart or authentication reset is performed.

**After reboot, log in to the `chatbooksqa` account once.** This is a user
LaunchAgent, not a pre-login system service. If FileVault is enabled, the disk
must also be unlocked before normal services can run. The installer does not
configure automatic login or change disk encryption. Locking an existing login
session is different from logging out. The Mac must remain awake and online;
the job cannot restore access while the computer is asleep or shut down.
FileVault was confirmed **On** on this host during the 2026-09-15 repair.

## Diagnose the next failure

Run these from a normal Terminal or an SSH session as the host user. An agent
sandbox can deny local sockets and process inspection even when services are
healthy; an `Operation not permitted` result there is not evidence of an outage.

```bash
# Read-only daemon reachability check. It must not start a missing daemon.
codex app-server daemon version

# The periodic command normally exits. "not running" with last exit code 0
# is healthy for this launchd job; the separate Codex daemon keeps running.
launchctl print "gui/$(id -u)/ai.chatbooks.codex-remote-control"
plutil -lint "$HOME/Library/LaunchAgents/ai.chatbooks.codex-remote-control.plist"

# Last launchd enrollment result and recent errors.
tail -n 1 "$HOME/Library/Logs/MacSetup/codex-remote-control.log"
tail -n 20 "$HOME/Library/Logs/MacSetup/codex-remote-control.err.log"

# Authentication presence, then actively ensure enrollment.
codex login status
codex remote-control start --json

# Separate network checks for SSH connections.
tailscale ip -4
nc -vz -G 3 127.0.0.1 22
launchctl print system/homebrew.mxcl.tailscale
launchctl print system/com.openssh.sshd
```

SSH is socket-activated, so `com.openssh.sshd` can also say `not running` while
port 22 is available. Use the TCP check, not the process-state wording alone.

If launchd is disabled, rerun the installer to re-enable and load it. If macOS
reports no `gui/<uid>` domain, log in to that account, then rerun. Check the
macOS Login Items/background items settings if the job was disabled there.

If enrollment returns a 401 or 403, use the
[enrollment error table](remote-agent-sessions.md#codex-enrollment-failure-modes).
The recovery job cannot fix revoked credentials, missing MFA, or account access.
Resolve those based on the actual error, not by deleting the daemon directory.

If the host reports `connected` but one client still fails, reconnect its
existing connection and inspect that client's error. Host-side enrollment is
not an end-to-end test of another computer's app or SSH credentials.

Logs append under `~/Library/Logs/MacSetup/`; the success log receives one JSON
record per minute. They are local diagnostics and should not be committed.

## Pause or remove

The job will undo a plain `codex remote-control stop` within a minute. To
intentionally stop remote access for maintenance, first unload recovery:

```bash
launchctl bootout "gui/$(id -u)/ai.chatbooks.codex-remote-control"
codex remote-control stop
```

Rerun `./bin/install-codex-service` to resume. To remove automatic startup
permanently, also remove its plist after unloading it:

```bash
rm "$HOME/Library/LaunchAgents/ai.chatbooks.codex-remote-control.plist"
```

## Verification

Installer regression checks:

```bash
python3 -m unittest discover -s tests -p test_codex_service.py
```

They verify executable arguments and XML escaping, startup/retry settings,
daemon child survival settings, stable binary paths, idempotent installation,
and propagation of launchd failures. They use a temporary directory and mock
launchctl, so they cannot prove a real login or reboot works.

For a live recovery check, stop the remote daemon during a maintenance window
and confirm `codex app-server daemon version` fails. Leave the launchd job
loaded, wait for its next 60-second interval, then check `daemon version` and
the newest launchd log entry. Do not run `remote-control start` during this
test: that would mask a broken automatic recovery job. A full reboot/login
check remains the final validation of macOS startup behavior.

On 2026-09-15, the live recovery test passed: after `remote-control stop`,
`daemon version` failed because the socket was absent. Without manually
starting Codex, the next launchd interval logged `daemon.status: "started"`
and remote `status: "connected"`. A subsequent interval logged
`daemon.status: "alreadyRunning"` for the same enrolled environment, and
launchd reported exit code 0. All four installer regression tests passed.
The computer was not rebooted again, and the other computer's client was not
directly tested.

The CLI commands and backend behavior above were checked against the installed
0.154.0 CLI and this Mac. The launchd settings were checked against the local
`man launchd.plist`; future CLI changes should be validated with `--help` and
the recovery test before changing the job.
