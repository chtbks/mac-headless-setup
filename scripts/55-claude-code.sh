#!/usr/bin/env bash
# 55-claude-code.sh — install Claude Code via the native installer.
# Lands a self-updating binary in ~/.local/bin.
# Sourced by setup.sh; defines module_main.

module_main() {
  export PATH="${HOME}/.local/bin:${PATH}"

  if have claude; then
    log_ok "Claude Code already installed ($(claude --version 2>/dev/null || echo present))"
    return 0
  fi

  log_info "installing Claude Code (native installer)…"
  if ! retry bash -c 'curl -fsSL https://claude.ai/install.sh | bash'; then
    log_error "Claude Code install failed"
    return 1
  fi

  if ! have claude; then
    log_warn "claude not on PATH yet; ensure ~/.local/bin is on PATH (30-shell handles login shells)"
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
  have claude && log_ok "Claude Code ready ($(claude --version 2>/dev/null || echo present))"
  return 0
}
