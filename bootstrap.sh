#!/usr/bin/env bash
# bootstrap.sh — zero-dependency entrypoint for a FRESH, headless Mac.
#
# Run on the target box (over SSH is fine):
#
#   curl -fsSL https://raw.githubusercontent.com/<you>/mac-headless-setup/main/bootstrap.sh | bash
#
# It:
#   1. Installs the Xcode Command Line Tools WITHOUT the GUI prompt (so it works
#      headless over SSH), waiting until they're actually present.
#   2. Clones (or updates) this repo to ~/MacSetup.
#   3. Hands off to ./setup.sh for the real work.
#
# Override the source with env vars, e.g.:
#   MACSETUP_REPO=https://github.com/you/MacSetup.git MACSETUP_REF=main bash bootstrap.sh

set -euo pipefail

REPO_URL="${MACSETUP_REPO:-https://github.com/chtbks/mac-headless-setup.git}"
REF="${MACSETUP_REF:-main}"
DEST="${MACSETUP_DEST:-${HOME}/mac-headless-setup}"

say()  { printf '\033[34m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[bootstrap]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "this bootstrap is for macOS only"

# ---------------------------------------------------------------------------
# 1. Command Line Tools — headless install.
#
# `git`/`clang` on a fresh Mac trigger a GUI installer we can't click over SSH.
# The softwareupdate trick below requests the CLT non-interactively.
# ---------------------------------------------------------------------------
install_clt() {
  if xcode-select -p >/dev/null 2>&1 && [[ -e /Library/Developer/CommandLineTools/usr/bin/git ]]; then
    say "Command Line Tools already installed"
    return 0
  fi
  say "Installing Command Line Tools (headless)…"
  local placeholder="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
  touch "${placeholder}"
  # Find the newest Command Line Tools label offered by softwareupdate.
  local label
  label="$(softwareupdate -l 2>/dev/null \
    | grep -E 'Label: *Command Line Tools' \
    | sed -E 's/^.*Label: *//' \
    | sort -V | tail -n1 || true)"
  if [[ -n "${label}" ]]; then
    say "Installing: ${label}"
    softwareupdate -i "${label}" --verbose || warn "softwareupdate install returned non-zero"
  else
    warn "no CLT label from softwareupdate; falling back to xcode-select --install"
    xcode-select --install 2>/dev/null || true
  fi
  rm -f "${placeholder}"

  # Wait until git is actually usable (up to ~15 min).
  local waited=0
  until xcode-select -p >/dev/null 2>&1 && /usr/bin/git --version >/dev/null 2>&1; do
    (( waited >= 900 )) && die "Command Line Tools did not finish installing in time"
    say "…waiting for Command Line Tools ( ${waited}s )"
    sleep 15; waited=$((waited + 15))
  done
  say "Command Line Tools ready"
}

install_clt

# ---------------------------------------------------------------------------
# 2. Clone or update the repo.
# ---------------------------------------------------------------------------
if [[ "${REPO_URL}" == *REPLACE_ME* ]]; then
  warn "REPO_URL is still the placeholder. Set MACSETUP_REPO to your repo, e.g.:"
  warn "  MACSETUP_REPO=https://github.com/you/mac-headless-setup.git bash bootstrap.sh"
fi

if [[ -d "${DEST}/.git" ]]; then
  say "Updating existing checkout at ${DEST}"
  git -C "${DEST}" fetch --depth 1 origin "${REF}" && git -C "${DEST}" checkout -q "${REF}" && git -C "${DEST}" reset -q --hard "origin/${REF}" || warn "update failed; using existing checkout"
else
  say "Cloning ${REPO_URL} -> ${DEST}"
  git clone --depth 1 --branch "${REF}" "${REPO_URL}" "${DEST}"
fi

# ---------------------------------------------------------------------------
# 3. Hand off to setup.sh.
# ---------------------------------------------------------------------------
say "Handing off to setup.sh"
cd "${DEST}"
chmod +x setup.sh scripts/*.sh 2>/dev/null || true
exec ./setup.sh "$@"
