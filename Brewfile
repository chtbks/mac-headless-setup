# Brewfile — packages for the headless iOS agent host.
# Installed with `brew bundle` by scripts/25-brewfile.sh (idempotent).

# --- Core CLI ---------------------------------------------------------------
brew "git"            # newer than the CLT-bundled git
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
# `xcodes` installs full Xcode non-interactively when an Apple ID is provided.
# Now in homebrew-core (was the xcodesorg/made tap, which newer Homebrew refuses
# to auto-tap mid-`brew bundle` as an untrusted third-party source).
brew "xcodes"

# --- OpenClaw ---------------------------------------------------------------
# CLI-first for a headless host. If your account/setup turns out to need the
# GUI app instead, swap this for:  cask "openclaw"
brew "openclaw-cli"
