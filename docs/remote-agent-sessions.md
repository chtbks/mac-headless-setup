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
| `401 token_revoked` | **the daemon is still holding a pre-login token** | `codex remote-control stop && codex remote-control start` |

That last one is the trap: after re-authenticating, restart the daemon before
concluding anything is wrong with the account. `scripts/56-codex.sh` always stops
the daemon before starting it for exactly this reason.

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
