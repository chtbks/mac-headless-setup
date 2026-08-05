#!/usr/bin/env bash
# 90-hermes.sh — install the Hermes Agent, which replaced OpenClaw as the
# Slack-facing controller on this host.
#
# Hermes is distributed as a Git checkout, not a package: clone it, then let its
# own setup-hermes.sh build a Python 3.11 venv (it installs uv if missing) and
# symlink the `hermes` CLI into ~/.local/bin.
#
# Hermes owns its configuration through an interactive wizard (`hermes setup`)
# and stores it in ~/.hermes/config.yaml, so this module deliberately does NOT
# template that file — an earlier OpenClaw-era scaffold guessed at a schema and
# was never right. Slack wiring is a checkpoint instead.
#
# Sourced by setup.sh; defines module_main.

HERMES_REPO="${HERMES_REPO:-https://github.com/NousResearch/hermes-agent.git}"
HERMES_REF="${HERMES_REF:-main}"
HERMES_HOME="${HERMES_HOME:-${HOME}/.hermes}"
HERMES_SRC="${HERMES_HOME}/hermes-agent"

module_main() {
  load_brew_env
  export PATH="${HOME}/.local/bin:${PATH}"

  _hermes_fetch || return 1
  _hermes_build || return 1
  _hermes_configure
  return 0
}

# --- source checkout -------------------------------------------------------
_hermes_fetch() {
  if [[ -d "${HERMES_SRC}/.git" ]]; then
    # A local checkout may carry local commits (this host has). Never reset it:
    # fetch and report, and let the operator decide when to move.
    log_info "existing Hermes checkout at ${HERMES_SRC}"
    if ! retry git -C "${HERMES_SRC}" fetch --quiet origin "${HERMES_REF}"; then
      log_warn "could not fetch origin/${HERMES_REF}; using the checkout as-is"
      return 0
    fi
    local behind
    behind="$(git -C "${HERMES_SRC}" rev-list --count "HEAD..origin/${HERMES_REF}" 2>/dev/null || echo 0)"
    if [[ "${behind}" != "0" ]]; then
      log_warn "Hermes checkout is ${behind} commit(s) behind origin/${HERMES_REF}"
      add_manual_todo "Update Hermes when convenient: git -C ${HERMES_SRC} pull --ff-only (then re-run ./setup.sh --only 90-hermes)"
    else
      log_ok "Hermes checkout is current with origin/${HERMES_REF}"
    fi
    return 0
  fi

  log_info "cloning Hermes Agent (${HERMES_REPO} @ ${HERMES_REF})…"
  mkdir -p "${HERMES_HOME}"
  if ! retry git clone --branch "${HERMES_REF}" "${HERMES_REPO}" "${HERMES_SRC}"; then
    log_error "Hermes clone failed"
    return 1
  fi
  log_ok "cloned Hermes to ${HERMES_SRC}"
  return 0
}

# --- venv + CLI ------------------------------------------------------------
_hermes_build() {
  if have hermes; then
    log_ok "hermes CLI already installed ($(hermes --version 2>/dev/null | head -n1 || echo present))"
    return 0
  fi

  local setup="${HERMES_SRC}/setup-hermes.sh"
  [[ -x "${setup}" ]] || [[ -f "${setup}" ]] || { log_error "missing ${setup}"; return 1; }

  log_info "running setup-hermes.sh (builds the venv, installs uv if needed, links the CLI)…"
  # Its wizard is interactive; MACSETUP_NONINTERACTIVE runs should skip it and
  # leave the wizard for the Slack checkpoint below.
  if ! retry bash "${setup}" </dev/null >>"${LOG_FILE}" 2>&1; then
    log_error "setup-hermes.sh failed — see ${LOG_FILE}"
    return 1
  fi
  hash -r 2>/dev/null || true

  have hermes || { log_error "hermes not on PATH after setup (expected ~/.local/bin/hermes)"; return 1; }
  log_ok "hermes CLI ready ($(hermes --version 2>/dev/null | head -n1 || echo present))"
  return 0
}

# --- configuration ---------------------------------------------------------
# Slack is the channel this host uses. Hermes generates its own app manifest, so
# point the operator at that rather than hand-rolling tokens into a YAML file.
_hermes_configure() {
  local cfg="${HERMES_HOME}/config.yaml"

  if [[ -f "${cfg}" ]] && grep -qE '^\s*slack:' "${cfg}" 2>/dev/null; then
    log_ok "Hermes config present with a Slack section (${cfg})"
  else
    local instructions
    instructions=$(cat <<'EOF'
Hermes has no Slack channel configured yet. Run its wizard on this machine:

    hermes setup            # pick provider/model and channels
    hermes slack            # generate the Slack app manifest, then install the
                            # app to the workspace and paste its tokens

Slack tokens live in ~/.hermes/config.yaml (bot xoxb-… and app-level xapp-…).

Press Enter once Hermes reports a configured Slack channel (nothing to paste).
EOF
)
    checkpoint "Configure Hermes Slack channel ('hermes setup' + 'hermes slack')" "${instructions}" >/dev/null
    if [[ -f "${cfg}" ]] && grep -qE '^\s*slack:' "${cfg}" 2>/dev/null; then
      log_ok "Hermes Slack section now present"
    else
      log_warn "Hermes still has no Slack channel configured"
    fi
  fi

  log_info "hermes doctor (diagnostics to the log)…"
  hermes doctor >>"${LOG_FILE}" 2>&1 || log_warn "'hermes doctor' reported problems — see ${LOG_FILE}"
  return 0
}
