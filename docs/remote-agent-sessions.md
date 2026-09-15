# Remote agent sessions

How this host exposes coding-agent sessions to a phone or another desktop, and
why the three agents are wired differently. Written from what was actually
verified on the box — see the "Verified" notes.

## The launcher

[`bin/spawn-session.sh`](../bin/spawn-session.sh) (installed to
`~/spawn-session.sh` by `scripts/92-agent-sessions.sh`) is the single entry point:

```bash
~/spawn-session.sh [--agent claude|codex|cursor] <main-project> <display-name> [additional-project ...]
```

- `--agent` **defaults to `claude`**. Omit it rather than passing `--agent claude`.
- `<main-project>` is a direct child name of `~/workspace` (override the root
  with `SPAWN_SESSION_REPOS_DIR`). It gets the session's Git worktree.
- Additional projects are exposed as extra workspace directories, no worktree.
- Every session runs in its own `tmux` session named `<agent>-<internal-name>`,
  where the internal name carries a timestamp and PID so filesystem, Git branch,
  and tmux resources never collide. The display name stays human-readable.
- On any startup failure the launcher removes what it created (tmux session, and
  for codex/cursor the worktree and branch) and exits non-zero. It prints
  `Remote session is running.` only on success — the Hermes skill keys off that
  exact string.

Hermes drives it through the `spawn-claude-session` skill
([template](../templates/hermes-skills/spawn-claude-session/SKILL.md.tmpl)),
which defaults to Claude Code and only selects codex/cursor when the user asks
for one by name.

The launcher also accepts two automation-oriented options without changing the
legacy interface:

```bash
~/spawn-session.sh --prompt-file /path/to/prompt.txt --json chatty-family MEMS-123
```

`--prompt-file` passes one initial prompt as an argument (without evaluating it
as shell input). `--json` keeps stdout machine-readable while progress and
diagnostics go to stderr.

## Ticketflow: Jira and SSH intake

`scripts/93-ticketflow.sh` installs `ticketflow` at `~/.local/bin/ticketflow`.
It is an intake layer around the same launcher, not another agent runtime.

Manual SSH intake starts the normal gated workflow:

```bash
ticketflow start https://chatbookstown.atlassian.net/browse/MEMS-123
# A key is equivalent:
ticketflow start MEMS-123
# Pick another agent explicitly:
ticketflow start --agent codex MEMS-123
```

Ticketflow normalizes the key, maps `MEMS` to `~/workspace/chatty-family`, names
the Claude Remote Control session `MEMS-123`, and preloads `/cb-all`. Manual key
mappings also support `IOSP` → `iphone`, `FC` → `fluttershy`, and `COR` →
`backend`. Scoping,
implementation, PR iteration, and final sign-off stay in that session.

From another machine, clone this repository and use the included thin SSH
client. Configure `chatbooks-agent` as a host in `~/.ssh/config`, or set
`TICKETFLOW_REMOTE_HOST` to an SSH host or alias:

```bash
cd mac-headless-setup
TICKETFLOW_REMOTE_HOST=chatbooksqa@your-host \
  ./bin/ticketflow-remote MEMS-123
```

The client needs only Bash and SSH. It safely forwards the ticket key or URL to
`~/.local/bin/ticketflow start` on this Mac; Jira access, prompts, repository
mapping, tmux, and Claude Remote Control remain owned by the remote host.

Automatic intake is a launchd job named `ai.chatbooks.ticketflow`. Every 60
seconds it searches for the oldest unfinished issue carrying one of these labels:

- `josh-iphone` → `iphone`
- `josh-artemis` → `artemis`
- `josh-backend` → `backend`
- `josh-fluttershy` → `fluttershy`
- `josh-chatty-family` → `chatty-family`

The Jira board/project does not affect repository selection; the label does.
An additional `claude`, `cursor`, or `codex` label selects the agent. With no
agent label, Ticketflow defaults to `claude`; multiple agent labels are rejected
as ambiguous. The selected agent is stored with the run so retries use the same
agent even if the Jira labels change.

