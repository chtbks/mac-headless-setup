# MacSetup — Headless iOS Agent-Host Bootstrap

Fault-tolerant, **re-runnable** scripts that turn a **fresh, headless Mac**
(latest macOS, a user logged in, otherwise at defaults) into a Slack-driven iOS
development agent host. The original writeup is
[`docs/openclaw-ios-agent-setup-v1.md`](docs/openclaw-ios-agent-setup-v1.md);
**OpenClaw has since been replaced by the [Hermes Agent](https://github.com/NousResearch/hermes-agent)**
as the Slack-facing controller.

It installs and configures: Command Line Tools, Homebrew, oh-my-zsh, Node,
the XcodeBuildMCP CLI, full Xcode (via `xcodes`), Git LFS, SwiftLint +
swift-format, GitHub access (`gh` device-flow auth + git credential helper, so
agents can clone/push private repos), Tailscale, Remote Login/SSH, the Chatbooks
build secrets, Hermes + Slack pairing, and three coding agents reachable from a
phone — **Claude Code, Codex, and Cursor** — plus the launcher that spawns
isolated remote sessions for them (see
[`docs/remote-agent-sessions.md`](docs/remote-agent-sessions.md)).

---

## Quick start (on a fresh box, SSH is fine)

```bash
curl -fsSL https://raw.githubusercontent.com/chtbks/mac-headless-setup/main/bootstrap.sh | MACSETUP_REPO=https://github.com/chtbks/mac-headless-setup.git bash
```

The bootstrap installs Command Line Tools **headlessly** (no GUI prompt), clones
this repo to `~/mac-headless-setup`, and runs `./setup.sh`.

Already have the repo cloned? Just:

```bash
./setup.sh
```

> The repo (`github.com/chtbks/mac-headless-setup`) must be **public** for the
> token-less one-liner to work (no secrets live in it).

---

## Prerequisites (do these once, before running)

Some things genuinely can't be automated on the box — do them first and stash
the resulting secrets (see [Secrets](#secrets)):

1. **Slack app for Hermes.** Hermes generates its own app manifest — run
   `hermes slack` on the box (the `90-hermes` module pauses for this), create the
   app from the manifest at <https://api.slack.com/apps>, install it to the
   workspace, and paste the **Bot User OAuth Token** (`xoxb-…`) and **App-Level
   Token** (`xapp-…`) where Hermes asks. Tokens live in `~/.hermes/config.yaml`,
   not in this repo's `config.env`.
2. **Tailscale auth key** (recommended) from
   <https://login.tailscale.com/admin/settings/keys>. Prefer a **tagged**,
   reusable key for a long-lived host. If your tailnet is managed by Google
   Workspace and you can't mint keys, either ask an admin or skip the key and
   use the interactive SSO fallback.
3. **Apple ID** (optional) if you want the scripts to install **full Xcode**
   via `xcodes`. Otherwise only Command Line Tools are installed.
4. **GitHub access** — this box runs as the dedicated **Chatbooks QA machine
   user (`qa@chatbooks.com`)**. Nothing to pre-create: the `50-github` module
   runs `gh` device-flow login during the run (enter a one-time code at
   <https://github.com/login/device>) — **sign in as the `qa` account, not a
   personal one**, and ensure it has push access to the target repos. Git
   identity defaults to that machine user. Because **chtbks enforces SAML SSO**,
   after login you may need to authorize the session for the org — the script
   detects this and tells you. (Optional: drop a fine-grained PAT for the `qa`
   user in `GITHUB_TOKEN`/LastPass for a fully unattended login instead.)

---

## Toolchain notes

- **Xcode floor:** the `artemis` repo requires **Xcode 26+ / Swift 6.2**
  (`Package.swift` is `swift-tools-version: 6.2.1`); Chatbooks needs Xcode 16+.
  `xcodes install --latest` satisfies both — if you ever pin a version, keep it ≥26.
- **Python:** `python@3.14` is installed for artemis's API codegen
  (`api/generate.sh`) and its analytics-validator venvs (which are created
  per-clone by repo scripts, not here).

## Required private repo access (`qa` GitHub user)

SwiftPM resolves these private `chtbks` repos directly — the `qa` machine user
must have **read** access and, because chtbks enforces SAML SSO, the session/token
must be **SSO-authorized**. `52-repo-access` checks each and re-runs until all pass:

```
artemis  AppNavigationMacros  ServerIdentifiableMacros  ios-api
chatty-api  chatty-ui  chatty-strings  chatty-uploader
CustomAlert  MediaEncoder  imgly-sdk-ios-2  rudder-sdk-ios  braintree_ios
```

## Remote agent sessions

Hermes spawns isolated agent sessions on this box through one launcher, installed
by `92-agent-sessions`:

```bash
~/spawn-session.sh [--agent claude|codex|cursor] <main-project> <display-name> [additional-project ...]
```

`--agent` **defaults to `claude`**; the Hermes skill only picks codex or cursor
when you ask for one by name. Each session gets its own Git worktree and `tmux`
session, and the launcher prints how to reach it (a `claude.ai/code` session, a
`cursor.com/agents#workerId=…` link, or the worktree to open in the ChatGPT app).

The three agents do **not** share a remote-access model — Claude Code and Cursor
register per session, Codex is machine-wide and cannot name a thread remotely.
[`docs/remote-agent-sessions.md`](docs/remote-agent-sessions.md) covers that, the
Codex trust and enrollment quirks (including the `401 token_revoked` trap after
re-login), and how to connect from the macOS desktop app.

**Codex offline after restarting the Mac?** See
[`docs/codex-remote-recovery.md`](docs/codex-remote-recovery.md). The `56-codex`
module installs a login job that starts remote access and retries every minute.
On an existing host, run `./bin/install-codex-service` once to add it without
rerunning the full setup. The host account must log in after a reboot.

**Cursor:** SSH already uses the system Remote Login/Tailscale services. For
web/phone agents, `57-cursor` installs a persistent personal worker for the five
supported repos that exist under `~/workspace`. Existing hosts can run
`./bin/install-cursor-service`. See
[`docs/cursor-remote-recovery.md`](docs/cursor-remote-recovery.md) for the two
connection types, startup behavior, exact repo selection, and recovery checks.
The setup also installs separate `iphone` and `chatty-family` workers so each
can be selected as the primary repository, alongside the original Artemis worker.
Install them directly with `./bin/install-cursor-service --service-id iphone
"$HOME/workspace/iphone"` (or `chatty-family` with its matching path).

For ticket-driven work, `93-ticketflow` also installs a 60-second Jira poller.
Adding a repository label (`josh-iphone`, `josh-artemis`, `josh-backend`,
`josh-fluttershy`, or `josh-chatty-family`) to any Jira issue starts a coding
session in that repository. Add `cursor` or `codex` to select another agent;
`claude` is the default. Over SSH, `ticketflow start MEMS-123` starts the
ordinary gated `/cb-all` workflow in the same kind of remote session. See the
Ticketflow section in
[`docs/remote-agent-sessions.md`](docs/remote-agent-sessions.md#ticketflow-jira-and-ssh-intake).

---

## Secrets

Secrets are resolved in this order, per value: **LastPass → `config.env` →
interactive prompt**.

- **LastPass:** `brew install lastpass-cli` then `lpass login <you@work>` (this
  is interactive and may require MFA). The scripts read these entries by
  default: `MacSetup/slack-bot-token`, `MacSetup/slack-app-token`,
  `MacSetup/tailscale-authkey`, `MacSetup/apple-id`, `MacSetup/jira-email`
  (username field), and `MacSetup/jira-api-token`.
- **File fallback:** `cp config.example.env config.env` and fill it in.
  `config.env` is gitignored.
- **Prompt:** anything still missing is asked for at runtime (silently). Run
  with `MACSETUP_NONINTERACTIVE=1` to skip prompts and defer to the manual list.

---

## How it works

- **Idempotent & resumable.** Each step records a marker in `log/state/`. A
  re-run skips completed steps. Force a full redo with `MACSETUP_FORCE=1`.
- **Resilient.** A failed step is logged and the run **continues**; steps that
  depend on the failed one are skipped, and a summary lists what failed so you
  can re-run to finish.
- **Logged.** Every run is tee'd to `log/setup-<timestamp>.log`.
- **Human checkpoints.** Steps needing a human (Hermes/Slack pairing, `codex
  login` and `cursor-agent login`, Tailscale SSO fallback, Xcode 2FA) pause with
  instructions; pressing Enter skips and adds
  the item to a "finish manually" list at the end.
- **One sudo prompt.** Asked once up front, kept warm in the background.

### Modules (run in this order; dependencies enforced)

| id | does |
|----|------|
| `00-preflight` | macOS/arch/network checks |
| `10-clt` | Command Line Tools (headless) |
| `20-homebrew` | Homebrew + PATH |
| `25-brewfile` | everything in [`Brewfile`](Brewfile) (incl. git-lfs, swiftlint, swift-format, python@3.14) |
| `30-shell` | oh-my-zsh (near-vanilla) + PATH |
| `35-git-lfs` | Git LFS filters (Chatbooks Flutter/LFS assets) |
| `40-xcode` | full Xcode via `xcodes` + license accept |
| `45-macro-trust` | disable Swift-macro fingerprint validation (headless builds) |
| `50-github` | GitHub auth (`gh` device flow) + git identity + credential helper |
| `52-repo-access` | verify `qa` can read the private `chtbks` SPM repos |
| `55-claude-code` | Claude Code native installer |
| `56-codex` | Codex CLI + remote-control enrollment + login/recovery launchd job |
| `57-cursor` | Cursor CLI + login + persistent personal worker for existing repos |
| `60-xcodebuildmcp` | install the XcodeBuildMCP CLI globally (`xcodebuildmcp`, `xcodebuildmcp-doctor`) |
| `70-tailscale` | tailscaled + join tailnet |
| `75-remote-login` | enable SSH |
| `85-app-secrets` | Chatbooks build secrets → `~/.chatbooks-build.env` |
| `90-hermes` | Hermes Agent clone + `setup-hermes.sh` + config (replaces OpenClaw) |
| `92-agent-sessions` | install `~/spawn-session.sh` + the Hermes `spawn-claude-session` skill |
| `93-ticketflow` | install `ticketflow` + a 60-second launchd Jira poller for `josh-*` repository labels |
| `95-hermes-gateway` | start the Hermes gateway + Slack pairing |
| `99-verify` | doctor / health report |

Run a single module (dependencies still checked):

```bash
./setup.sh --only 70-tailscale
```

---

## ⚠️ Unverified — validate on first real run

These are transcribed from the source doc and **could not be verified** while
authoring. The scripts handle them defensively (probe, gate, degrade to a manual
TODO) rather than assuming they work:

1. **Hermes config is owned by Hermes.** `90-hermes.sh` deliberately does not
   template `~/.hermes/config.yaml` — the OpenClaw-era scaffold guessed at a
   schema and was never right. Channel setup is a checkpoint (`hermes setup`,
   `hermes slack`) and the module only verifies a `slack:` section exists.
2. **The Hermes gateway is not supervised.** `95-hermes-gateway.sh` starts it for
   the current boot only and records a manual TODO; it does not install a launchd
   agent.
3. **XcodeBuildMCP package name.** The source doc's `@sentry/xcodebuildmcp` is
   wrong; the real package is `xcodebuildmcp` (unscoped). We install it as a
   **CLI** (`npm install -g xcodebuildmcp` → `xcodebuildmcp` +
   `xcodebuildmcp-doctor`), not as a registered MCP server.
4. **`systemsetup -setremotelogin on` may need Full Disk Access** on recent
   macOS — a GUI-only grant. If so, the step degrades to a manual TODO (Tailscale
   SSH may already cover remote access).
5. **Tailscale key generation** may be restricted by a Google-Workspace-managed
   tailnet; the interactive SSO fallback covers that case.

---

## Layout

```
bootstrap.sh                 curl|bash entrypoint (headless CLT → clone → setup)
setup.sh                     orchestrator (sudo, secrets, run modules, summary)
Brewfile                     brew packages
config.example.env           secret template (copy to config.env)
lib/common.sh                logging, run-step engine, retry, secrets, checkpoints
scripts/*.sh                 one module per concern (see table above)
bin/spawn-session.sh         remote-session launcher (installed to ~/spawn-session.sh)
bin/install-codex-service    install Codex remote startup/recovery for the logged-in user
bin/install-cursor-service   install a persistent repo-scoped Cursor personal worker
bin/ticketflow               Jira intake CLI (installed to ~/.local/bin/ticketflow)
bin/ticketflow-remote        SSH client for starting Ticketflow from another machine
templates/hermes-skills/     the Hermes skill that calls the launcher
docs/                        original setup writeup + remote-agent-sessions.md
log/                         run logs + resume markers (gitignored)
```
