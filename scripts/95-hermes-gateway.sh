#!/usr/bin/env bash
# 95-hermes-gateway.sh — start the Hermes messaging gateway and pair the Slack
# user, replacing the OpenClaw daemon + pairing step.
#
# The gateway is the long-running process that connects Hermes to Slack. Pairing
# approves which Slack user may drive the agent.
#
# Sourced by setup.sh; defines module_main.

HERMES_HOME="${HERMES_HOME:-${HOME}/.hermes}"

module_main() {
  export PATH="${HOME}/.local/bin:${PATH}"
  have hermes || { log_error "hermes CLI missing (90-hermes incomplete)"; return 1; }

  _gateway_start || return 1
  _pairing
  _status
  return 0
}

# --- gateway ---------------------------------------------------------------
_gateway_start() {
  if pgrep -f 'hermes.*gateway' >/dev/null 2>&1; then
    log_ok "Hermes gateway already running (pid $(pgrep -f 'hermes.*gateway' | head -n1))"
    return 0
  fi

  local cfg="${HERMES_HOME}/config.yaml"
  if [[ ! -f "${cfg}" ]]; then
    log_warn "no ${cfg} — configure Hermes first (./setup.sh --only 90-hermes)"
    add_manual_todo "Configure Hermes, then start the gateway: hermes gateway run --replace"
    return 0
  fi

  # `gateway run` stays in the foreground, so background it and keep the log.
  local glog="${LOG_DIR}/hermes-gateway-${RUN_ID}.log"
  log_info "starting the Hermes gateway (log: ${glog})…"
  nohup hermes gateway run --replace >"${glog}" 2>&1 &
  disown 2>/dev/null || true

  local waited=0
  until pgrep -f 'hermes.*gateway' >/dev/null 2>&1; do
    (( waited >= 30 )) && { log_error "gateway did not start within 30s — see ${glog}"; return 1; }
    sleep 2; waited=$((waited + 2))
  done
  log_ok "Hermes gateway running"

  add_manual_todo "Make the gateway survive reboots (launchd agent or 'hermes gateway' under a supervisor) — this module only starts it for the current boot"
  return 0
}

# --- pairing ---------------------------------------------------------------
_pairing() {
  # checkpoint's non-interactive notice goes to stdout, so capturing its output
  # in that mode would read the log line back as the pairing code. Bail first.
  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    log_warn "non-interactive: skipping the Hermes Slack pairing checkpoint"
    add_manual_todo "Pair the Slack user: DM the Hermes bot, then 'hermes pairing approve <code>'"
    return 0
  fi

  local instructions
  instructions=$(cat <<'EOF'
1. In Slack, send a Direct Message to the Hermes bot.
2. Hermes replies with a pairing code (and 'hermes pairing list' shows pending
   requests on this machine).
3. Paste that code below to approve your Slack user.

Press Enter with no value to skip and approve it yourself later with
'hermes pairing approve <code>'.
EOF
)
  local code
  code="$(checkpoint "Approve the Hermes Slack pairing (hermes pairing approve <code>)" "${instructions}")"

  [[ -z "${code}" ]] && { log_warn "pairing skipped"; return 0; }

  # Codes are short alphanumerics; refuse anything that could carry shell or
  # argument syntax rather than passing it through.
  if [[ ! "${code}" =~ ^[A-Za-z0-9-]{4,32}$ ]]; then
    log_warn "'${code}' does not look like a pairing code; not attempting approve"
    add_manual_todo "Run: hermes pairing approve <code>"
    return 0
  fi

  log_info "approving pairing…"
  if hermes pairing approve "${code}" >>"${LOG_FILE}" 2>&1; then
    log_ok "Slack user paired"
  else
    log_warn "'hermes pairing approve ${code}' failed — check 'hermes pairing list'"
    add_manual_todo "Retry the Hermes pairing: hermes pairing approve ${code}"
  fi
  return 0
}

# --- status ----------------------------------------------------------------
_status() {
  log_info "hermes status (to the log)…"
  hermes status >>"${LOG_FILE}" 2>&1 || log_warn "'hermes status' returned non-zero"
  log_info "ask Hermes in Slack to 'start an artemis session' to exercise the spawn-session skill"
  return 0
}
