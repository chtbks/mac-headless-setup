#!/usr/bin/env bash
# setup.sh — orchestrator for the MacSetup headless iOS agent-host bootstrap.
#
# Safe to run repeatedly: every step is idempotent and resumable. A failed step
# is logged and skipped-forward; re-running picks up where it left off.
#
# Usage:
#   ./setup.sh                 # full run
#   MACSETUP_FORCE=1 ./setup.sh          # ignore completion markers, redo all
#   MACSETUP_NONINTERACTIVE=1 ./setup.sh # never prompt; skip human checkpoints
#   ./setup.sh --only 70-tailscale       # run a single module (deps still checked)
#
# See README.md for prerequisites (Slack app, LastPass entries, Tailscale key).

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

ONLY=""
if [[ "${1:-}" == "--only" ]]; then ONLY="${2:-}"; fi

trap stop_sudo_keepalive EXIT

log_step "MacSetup — headless iOS agent host"
log_info "run id: ${RUN_ID}   log: ${LOG_FILE}"
log_info "flags: FORCE=${FORCE} NONINTERACTIVE=${NONINTERACTIVE} ONLY=${ONLY:-<none>}"

# Load Homebrew env (if brew already installed from a prior run) and secrets.
load_brew_env
load_config_env

# Validate sudo up front so no later step stalls waiting for a password.
ensure_sudo || log_warn "continuing without validated sudo — privileged steps may fail"

# ---------------------------------------------------------------------------
# Module registry. Format: "<id>|<description>|<script>|<space-separated deps>"
# Order matters; dependencies are enforced by run_step regardless of order.
# ---------------------------------------------------------------------------
MODULES=(
  "00-preflight|Preflight checks (macOS version, arch, network)|00-preflight.sh|"
  "10-clt|Xcode Command Line Tools (headless)|10-clt.sh|00-preflight"
  "20-homebrew|Homebrew|20-homebrew.sh|10-clt"
  "25-brewfile|Brew packages (Brewfile)|25-brewfile.sh|20-homebrew"
  "30-shell|oh-my-zsh + PATH|30-shell.sh|20-homebrew"
  "40-xcode|Full Xcode via xcodes + license accept|40-xcode.sh|25-brewfile"
  "50-github|GitHub auth (gh device flow) + git identity|50-github.sh|25-brewfile"
  "55-claude-code|Claude Code (native installer)|55-claude-code.sh|00-preflight"
  "60-xcodebuildmcp|Register XcodeBuildMCP with Claude Code|60-xcodebuildmcp.sh|25-brewfile 55-claude-code"
  "70-tailscale|Tailscale (CLI daemon + join tailnet)|70-tailscale.sh|25-brewfile"
  "75-remote-login|Enable Remote Login (SSH)|75-remote-login.sh|00-preflight"
  "90-openclaw|OpenClaw CLI install + config scaffold|90-openclaw.sh|25-brewfile"
  "95-pairing|OpenClaw daemon + Slack pairing|95-pairing.sh|90-openclaw"
  "99-verify|Verify / doctor|99-verify.sh|"
)

run_module() {
  local spec="$1"
  local id desc script deps
  IFS='|' read -r id desc script deps <<<"${spec}"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/${script}"   # defines step_<id-without-prefix>? -> we call `main`
  # Each module script defines a function named `module_main`.
  # shellcheck disable=SC2086
  run_step "${id}" "${desc}" module_main ${deps}
  unset -f module_main 2>/dev/null || true
}

for spec in "${MODULES[@]}"; do
  id="${spec%%|*}"
  if [[ -n "${ONLY}" && "${id}" != "${ONLY}" ]]; then continue; fi
  run_module "${spec}"
done

print_summary
