# Brewfile — packages for the headless iOS agent host.
# Installed with `brew bundle` by scripts/25-brewfile.sh (idempotent).

# --- Core CLI ---------------------------------------------------------------
brew "git"            # newer than the CLT-bundled git
brew "git-lfs"        # Chatbooks Flutter frameworks + kernel_blob.bin are LFS-tracked
brew "gh"             # GitHub auth (device flow) + git credential helper
brew "node"           # runtime for XcodeBuildMCP (via npx)
brew "jq"             # JSON wrangling in scripts / debugging

# --- Swift lint / format ----------------------------------------------------
brew "swiftlint"      # .swiftlint.yml in the iOS repo
brew "swift-format"   # .swift-format in the iOS repo

# --- Secrets ----------------------------------------------------------------
brew "lastpass-cli"   # `lpass` — primary secret source (see lib/common.sh)

# --- Networking / remote access --------------------------------------------
brew "tailscale"      # CLI + tailscaled daemon (headless-friendly)

# --- Apple toolchain --------------------------------------------------------
# `xcodes` installs full Xcode non-interactively when an Apple ID is provided.
brew "xcodesorg/made/xcodes"

# --- OpenClaw ---------------------------------------------------------------
# CLI-first for a headless host. If your account/setup turns out to need the
# GUI app instead, swap this for:  cask "openclaw"
brew "openclaw-cli"
