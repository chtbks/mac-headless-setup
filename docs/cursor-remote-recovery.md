# Cursor remote access after restart

Cursor has two separate routes to this Mac:

| Route | What you use | What must run on this Mac |
| --- | --- | --- |
| Remote SSH | Cursor desktop on another computer, editing a remote folder | macOS Remote Login; Tailscale when connecting over the tailnet |
| My Machines / private worker | Cursor web or phone, dispatching agents here | A persistent `cursor-agent worker` bridge authenticated as your Cursor user |

Cursor's [Remote SSH guidance](https://cursor.com/help/troubleshooting/network)
and [My Machines documentation](https://cursor.com/docs/cloud-agent/self-hosted/my-machines)
describe these routes. Desktop-managed Remote Control also uses a worker, but
its lifecycle is owned by Cursor's desktop app. The service below is a CLI
worker, independent of the desktop app.

## Findings on 2026-09-15

- SSH accepted TCP connections on both loopback and the host's Tailscale IP.
  `com.openssh.sshd` was enabled, and `homebrew.mxcl.tailscale` was running with
  `RunAtLoad` and `KeepAlive`. Those startup services already survived reboot.
- `~/.cursor-server` contained recent Remote SSH installs and logs from before
  the reboot. The other computer's client and SSH authentication were not
  directly tested; a successful TCP connection proves the listener, not login.
- `cursor-agent status` confirmed the saved login. No Cursor worker process or
  Cursor LaunchAgent was running on this host.
- The old setup only installed/authenticated the CLI. `spawn-session.sh --agent
  cursor` runs a temporary worker inside tmux. Restarting tmux with an empty
  `main` session does not restore those worker commands.
- `cursor-agent worker debug` could see workers belonging to the other Mac.
  A nonzero global worker count therefore did not mean **this** Mac was online.

No host-side SSH configuration change was needed. A persistent personal Cursor
worker was installed for the existing `artemis`, `iphone`, `backend`,
`fluttershy`, and `chatty-family` checkouts.

## Install and connect

As the logged-in host user, from this repo:

```bash
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
cursor-agent status
./bin/install-cursor-service
```

If signed out, run `cursor-agent login` first. No sudo is needed. The installer
requires Python 3, but the installed job invokes the CLI directly.

The default worker name on this host is **ChatbooksQAs-MacBook-Pro - Cursor**.
Select it under My Machines at [Cursor Agents](https://cursor.com/agents). The
worker's log also prints a direct `agents#workerId=…` link. Starting the bridge
registers the machine; it does not submit a coding task.

With no directory arguments, the installer registers the existing five supported
repos under `~/workspace`. It never defaults to exposing the entire home or
workspace directory. To choose other roots, pass their exact paths:

```bash
./bin/install-cursor-service --name "QA Cursor" \
  "$HOME/workspace/artemis" "$HOME/workspace/backend"
```

The first root is the primary assignment directory. All roots must exist.
These are the existing checkouts; this installer creates no worktrees. Use
`spawn-session.sh --agent cursor ...` when an isolated, temporary worktree
worker is desired instead. Its lifetime is still tied to its tmux session.

`57-cursor` now installs the persistent service after authentication, using the
five existing repo directories under `WORKSPACE_DIR` (default `~/workspace`).
Fresh hosts without cloned repos receive a manual follow-up instead. To rerun
the module despite its old completion marker:

```bash
MACSETUP_FORCE=1 ./setup.sh --only 57-cursor
```

Rerunning that module uses the default name and supported roots. If using a
custom name/root list, rerun the direct installer with those same arguments.
Changing configuration reloads the worker and interrupts any tasks using it;
an unchanged installation keeps the running worker and its identity.

## Why this survives future logins and exits

Job: `~/Library/LaunchAgents/ai.chatbooks.cursor-worker.plist`.

- `RunAtLoad=true`: starts when the user's login session loads.
- `KeepAlive=true`: restarts after crashes **and** normal exit. This CLI's
  default idle-release timeout is 3600 seconds, after which it can exit with
  code 0. Restarting only failed exits would eventually leave it offline.
- `ThrottleInterval=30`: limits rapid retries during startup failures.
- Explicit HOME, PATH, working directory, and absolute CLI path remove login
  shell dependencies. The stable CLI symlink is retained for CLI updates.
- A generated `CURSOR_AGENT_WORKER_ID` is saved in the plist and retained on
  reinstall, so recovery re-registers the same worker ID.
- `--data-dir ~/.local/share/cursor-agent/macsetup-worker` separates its worker
  lock and runtime files from the CLI's default data directory used by temporary
  session workers.

This runs as the user's personal worker and uses their saved Cursor login.
It does not opt into a team pool or credential delivery flags. Repo roots guide
workspace selection and routing; they are not an OS sandbox for tool processes.

**FileVault is On on this Mac.** After a full restart, unlock the Mac and log in
to `chatbooksqa` once. The LaunchAgent then starts automatically. Neither this
worker nor SSH can bypass the disk-unlock stage. Keep the Mac awake and online.

## Check and recover

```bash
# This long-running job should say state = running and have a pid.
launchctl print "gui/$(id -u)/ai.chatbooks.cursor-worker"
plutil -lint "$HOME/Library/LaunchAgents/ai.chatbooks.cursor-worker.plist"
tail -n 20 "$HOME/Library/Logs/MacSetup/cursor-worker.log"
tail -n 20 "$HOME/Library/Logs/MacSetup/cursor-worker.err.log"

# Same data directory, name, and roots as the installed default worker.
cursor-agent worker --name "ChatbooksQAs-MacBook-Pro - Cursor" \
  --data-dir "$HOME/.local/share/cursor-agent/macsetup-worker" \
  --worker-dir "$HOME/workspace/artemis" \
  --worker-dir "$HOME/workspace/iphone" \
  --worker-dir "$HOME/workspace/backend" \
  --worker-dir "$HOME/workspace/fluttershy" \
  --worker-dir "$HOME/workspace/chatty-family" debug --json
```

For a custom installation, use its saved arguments from the plist, replacing
`start` with `debug --json`. In the report, verify that **this worker's ID/name**
appears in `visibilityProbe`, not just that `totalCount` is positive. A running
process alone also does not prove successful registration. The probe samples a
limited number of workers; if this worker is not in the sample, check the
My Machines list before concluding it is offline.

If the job is missing or disabled, rerun the installer. If auth fails, complete
`cursor-agent login` and restart the worker in a maintenance window. Read the
actual error before changing authentication or deleting runtime files. A CLI
preflight warning about Linux X11 computer use does not prevent file/terminal
worker access; desktop computer use is separate from this service.

For a desktop SSH failure, on the **client** Mac run
`ssh chatbooksqa@<host-tailscale-ip>`, then reconnect with Cursor's
`Remote-SSH: Connect to Host`. If SSH succeeds but Cursor fails, inspect Cursor's
Remote-SSH output. A private worker service does not repair a client SSH error.

Logs and worker runtime files remain local and should not be committed.

## Stop, restart, or remove

Unloading the job is the way to stop it deliberately. Killing its process alone
triggers automatic recovery.

```bash
launchctl bootout "gui/$(id -u)/ai.chatbooks.cursor-worker"
```

Rerun the installer to resume. For permanent removal, unload it first, then:

```bash
rm "$HOME/Library/LaunchAgents/ai.chatbooks.cursor-worker.plist"
```

## Verification

```bash
python3 -m unittest discover -s tests -p test_cursor_service.py
```

Tests cover restart after normal exits, exact repo arguments including spaces,
separate runtime state, stable identity, idempotent installation, scope changes,
missing directories, and propagation of launchd errors. They mock launchctl.

For a live recovery test when no agents are using this worker, record its PID
and worker ID, then send `launchctl kill SIGTERM` to this job. Leave it loaded.
Verify launchd increments `runs`, gives it a new PID, and Cursor sees the same
worker ID again. This checks automatic recovery without rebooting the machine.

On 2026-09-15 this live check passed: the first worker exited with code 0,
launchd started a replacement process, and both privacy visibility probes
listed the same saved worker ID with all five expected roots. All five Cursor
installer tests and four existing Codex installer tests passed. SSH TCP checks
also passed on loopback and the Tailscale address. No full reboot or remote
client UI session was tested.

Behavior was checked against installed CLI `2026.08.11-e8db854`, its help/code,
and local `man launchd.plist`. Cursor's [My Machines docs](https://cursor.com/docs/cloud-agent/self-hosted/my-machines)
cover multi-root registration; [worker deployment guidance](https://cursor.com/docs/cloud-agent/self-hosted/pool)
supports launchd supervision. Newer CLI releases may differ; verify options
and recovery before changing the job.