Each poll starts at most one new session. That session receives
`/cb-auto-ticket`, which continues without the grill/spec gates only if every
conservative low-risk condition passes. Otherwise it asks questions and waits
in the same remotely accessible session.

After a successful launch Ticketflow removes the triggering label, adds its
`-started` counterpart, and comments with the session name. Re-adding the trigger
creates an intentional new run. State and logs live under
`~/.local/state/ticketflow`; Jira credentials live in
`~/.config/ticketflow/env` with mode 0600.

Useful SSH diagnostics:

```bash
ticketflow status [MEMS-123]
ticketflow poll --once
ticketflow retry MEMS-123
ticketflow doctor
```

Launch failures retry after 1, 5, and 15 minutes. The fourth failure leaves the
trigger label in place, posts one sanitized Jira comment, and waits for an
explicit `ticketflow retry`. A successful launch whose Jira acknowledgment
fails is only re-acknowledged; it is never launched twice.

## Why each agent differs

The three agents do not share a remote-access model, and the launcher's output is
deliberately honest about it.

### Claude Code — per-session, native worktrees

`claude --worktree <name> --remote-control <display-name> --permission-mode auto`.
Remote Control is registered **per session**, so each one appears on its own at
`claude.ai/code` and in the phone app under its display name. Claude Code creates
and cleans up its own worktree under `<repo>/.claude/worktrees/`. The launcher
auto-answers the one-time `Enable Remote Control? (y/n)` consent prompt and
nothing else.

**Verified:** session reports `/remote-control is active` with a
`claude.ai/code/session_…` URL.

### Cursor — per-session named workers

For persistent access to the main checkouts, `57-cursor` now installs a separate
personal worker at login using `ai.chatbooks.cursor-worker`. See the
[Cursor recovery runbook](cursor-remote-recovery.md). The per-session launcher
described below still creates temporary, isolated worktree workers; these are
not automatically resurrected after reboot.

`cursor-agent worker start --name <display-name> --worker-dir <worktree>`
registers a **named private worker** with Cursor scoped to the directories given,
and prints `https://cursor.com/agents#workerId=<uuid>`. The launcher extracts
that URL (unwrapping the tmux line wrap) and reports it. This is the closest
thing to Claude Code's per-session parity.

Two consequences worth knowing:

- **No agent runs locally.** The worker is only the remote surface; you start an
  agent against it from Cursor on the web or your phone. The tmux pane holds the
  worker bridge, and killing it deregisters the worker.
- The launcher creates the worktree itself (the `worker` subcommand has no
  worktree flag) at `~/.cursor/worktrees/<project>/<internal-name>`, which is the
  CLI's own convention. Its first `--worker-dir` is the assignment identity, so
  the worktree comes first.

**Verified:** `cursor-agent worker debug` listed the worker as
`<uuid>(<display-name>)` while running, and `total=0` after the tmux session was
killed. That probe is the way to check registration without touching a phone.
`cursor-agent status` is the cheap auth gate.

### Codex — machine-wide, not per session

Codex has **no per-session remote flag**. Remote control is one machine-wide
app-server daemon (`codex remote-control start`) that carries every thread on the
host, and threads are opened from the ChatGPT app by picking a directory. So:

- The launcher ensures the daemon is running and **enrolled**, and aborts before
  creating anything if it is not — an unenrolled daemon means no remote access.
- It creates the worktree (`~/workspace/worktrees/<project>_<internal-name>`) and
  starts Codex in it with `--sandbox workspace-write -a never`, the unattended
  equivalent of Claude's auto permission mode.
- **The display name is local only.** Codex names its own threads, so don't tell
  anyone to look for it by name in the app.

