#!/usr/bin/env bash
# 90-openclaw.sh — install the OpenClaw CLI, probe what it actually provides,
# and scaffold its config from our template.
#
# CLI-first + scaffold-and-verify (from planning). The source doc's config
# schema and commands are UNVERIFIED, so we:
#   1. Ensure the `openclaw` CLI exists (installed via Brewfile: openclaw-cli).
#   2. Probe `openclaw --help` and record the real subcommands to the log.
#   3. Run `openclaw init` if it exists and diff its output vs our template.
#   4. Write the config only if we can locate the real config path.
#
# Sourced by setup.sh; defines module_main.

module_main() {
  load_brew_env

  if ! have openclaw; then
    log_error "openclaw CLI not found. Brewfile installs 'openclaw-cli'."
    add_manual_todo "Install OpenClaw CLI (brew install openclaw-cli) and re-run: ./setup.sh --only 90-openclaw"
    return 1
  fi
  log_ok "openclaw CLI present: $(openclaw --version 2>/dev/null || echo 'version unknown')"

  # --- Probe real capabilities (scaffold-and-verify) -----------------------
  log_info "probing 'openclaw --help' — recording real subcommands to the log…"
  openclaw --help >>"${LOG_FILE}" 2>&1 || log_warn "'openclaw --help' returned non-zero"

  local has_init=0 has_daemon=0 has_pairing=0
  local help; help="$(openclaw --help 2>&1 || true)"
  grep -qiE '\binit\b'    <<<"${help}" && has_init=1
  grep -qiE '\bdaemon\b'  <<<"${help}" && has_daemon=1
  grep -qiE '\bpairing\b' <<<"${help}" && has_pairing=1
  log_info "detected subcommands — init:${has_init} daemon:${has_daemon} pairing:${has_pairing}"
  # Stash for the pairing module.
  printf 'has_daemon=%s\nhas_pairing=%s\n' "${has_daemon}" "${has_pairing}" >"${STATE_DIR}/openclaw.probe"

  # --- Run init if available, then diff against our template ---------------
  local cfg_dir="${HOME}/.openclaw"
  local cfg_file="${cfg_dir}/config.yaml"
  if (( has_init )); then
    log_info "running 'openclaw init'…"
    openclaw init >>"${LOG_FILE}" 2>&1 || log_warn "'openclaw init' returned non-zero"
  fi

  # Resolve secrets for the template.
  local bot app
  bot="$(get_secret SLACK_BOT_TOKEN "MacSetup/slack-bot-token" "Slack Bot User OAuth Token (xoxb-…)" --optional)"
  app="$(get_secret SLACK_APP_TOKEN "MacSetup/slack-app-token" "Slack App-Level Token (xapp-…)" --optional)"

  # Render the template regardless (best-effort scaffold).
  local rendered="${STATE_DIR}/openclaw.config.rendered.yaml"
  SLACK_BOT_TOKEN="${bot}" SLACK_APP_TOKEN="${app}" \
    _render_template "${REPO_ROOT}/templates/openclaw.config.yaml.tmpl" "${rendered}"

  if [[ -f "${cfg_file}" ]]; then
    log_info "existing config at ${cfg_file}; diff vs our scaffold (informational):"
    diff -u "${cfg_file}" "${rendered}" >>"${LOG_FILE}" 2>&1 || true
    if [[ -z "${bot}" || -z "${app}" ]]; then
      log_warn "Slack tokens not provided; leaving existing config untouched"
      add_manual_todo "Add Slack tokens to config and re-run: ./setup.sh --only 90-openclaw"
    else
      log_info "writing merged Slack settings into ${cfg_file}"
      cp "${cfg_file}" "${cfg_file}.macsetup.bak.$(date +%s)"
      cp "${rendered}" "${cfg_file}"
      log_ok "updated ${cfg_file} (backup kept)"
    fi
  else
    if [[ -z "${bot}" || -z "${app}" ]]; then
      log_warn "no config produced by init and no tokens to scaffold one"
      add_manual_todo "Create OpenClaw config with Slack tokens (see docs) then re-run pairing"
      return 0
    fi
    mkdir -p "${cfg_dir}"
    cp "${rendered}" "${cfg_file}"
    log_ok "wrote scaffolded config to ${cfg_file} (UNVERIFIED schema — validate on first daemon start)"
  fi

  return 0
}

# _render_template <src> <dst> — substitute ${VAR} using envsubst if available,
# otherwise a pure-bash fallback for the two known vars.
_render_template() {
  local src="$1" dst="$2"
  if have envsubst; then
    envsubst <"${src}" >"${dst}"
  else
    sed -e "s|\${SLACK_BOT_TOKEN}|${SLACK_BOT_TOKEN:-}|g" \
        -e "s|\${SLACK_APP_TOKEN}|${SLACK_APP_TOKEN:-}|g" \
        "${src}" >"${dst}"
  fi
}
