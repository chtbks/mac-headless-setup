#!/usr/bin/env bash
# 75-remote-login.sh — enable Remote Login (SSH) on the host.
#
# KNOWN macOS GOTCHA (flagged in planning): on recent macOS,
# `systemsetup -setremotelogin on` requires the calling process to have Full
# Disk Access. Over a plain SSH/Terminal session that FDA may not be granted,
# and the command can fail with "Turning Remote Login on or off requires Full
# Disk Access privileges." That grant is a GUI toggle and cannot be done
# headlessly — so this step degrades gracefully to a manual TODO.
#
# Sourced by setup.sh; defines module_main.

module_main() {
  # Already on?
  if sudo systemsetup -getremotelogin 2>/dev/null | grep -qi 'On'; then
    log_ok "Remote Login already enabled"
    return 0
  fi

  log_info "enabling Remote Login (SSH)…"
  local out
  out="$(sudo systemsetup -setremotelogin on 2>&1)"
  printf '%s\n' "${out}" >>"${LOG_FILE}"

  if sudo systemsetup -getremotelogin 2>/dev/null | grep -qi 'On'; then
    log_ok "Remote Login enabled"
    return 0
  fi

  if grep -qi 'Full Disk Access' <<<"${out}"; then
    log_warn "Remote Login needs Full Disk Access for this session (GUI-only grant)"
    add_manual_todo "Enable SSH: System Settings > General > Sharing > Remote Login (or grant your SSH client Full Disk Access, then re-run: ./setup.sh --only 75-remote-login)"
    # Not a hard failure — the box may already be reachable via Tailscale SSH.
    return 0
  fi

  log_error "failed to enable Remote Login: ${out}"
  return 1
}
