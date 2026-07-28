#!/usr/bin/env bash
# 00-preflight.sh — sanity checks before we touch anything.
# Sourced by setup.sh; defines module_main.

module_main() {
  # macOS only.
  if [[ "$(uname -s)" != "Darwin" ]]; then
    log_error "not macOS"; return 1
  fi

  local product build arch
  product="$(sw_vers -productVersion 2>/dev/null || echo '?')"
  build="$(sw_vers -buildVersion 2>/dev/null || echo '?')"
  arch="$(uname -m)"
  log_info "macOS ${product} (${build}) on ${arch}"

  # We target Apple Silicon (Homebrew at /opt/homebrew). Warn on Intel.
  if [[ "${arch}" != "arm64" ]]; then
    log_warn "non-arm64 arch '${arch}' — Homebrew prefix will differ; proceeding anyway"
  fi

  # OpenClaw cask requires macOS >= 15; warn if older.
  local major="${product%%.*}"
  if [[ "${major}" =~ ^[0-9]+$ ]] && (( major < 15 )); then
    log_warn "macOS ${product} is < 15; OpenClaw may refuse to install"
  fi

  # Network reachability (best-effort; retried).
  if retry curl -fsS --max-time 10 https://github.com >/dev/null; then
    log_ok "network reachable"
  else
    log_error "cannot reach github.com — network required for the rest of setup"
    return 1
  fi

  return 0
}