**Restart recovery:** `56-codex` also installs the
`ai.chatbooks.codex-remote-control` LaunchAgent. It starts remote access at login
and retries every 60 seconds. A one-off `remote-control start` (or a bootstrap
that reports `backend: "pid"`) is insufficient for future boots. See the
[recovery runbook](codex-remote-recovery.md) for installation, checks, and the
requirement to log in to the host account after reboot.

Also ruled out: the app-server control socket does not answer app-server JSON-RPC
(`initialize` gets silence), so the launcher cannot create a named thread
programmatically. That is why Codex parity stops where it does.

#### Codex trust quirk

Codex resolves directory trust at the **repository root**, not the worktree path,
so a worktree launch blocks on a trust prompt unless the main repo is trusted
too. Worse, repeated `-c projects."<path>".trust_level=…` flags **replace** each
other instead of merging — only the last survives. The launcher therefore passes
one inline TOML table naming every directory the session touches:

```
-c 'projects={"<worktree>"={trust_level="trusted"},"<repo>"={trust_level="trusted"},…}'
```

This is launch-scoped, so nothing is written to `~/.codex/config.toml`, and
trusted projects recorded there are deliberately *not* inherited.

#### Codex enrollment failure modes

Enrollment against
`wss://chatgpt.com/backend-api/wham/remote/control/server` failed three distinct
ways on this host before it worked. Read the error body rather than guessing;
full detail lands in `~/.codex/logs_2.sqlite` (rows whose target is like
`%remote_control%`):

| Symptom | Cause | Fix |
|---|---|---|
| `403 codex_workspace_access_denied` | workspace admin has not granted Codex access | grant it in ChatGPT workspace admin, or use a different workspace |
| `403 {"detail":"Multi-factor authentication required"}` | session was SSO-only (`amr: ['urn:openai:amr:google']`) | `codex logout && codex login`, completing MFA |
| `401 token_revoked` | **the daemon is still holding a pre-login token** | after login, restart the daemon; allow the old process to exit before starting again |

That last one is the trap: after re-authenticating, restart the daemon before
concluding anything is wrong with the account. `scripts/56-codex.sh` tries
enrollment first and only stops/retries after a failure, waiting for the old
control socket to disappear. For manual maintenance, first
[unload automatic recovery](codex-remote-recovery.md#pause-or-remove), then stop
the daemon, complete login, and rerun the service installer.

Local Codex usage works throughout all of these — only enrollment is affected.

## Reaching sessions from a client

- **Claude Code:** `claude.ai/code`, or the phone app; each session is listed by
  display name.
- **Cursor:** the `cursor.com/agents#workerId=…` link the launcher prints.
- **Codex, phone:** pick this host in the ChatGPT app. If it is not listed, pair
  with `codex remote-control pair`.
- **Codex, desktop app:** Settings → Connections on the machine you are sitting
  at. First authorize via **"Control other devices from this Mac"** →
  *Authorize on chatgpt.com*, then either **Add device** (same relay the phone
  uses; lists signed-in devices Online/Offline) or **Add SSH Connection** (reads
  `~/.ssh/config`, or add host/port/identity manually — a good fit for this box,
  which already has Tailscale and Remote Login). Do **not** turn on the host-side
  "Allow this Mac to be discovered and controlled" toggle here: this host is
  already enrolled through the CLI daemon, and that would create a second
  enrollment for the same machine.

  Mac-to-Mac desktop remote control has known rough edges
  ([#26640](https://github.com/openai/codex/issues/26640),
  [#25532](https://github.com/openai/codex/issues/25532)); the SSH route or
  `chatgpt.com/codex` in a browser reach the same sessions.

## Housekeeping

Killing a tmux session stops the agent but does **not** remove a worktree the
launcher created. The success output prints the exact `git worktree remove` /
`git branch -D` command for that session; Claude Code cleans up its own.

Stale worktrees accumulate in `~/workspace/worktrees/` and
`~/.cursor/worktrees/`. `git -C <repo> worktree list` is the source of truth.
