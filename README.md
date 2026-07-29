# MacSetup — Headless iOS Agent-Host Bootstrap

Fault-tolerant, **re-runnable** scripts that turn a **fresh, headless Mac**
(latest macOS, a user logged in, otherwise at defaults) into the Slack-driven
iOS development agent host described in
[`docs/openclaw-ios-agent-setup-v1.md`](docs/openclaw-ios-agent-setup-v1.md).

It installs and configures: Command Line Tools, Homebrew, oh-my-zsh, Node,
Claude Code, XcodeBuildMCP (wired to Claude Code), full Xcode (via `xcodes`),
Git LFS, SwiftLint + swift-format, GitHub access (`gh` device-flow auth + git
credential helper, so agents can clone/push private repos), Tailscale, Remote
Login/SSH, the Chatbooks build secrets, and the OpenClaw CLI + Slack pairing.

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

1. **Create the Slack app** at <https://api.slack.com/apps> (from scratch):
   - **Socket Mode** → On → generate an **App-Level Token** (`xapp-…`) with
     `connections:write`.
   - **OAuth & Permissions** → Bot Token Scopes: `app_mentions:read`,
     `chat:write`, `im:history`, `im:read`, `im:write`.
   - Install to workspace → copy the **Bot User OAuth Token** (`xoxb-…`).
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

## Required private repo access (`qa` GitHub user)

SwiftPM resolves these private `chtbks` repos directly — the `qa` machine user
must have **read** access and, because chtbks enforces SAML SSO, the session/token
must be **SSO-authorized**. `52-repo-access` checks each and re-runs until all pass:

```
artemis  AppNavigationMacros  ServerIdentifiableMacros  ios-api
chatty-api  chatty-ui  chatty-strings  chatty-uploader
CustomAlert  MediaEncoder  imgly-sdk-ios-2  rudder-sdk-ios  braintree_ios
```

## Secrets

Secrets are resolved in this order, per value: **LastPass → `config.env` →
interactive prompt**.

- **LastPass:** `brew install lastpass-cli` then `lpass login <you@work>` (this
  is interactive and may require MFA). The scripts read these entries by
  default: `MacSetup/slack-bot-token`, `MacSetup/slack-app-token`,
  `MacSetup/tailscale-authkey`, `MacSetup/apple-id`.
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
- **Human checkpoints.** Steps needing a human (OpenClaw pairing, Tailscale SSO
  fallback, Xcode 2FA) pause with instructions; pressing Enter skips and adds
  the item to a "finish manually" list at the end.
- **One sudo prompt.** Asked once up front, kept warm in the background.

### Modules (run in this order; dependencies enforced)

| id | does |
|----|------|
| `00-preflight` | macOS/arch/network checks |
| `10-clt` | Command Line Tools (headless) |
| `20-homebrew` | Homebrew + PATH |
| `25-brewfile` | everything in [`Brewfile`](Brewfile) (incl. git-lfs, swiftlint, swift-format) |
| `30-shell` | oh-my-zsh (near-vanilla) + PATH |
| `35-git-lfs` | Git LFS filters (Chatbooks Flutter/LFS assets) |
| `40-xcode` | full Xcode via `xcodes` + license accept |
| `45-macro-trust` | disable Swift-macro fingerprint validation (headless builds) |
| `50-github` | GitHub auth (`gh` device flow) + git identity + credential helper |
| `52-repo-access` | verify `qa` can read the private `chtbks` SPM repos |
| `55-claude-code` | Claude Code native installer |
| `60-xcodebuildmcp` | register XcodeBuildMCP with Claude Code |
| `70-tailscale` | tailscaled + join tailnet |
| `75-remote-login` | enable SSH |
| `85-app-secrets` | Chatbooks build secrets → `~/.chatbooks-build.env` |
| `90-openclaw` | OpenClaw CLI install + config scaffold |
| `95-pairing` | OpenClaw daemon + Slack pairing |
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

1. **OpenClaw's Slack integration, `config.yaml` schema, and
   `daemon`/`pairing` subcommands.** `90-openclaw.sh` probes the real
   `openclaw --help`, runs `openclaw init` if present, and diffs its output
   against [`templates/openclaw.config.yaml.tmpl`](templates/openclaw.config.yaml.tmpl).
   The template schema is a best-effort scaffold.
2. **`openclaw-cli` vs the `openclaw` cask.** We install the CLI formula for a
   headless box. If your setup actually needs the GUI app, switch the Brewfile
   line to `cask "openclaw"`.
3. **XcodeBuildMCP package name.** The source doc's `@sentry/xcodebuildmcp` is
   wrong; the real package is `xcodebuildmcp` (unscoped). Registered with Claude
   Code via `claude mcp add … npx -y xcodebuildmcp@<version>`. **OpenClaw-side
   registration is a marked TODO** pending its real MCP mechanism.
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
templates/                   config templates (OpenClaw)
docs/                        the original setup writeup (reference)
log/                         run logs + resume markers (gitignored)
```
