#!/usr/bin/env bash
# 70-tailscale.sh — install the Tailscale system daemon and join the tailnet.
#
# Auth strategy (from planning): use an auth key if provided
# (fully non-interactive), otherwise fall back to interactive SSO — print the
# login URL and wait, which suits a Google-Workspace tailnet where humans sign
# in via a browser.
#
# Sourced by setup.sh; defines module_main.

module_main() {
  load_brew_env
  have tailscale || { log_error "tailscale not installed (Brewfile step incomplete)"; return 1; }

  # Start tailscaled via Homebrew's service manager, at SYSTEM level (sudo) so it
  # runs headless without a login session. This is the documented way to run the
  # open-source tailscale formula's daemon; the `tailscale install-system-daemon`
  # subcommand only exists on Tailscale's standalone tailscaled binary.
  # Use brew's full path because sudo's PATH may not include the Homebrew prefix.
  local brew_bin; brew_bin="$(command -v brew)"
  if sudo "${brew_bin}" services list 2>/dev/null | grep -qiE '^tailscale[[:space:]]+started'; then
    log_ok "tailscaled already running (brew services)"
  else
    log_info "starting tailscaled (sudo brew services start tailscale)…"
    if ! run_logged "brew services start tailscale" sudo "${brew_bin}" services start tailscale; then
      log_error "failed to start tailscaled"
      return 1
    fi
    sleep 3
  fi

  # Already connected?
  if tailscale status >/dev/null 2>&1 && ! tailscale status 2>/dev/null | grep -qi 'Logged out'; then
    log_ok "already connected to tailnet: $(tailscale ip -4 2>/dev/null | head -n1)"
    return 0
  fi

  # Prefer an auth key.
  local authkey
  authkey="$(get_secret TS_AUTHKEY "MacSetup/tailscale-authkey" "Tailscale auth key" --optional)"

  if [[ -n "${authkey}" ]]; then
    log_info "joining tailnet with auth key…"
    if run_logged "tailscale up (authkey)" sudo tailscale up \
         --authkey="${authkey}" --accept-routes --ssh; then
      log_ok "joined tailnet: $(tailscale ip -4 2>/dev/null | head -n1)"
      return 0
    fi
    log_warn "auth-key join failed; falling back to interactive SSO"
  fi

  # Interactive SSO fallback: start `tailscale up`, surface the login URL.
  log_info "starting interactive login (Google SSO)…"
  # --qr prints a URL (and QR) to authenticate; run without --authkey.
  ( sudo tailscale up --accept-routes --ssh --qr 2>&1 | tee -a "${LOG_FILE}" ) &
  local up_pid=$!
  local msg="Open the Tailscale login URL printed above in a browser and sign in with your work Google account to authorize this machine."
  checkpoint "Complete Tailscale SSO login in a browser" "${msg}" >/dev/null
  wait "${up_pid}" 2>/dev/null || true

  if tailscale status >/dev/null 2>&1 && ! tailscale status 2>/dev/null | grep -qi 'Logged out'; then
    log_ok "joined tailnet: $(tailscale ip -4 2>/dev/null | head -n1)"
    return 0
  fi
  log_error "not connected to tailnet"
  add_manual_todo "Finish Tailscale login: run 'sudo tailscale up --ssh' and authenticate"
  return 1
}
