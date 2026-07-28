#!/usr/bin/env bash
# 40-xcode.sh — install full Xcode via `xcodes` when an Apple ID is available,
# then accept the license and run first-launch. Falls back to CLT-only.
#
# NOTE (flagged in planning): xcodes authenticates with your Apple ID and will
# prompt for 2FA. That is an interactive checkpoint — on a headless box you must
# be present for the 2FA code the first time.
#
# Sourced by setup.sh; defines module_main.

module_main() {
  load_brew_env

  # If a full Xcode.app is already selected, just finalize it.
  if xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    log_ok "full Xcode already selected ($(xcode-select -p))"
    _finalize_xcode
    return $?
  fi

  if ! have xcodes; then
    log_warn "xcodes not installed; leaving Command Line Tools as the toolchain"
    add_manual_todo "Install full Xcode (App Store or 'xcodes install --latest'), then re-run: ./setup.sh --only 40-xcode"
    return 0
  fi

  # Apple ID is optional. Without it we cannot install full Xcode headlessly.
  local apple_id
  apple_id="$(get_secret XCODES_USERNAME "MacSetup/apple-id" "Apple ID email for Xcode download" --optional)"
  if [[ -z "${apple_id}" ]]; then
    log_warn "no Apple ID provided; skipping full Xcode install (CLT remains)"
    add_manual_todo "Provide XCODES_USERNAME/XCODES_PASSWORD (or run 'xcodes install --latest' interactively) to get full Xcode"
    return 0
  fi
  export XCODES_USERNAME="${apple_id}"
  # Password is optional up front; xcodes will prompt if absent.
  local pw; pw="$(get_secret XCODES_PASSWORD "MacSetup/apple-id" "Apple ID password (blank to let xcodes prompt)" --optional)"
  [[ -n "${pw}" ]] && export XCODES_PASSWORD="${pw}"

  log_info "installing latest Xcode via xcodes (expect a 2FA prompt)…"
  if ! xcodes install --latest --experimental-unxip 2>&1 | tee -a "${LOG_FILE}"; then
    log_error "xcodes install failed"
    add_manual_todo "Finish Xcode install: run 'xcodes install --latest' interactively"
    return 1
  fi

  # Point the toolchain at the newly installed Xcode.
  local xpath
  xpath="$(xcodes installed 2>/dev/null | tail -n1 | awk '{print $NF}')"
  if [[ -d "${xpath}" ]]; then
    run_logged "select ${xpath}" sudo xcode-select -s "${xpath}/Contents/Developer" || true
  fi

  _finalize_xcode
}

_finalize_xcode() {
  log_info "accepting Xcode license + first-launch…"
  run_logged "license accept" sudo xcodebuild -license accept || log_warn "license accept failed"
  run_logged "runFirstLaunch" sudo xcodebuild -runFirstLaunch || log_warn "runFirstLaunch failed"
  # Enable developer mode for device debugging (harmless on a build host).
  sudo DevToolsSecurity -enable >/dev/null 2>&1 || true
  log_ok "Xcode finalized"
  return 0
}
