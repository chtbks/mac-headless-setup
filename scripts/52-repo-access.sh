#!/usr/bin/env bash
# 52-repo-access.sh — verify the authenticated GitHub user (the qa machine user)
# can actually read every private chtbks SPM dependency the Chatbooks app pulls.
#
# If any are unreadable (no access, or SAML SSO not authorized), SwiftPM package
# resolution 403s and the whole build fails with an opaque error. This check
# surfaces exactly which repos are missing. It returns non-zero until access is
# complete, so it never writes a "done" marker and re-runs on every ./setup.sh
# until all repos are reachable.
#
# List derived from the iphone repo's Package.resolved + Package.swift files.
# Keep in sync if dependencies change.
#
# Sourced by setup.sh; defines module_main.

REQUIRED_CHTBKS_REPOS=(
  artemis
  AppNavigationMacros
  ServerIdentifiableMacros
  ios-api
  chatty-api
  chatty-ui
  chatty-strings
  chatty-uploader
  CustomAlert
  MediaEncoder
  imgly-sdk-ios-2
  rudder-sdk-ios
  braintree_ios
)

module_main() {
  load_brew_env
  have gh || { log_error "gh not installed"; return 1; }

  if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    log_error "not authenticated to GitHub (50-github incomplete)"
    return 1
  fi

  local who; who="$(gh api user -q .login 2>/dev/null || echo '?')"
  log_info "checking chtbks repo access as '${who}' (${#REQUIRED_CHTBKS_REPOS[@]} repos)…"

  local ok=() missing=() r
  for r in "${REQUIRED_CHTBKS_REPOS[@]}"; do
    if gh api "repos/chtbks/${r}" -q .full_name >/dev/null 2>&1; then
      ok+=("${r}")
    else
      missing+=("${r}")
    fi
  done

  local x
  for x in "${ok[@]:-}";      do [[ -n "${x}" ]] && log_ok   "readable   chtbks/${x}"; done
  for x in "${missing[@]:-}"; do [[ -n "${x}" ]] && log_warn "NO ACCESS  chtbks/${x}"; done

  if ((${#missing[@]})); then
    log_error "${#missing[@]}/${#REQUIRED_CHTBKS_REPOS[@]} chtbks repos unreadable by '${who}'"
    add_manual_todo "Grant '${who}' read access (and SSO-authorize) to: ${missing[*]} — then re-run: ./setup.sh --only 52-repo-access"
    return 1
  fi

  log_ok "all ${#REQUIRED_CHTBKS_REPOS[@]} chtbks SPM repos are readable"
  return 0
}
