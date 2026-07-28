#!/usr/bin/env bash
# 95-pairing.sh — start the OpenClaw daemon and complete Slack pairing.
#
# This is the interactive-checkpoint step: we start the daemon, then pause for
# the human to DM the bot, receive a 6-digit code, and paste it back. Pressing
# Enter skips and adds the remaining work to the manual finish list.
#
# All of this is gated behind the capability probe from 90-openclaw, since the
# real OpenClaw CLI may not expose `daemon`/`pairing` as the doc claims.
#
# Sourced by setup.sh; defines module_main.

module_main() {
  load_brew_env
  have openclaw || { log_error "openclaw CLI missing"; return 1; }

  # Load probe results from 90-openclaw.
  local has_daemon=0 has_pairing=0
  # shellcheck disable=SC1090
  [[ -f "${STATE_DIR}/openclaw.probe" ]] && source "${STATE_DIR}/openclaw.probe"

  if (( ! has_daemon )); then
    log_warn "real OpenClaw CLI has no 'daemon' subcommand — the doc's flow is unverified here"
    add_manual_todo "Start OpenClaw per its actual CLI (check 'openclaw --help'); the doc's 'daemon start' may differ"
    return 0
  fi

  # Start the daemon (idempotent-ish; if already running this is a no-op error
  # we tolerate).
  log_info "starting OpenClaw daemon…"
  openclaw daemon start >>"${LOG_FILE}" 2>&1 || log_warn "'openclaw daemon start' returned non-zero (already running?)"
  sleep 3

  if (( ! has_pairing )); then
    log_warn "no 'pairing' subcommand detected — cannot script pairing"
    add_manual_todo "Pair your Slack user with OpenClaw per its real CLI/docs"
    return 0
  fi

  # Interactive checkpoint for the 6-digit code.
  local instructions
  instructions=$(cat <<'EOF'
1. In Slack, send a Direct Message to the OpenClaw bot.
2. The bot replies with a 6-digit pairing code.
3. Paste that code below to approve your Slack user.
EOF
)
  local code
  code="$(checkpoint "Approve OpenClaw Slack pairing (openclaw pairing approve slack <code>)" "${instructions}")"

  if [[ -z "${code}" ]]; then
    log_warn "pairing skipped"
    return 0
  fi

  if [[ ! "${code}" =~ ^[0-9]{6}$ ]]; then
    log_warn "'${code}' is not a 6-digit code; not attempting approve"
    add_manual_todo "Run: openclaw pairing approve slack <6-digit-code>"
    return 0
  fi

  log_info "approving pairing…"
  if openclaw pairing approve slack "${code}" >>"${LOG_FILE}" 2>&1; then
    log_ok "Slack user paired"
  else
    log_error "pairing approve failed"
    add_manual_todo "Retry: openclaw pairing approve slack ${code}"
    return 1
  fi

  # Post-setup reminder for the doc's Step 6 (worktree protocol system prompt).
  add_manual_todo "Send OpenClaw the worktree-protocol system instructions (docs Step 6)"
  return 0
}
