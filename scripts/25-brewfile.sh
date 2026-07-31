#!/usr/bin/env bash
# 25-brewfile.sh — install everything in the Brewfile.
# Sourced by setup.sh; defines module_main.

module_main() {
  load_brew_env
  have brew || { log_error "brew not available"; return 1; }

  local brewfile="${REPO_ROOT}/Brewfile"
  [[ -f "${brewfile}" ]] || { log_error "Brewfile missing at ${brewfile}"; return 1; }

  # On the newest macOS, Homebrew's git bottle links a newer libcurl than the
  # system provides (_curl_global_trace not found), crashing git-remote-https —
  # which breaks `brew update` and any HTTPS git clone. We don't need brew git
  # (the Command Line Tools git works with the system libcurl), so remove it if
  # a prior run installed it and let git resolve to /usr/bin/git.
  if brew list --formula git >/dev/null 2>&1; then
    log_warn "removing Homebrew git (using system CLT git; avoids libcurl symbol mismatch)"
    brew uninstall --ignore-dependencies --force git >>"${LOG_FILE}" 2>&1 || true
    hash -r 2>/dev/null || true
  fi

  # Skip the git-based tap update; formula definitions come from the Homebrew
  # API over curl, so bottle installs don't need a (possibly broken) git fetch.
  export HOMEBREW_NO_AUTO_UPDATE=1

  # `brew bundle` is idempotent: already-installed formulae are skipped.
  # We don't abort on partial failure — the summary + `brew bundle check`
  # below report exactly what's missing so a re-run can finish it.
  # Newer Homebrew removed `--no-lock` (brew bundle no longer writes a lockfile),
  # so we don't pass it. A stray Brewfile.lock.json, if one exists, is harmless.
  log_info "brew bundle (this can take a while for large casks)…"
  retry brew bundle --file="${brewfile}" || log_warn "brew bundle reported errors"

  if brew bundle check --file="${brewfile}" >/dev/null 2>&1; then
    log_ok "all Brewfile dependencies satisfied"
    return 0
  else
    log_warn "some Brewfile dependencies are still missing:"
    brew bundle check --file="${brewfile}" --verbose 2>&1 | tee -a "${LOG_FILE}" || true
    return 1
  fi
}
