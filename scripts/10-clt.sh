#!/usr/bin/env bash
# 10-clt.sh — ensure Xcode Command Line Tools are present.
#
# The curl|bash bootstrap normally installs these already. This module is the
# idempotent belt-and-suspenders path for when setup.sh is run from an
# already-cloned repo without the bootstrap.
#
# Sourced by setup.sh; defines module_main.

module_main() {
  if xcode-select -p >/dev/null 2>&1 && [[ -e /Library/Developer/CommandLineTools/usr/bin/git ]]; then
    log_ok "Command Line Tools already installed ($(xcode-select -p))"
    return 0
  fi

  log_info "installing Command Line Tools (headless)…"
  local placeholder="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
  touch "${placeholder}"
  local label
  label="$(softwareupdate -l 2>/dev/null \
    | grep -E 'Label: *Command Line Tools' \
    | sed -E 's/^.*Label: *//' \
    | sort -V | tail -n1 || true)"
  if [[ -n "${label}" ]]; then
    run_logged "install ${label}" softwareupdate -i "${label}" --verbose || true
  else
    log_warn "no CLT label available; trying xcode-select --install"
    xcode-select --install 2>/dev/null || true
  fi
  rm -f "${placeholder}"

  local waited=0
  until xcode-select -p >/dev/null 2>&1 && /usr/bin/git --version >/dev/null 2>&1; do
    (( waited >= 900 )) && { log_error "CLT did not finish installing"; return 1; }
    log_info "waiting for Command Line Tools ( ${waited}s )…"
    sleep 15; waited=$((waited + 15))
  done
  log_ok "Command Line Tools ready"
  return 0
}
