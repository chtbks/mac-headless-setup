#!/usr/bin/env bash
# 25-brewfile.sh — install everything in the Brewfile.
# Sourced by setup.sh; defines module_main.

module_main() {
  load_brew_env
  have brew || { log_error "brew not available"; return 1; }

  local brewfile="${REPO_ROOT}/Brewfile"
  [[ -f "${brewfile}" ]] || { log_error "Brewfile missing at ${brewfile}"; return 1; }

  log_info "brew update…"
  retry brew update || log_warn "brew update failed; continuing with existing metadata"

  # `brew bundle` is idempotent: already-installed formulae are skipped.
  # We don't abort on partial failure — the summary + `brew bundle check`
  # below report exactly what's missing so a re-run can finish it.
  log_info "brew bundle (this can take a while for large casks)…"
  retry brew bundle --file="${brewfile}" --no-lock || log_warn "brew bundle reported errors"

  if brew bundle check --file="${brewfile}" >/dev/null 2>&1; then
    log_ok "all Brewfile dependencies satisfied"
    return 0
  else
    log_warn "some Brewfile dependencies are still missing:"
    brew bundle check --file="${brewfile}" --verbose 2>&1 | tee -a "${LOG_FILE}" || true
    return 1
  fi
}
