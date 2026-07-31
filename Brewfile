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
brew "python@3.14"    # artemis API codegen (generate_api_code.py) + analytics-validator venvs

# --- Swift lint / format ----------------------------------------------------
brew "swiftlint"      # .swiftlint.yml in the iOS repo
brew "swift-format"   # .swift-format in the iOS repo

# --- Secrets ----------------------------------------------------------------
brew "lastpass-cli"   # `lpass` — primary secret source (see lib/common.sh)

# --- Networking / remote access --------------------------------------------
brew "tailscale"      # CLI + tailscaled daemon (headless-friendly)

# --- Apple toolchain --------------------------------------------------------
# NOTE: `xcodes` (used to auto-install full Xcode) is intentionally NOT here.
# On the newest macOS, homebrew-core has no `xcodes` bottle ("Tier 3 / no bottle
# available"), which would fail the whole `brew bundle`. scripts/40-xcode.sh
# installs it best-effort (bottle, else build-from-source) only when an Apple ID
# is provided, and degrades gracefully otherwise.

# --- OpenClaw ---------------------------------------------------------------
# CLI-first for a headless host. If your account/setup turns out to need the
# GUI app instead, swap this for:  cask "openclaw"
brew "openclaw-cli"
