#!/usr/bin/env bash
# 56-codex.sh — install the Codex CLI and enroll this machine for Codex remote
# control so sessions are reachable from the ChatGPT phone/desktop apps.
#
# Codex remote access is MACHINE-WIDE, unlike Claude Code's per-session
# registration: one `codex remote-control` app-server daemon carries every thread
# on this host, and threads are opened from the ChatGPT app by picking a
# directory. See docs/remote-agent-sessions.md.
#
# Login is interactive (browser + MFA), so it is a checkpoint rather than
# something this script can do unattended.
#
# Sourced by setup.sh; defines module_main.

module_main() {
  load_brew_env
  export PATH="${HOME}/.local/bin:${PATH}"

  _codex_install || return 1
  _codex_login    # non-fatal: records a manual TODO when unauthenticated
  # macOS's Codex PID backend survives terminal exit, but has no boot/login
  # registration. Install recovery before enrollment so a reboot or delayed
  # network cannot leave the host offline indefinitely.
  have python3 || { log_error "python3 missing (Brewfile step incomplete)"; return 1; }
  run_logged "install Codex login/recovery job" \
    python3 "${REPO_ROOT}/bin/install-codex-service" || return 1
  _codex_remote_control
  return 0
}

# --- install ---------------------------------------------------------------
# An existing install is left alone: the standalone package under
# ~/.codex/packages/standalone self-updates via `codex update`, and installing a
# second copy from Homebrew would shadow it depending on PATH order.
_codex_install() {
  if have codex; then
    log_ok "Codex CLI already installed ($(codex --version 2>/dev/null || echo present))"
    return 0
  fi

  log_info "installing Codex CLI (Homebrew)…"
  if retry brew install codex; then
    hash -r 2>/dev/null || true
  else
    log_warn "brew install codex failed; trying npm"
    have npm || { log_error "npm missing too (Brewfile step incomplete)"; return 1; }
    retry npm install -g @openai/codex || { log_error "Codex CLI install failed"; return 1; }
    hash -r 2>/dev/null || true
  fi

  have codex || { log_error "codex not on PATH after install"; return 1; }
  log_ok "Codex CLI ready ($(codex --version 2>/dev/null || echo present))"
  return 0
}

# --- authentication --------------------------------------------------------
_codex_login() {
  if codex login status >/dev/null 2>&1; then
    log_ok "Codex already authenticated"
    return 0
  fi

  local instructions
  instructions=$(cat <<'EOF'
Codex needs a ChatGPT login before remote control can enroll. On this machine:

    codex login

Remote control additionally requires:
  - the ChatGPT workspace to permit Codex (a 403 codex_workspace_access_denied
    on enrollment means an admin has not granted it), and
  - a session that satisfied MFA — a Google-SSO-only session is rejected with
    403 "Multi-factor authentication required".

Press Enter once `codex login` has completed (nothing to paste).
EOF
)
  checkpoint "Run 'codex login' (browser + MFA) so Codex remote control can enroll" "${instructions}" >/dev/null

  if codex login status >/dev/null 2>&1; then
    log_ok "Codex authenticated"
  else
    log_warn "Codex still unauthenticated — remote control cannot enroll yet"
  fi
  return 0
}

# --- remote control --------------------------------------------------------
# `codex remote-control start` is idempotent and exits non-zero when the daemon
# cannot reach the remote-control service, so try it first. Only when that fails
# do we restart: a daemon started before an authentication change keeps using the
# old token and enrollment then fails with 401 token_revoked.
#
# Do NOT stop-then-immediately-start. `stop` returns before the app-server has
# exited, and starting into that window leaves the daemon wedged ("app server did
# not become ready"), which then needs the manual recovery described below.
_codex_remote_control() {
  log_info "enrolling this machine for Codex remote control…"
  if _codex_rc_start; then return 0; fi

  log_info "first attempt failed; restarting the daemon so it picks up current credentials…"
  codex remote-control stop >>"${LOG_FILE}" 2>&1 || \
    log_warn "'codex remote-control stop' returned non-zero"
  _codex_rc_wait_stopped
  if _codex_rc_start; then return 0; fi

  log_warn "Codex remote control did not enroll"
  log_info "enrollment errors are logged in ~/.codex/logs_2.sqlite (rows with target like '%remote_control%')"
  log_info "a 403 means the ChatGPT workspace or MFA blocks it; 'app server did not become ready' means a wedged daemon (see below)"
  add_manual_todo "Fix Codex remote-control enrollment, then: codex remote-control start"
  add_manual_todo "If the daemon is wedged: check ~/.codex/app-server-daemon/app-server.pid — when that pid is <defunct>, kill the pid in app-server-updater.pid to let it be reaped, then start again"
  return 0
}

_codex_rc_start() {
  local out
  if out="$(codex remote-control start 2>&1)"; then
    printf '%s\n' "${out}" >>"${LOG_FILE}"
    log_ok "Codex remote control enrolled ($(printf '%s' "${out}" | grep -i 'available for remote control' | head -n1 || echo 'daemon running'))"
    add_manual_todo "Pair a phone/desktop client with Codex if this host is not listed yet: codex remote-control pair"
    return 0
  fi
  printf '%s\n' "${out}" >>"${LOG_FILE}"
  log_warn "codex remote-control start: $(printf '%s' "${out}" | grep -iE '^(error|caused)' | head -n1 || printf '%s' "${out}" | head -n1)"
  return 1
}

# Wait for the control socket to disappear, i.e. the app-server really exited.
_codex_rc_wait_stopped() {
  local sock="${CODEX_HOME:-${HOME}/.codex}/app-server-control/app-server-control.sock"
  local waited=0
  while [[ -e "${sock}" ]] && (( waited < 20 )); do
    sleep 1; waited=$((waited + 1))
  done
  [[ -e "${sock}" ]] && log_warn "control socket still present after ${waited}s; starting anyway"
  # Even once the socket is gone the process may still be tearing down.
  sleep 2
  return 0
}
