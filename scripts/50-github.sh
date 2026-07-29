#!/usr/bin/env bash
# 50-github.sh — authenticate the box to GitHub so agents can clone/push
# private chtbks repos.
#
# Strategy (from planning): `gh auth login` device flow. It prints a one-time
# code you enter at https://github.com/login/device on ANY device — so it works
# on a headless box over SSH — then wires up git's credential helper via
# `gh auth setup-git`. Also sets the global git identity used for commits/PRs.
#
# chtbks likely enforces SAML SSO: after login you may still need to authorize
# the session/token for the org. We detect that and surface it as a TODO.
#
# IDENTITY: this box runs as the dedicated Chatbooks QA machine user
# (qa@chatbooks.com). Sign in to the device flow as THAT GitHub account (not a
# personal one), and make sure it has push access to the target chtbks repos.
#
# Sourced by setup.sh; defines module_main.

# Default git identity for the machine user (overridable via config.env / env).
: "${GIT_AUTHOR_NAME:=Chatbooks QA}"
: "${GIT_AUTHOR_EMAIL:=qa@chatbooks.com}"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL

module_main() {
  load_brew_env
  have gh || { log_error "gh not installed (Brewfile step incomplete)"; return 1; }

  # --- Git identity (needed for commits the agent makes) -------------------
  _set_git_identity

  # --- Already authenticated? ---------------------------------------------
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    log_ok "already authenticated to GitHub as $(gh api user -q .login 2>/dev/null || echo '?')"
    _ensure_credential_helper
    _check_org_access
    return 0
  fi

  # --- Optional token fast-path (fully unattended if a PAT is provided) ----
  local token
  token="$(get_secret GITHUB_TOKEN "MacSetup/github-token" "GitHub token (blank to use device-flow login)" --optional)"
  if [[ -n "${token}" ]]; then
    log_info "authenticating with provided token…"
    if printf '%s' "${token}" | gh auth login --hostname github.com --git-protocol https --with-token 2>>"${LOG_FILE}"; then
      log_ok "authenticated to GitHub via token"
      _ensure_credential_helper
      _check_org_access
      return 0
    fi
    log_warn "token login failed; falling back to device flow"
  fi

  # --- Device flow (interactive) -------------------------------------------
  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    log_warn "non-interactive: cannot run GitHub device-flow login"
    add_manual_todo "Authenticate GitHub: run 'gh auth login -h github.com -p https -w' then './setup.sh --only 50-github'"
    return 0
  fi

  log_info "starting GitHub device-flow login — a one-time code will be shown."
  log_info "Open https://github.com/login/device on any device and enter it."
  log_warn "Sign in as the QA machine user (${GIT_AUTHOR_EMAIL}), NOT a personal account."
  # gh drives the terminal here; it prints the code, waits, then verifies.
  # The local browser-open may fail on a headless box — that's fine, use the URL.
  if gh auth login --hostname github.com --git-protocol https --web 2>&1 | tee -a "${LOG_FILE}"; then
    if gh auth status --hostname github.com >/dev/null 2>&1; then
      log_ok "authenticated to GitHub as $(gh api user -q .login 2>/dev/null || echo '?')"
      _ensure_credential_helper
      _check_org_access
      return 0
    fi
  fi

  log_error "GitHub authentication did not complete"
  add_manual_todo "Finish GitHub auth: run 'gh auth login -h github.com -p https -w' then './setup.sh --only 50-github'"
  return 1
}

# Wire gh in as git's credential helper for https (idempotent).
_ensure_credential_helper() {
  log_info "configuring git to use gh as the credential helper…"
  gh auth setup-git --hostname github.com >>"${LOG_FILE}" 2>&1 \
    && log_ok "git credential helper configured" \
    || log_warn "gh auth setup-git returned non-zero"
}

# Set global git user.name / user.email from secrets/config or prompt.
_set_git_identity() {
  local name email
  name="$(get_secret GIT_AUTHOR_NAME "" "git user.name for this box (e.g. Chatbooks Agent)" --optional)"
  email="$(get_secret GIT_AUTHOR_EMAIL "" "git user.email for this box" --optional)"
  if [[ -n "${name}" ]]; then git config --global user.name  "${name}";  log_info "git user.name = ${name}"; fi
  if [[ -n "${email}" ]]; then git config --global user.email "${email}"; log_info "git user.email = ${email}"; fi
  if [[ -z "$(git config --global user.name)" || -z "$(git config --global user.email)" ]]; then
    log_warn "git identity incomplete — commits made by the agent may be rejected"
    add_manual_todo "Set git identity: git config --global user.name/user.email"
  fi
}

# Detect whether org repos are reachable (SAML SSO gate).
_check_org_access() {
  if gh repo list chtbks --limit 1 >/dev/null 2>&1; then
    log_ok "chtbks org repos are reachable"
  else
    log_warn "cannot list chtbks repos — likely SAML SSO not authorized for this session/token"
    add_manual_todo "Authorize GitHub access for the 'chtbks' org (SSO): visit GitHub > Settings > Applications / token SSO, then re-run: ./setup.sh --only 50-github"
  fi
}
