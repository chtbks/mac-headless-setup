#!/usr/bin/env bash
# 45-macro-trust.sh — let headless xcodebuild builds run Swift macros without
# the interactive macro-trust / fingerprint prompt.
#
# The Chatbooks project depends on Swift-macro packages (chtbks/artemis,
# chtbks/AppNavigationMacros, chtbks/ServerIdentifiableMacros). Xcode 16 gates
# macro plugins behind a per-package-revision fingerprint stored in
# ~/Library/org.swift.swiftpm/security/macros.json, and a GUI trust prompt on
# first use — which a headless agent can't answer. The repo's own
# ci_scripts/ci_post_clone.sh sets the same default on Xcode Cloud.
#
# This is safe here because it's our own repo: package selection is still
# governed by Package.resolved and code review, not by this flag.
#
# Sourced by setup.sh; defines module_main.

module_main() {
  local domain="com.apple.dt.Xcode" key="IDESkipMacroFingerprintValidation"

  if [[ "$(defaults read "${domain}" "${key}" 2>/dev/null)" == "1" ]]; then
    log_ok "macro fingerprint validation already disabled"
    return 0
  fi

  log_info "disabling Swift-macro fingerprint validation for headless builds…"
  if defaults write "${domain}" "${key}" -bool YES; then
    log_ok "set ${domain} ${key} = YES"
    return 0
  fi
  log_error "failed to set ${key}"
  return 1
}
