# Brewfile — packages for the headless iOS agent host.
# Installed with `brew bundle` by scripts/25-brewfile.sh (idempotent).

# --- Core CLI ---------------------------------------------------------------
# NOTE: no `brew "git"`. On the newest macOS the Homebrew git bottle links a
# newer libcurl than the system ships (_curl_global_trace not found), crashing
# git-remote-https. The Command Line Tools git works with the system libcurl, so
# we use that. git-lfs/gh don't depend on the git formula.
brew "git-lfs"        # Chatbooks Flutter frameworks + kernel_blob.bin are LFS-tracked
brew "gh"             # GitHub auth (device flow) + git credential helper
brew "node"           # runtime for XcodeBuildMCP (via npx); artemis swagger prep (node)
brew "jq"             # JSON wrangling in scripts / debugging
brew "aria2"          # parallel downloader; xcodes auto-uses it to speed the multi-GB Xcode download
brew "python@3.14"    # artemis API codegen (generate_api_code.py) + analytics-validator venvs

# --- Swift lint / format ----------------------------------------------------
brew "swiftlint"      # .swiftlint.yml in the iOS repo
brew "swift-format"   # .swift-format in the iOS repo

# --- Secrets ----------------------------------------------------------------
brew "lastpass-cli"   # `lpass` — primary secret source (see lib/common.sh)

# --- Networking / remote access --------------------------------------------
brew "tailscale"      # CLI + tailscaled daemon (headless-friendly)
brew "tmux"           # every spawned agent session runs in its own tmux session (bin/spawn-session.sh)

# --- Apple toolchain --------------------------------------------------------
# NOTE: `xcodes` (used to auto-install full Xcode) is intentionally NOT here.
# On the newest macOS, homebrew-core has no `xcodes` bottle ("Tier 3 / no bottle
# available"), which would fail the whole `brew bundle`. scripts/40-xcode.sh
# installs it best-effort (bottle, else build-from-source) only when an Apple ID
# is provided, and degrades gracefully otherwise.

# --- Agent controller -------------------------------------------------------
# OpenClaw was replaced by the Hermes Agent, which is a Git checkout rather than
# a Homebrew package — scripts/90-hermes.sh clones it and runs its own
# setup-hermes.sh (which installs uv and builds a Python 3.11 venv).
#
# `brew bundle` here runs without --cleanup, so dropping openclaw-cli from this
# file does not uninstall it from hosts that already have it. To reclaim the
# space on such a host:  brew uninstall openclaw-cli
#
# The coding agents are likewise not Homebrew packages: Claude Code, Codex, and
# Cursor all ship self-updating installers (scripts/55, 56, 57).
