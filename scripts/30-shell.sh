#!/usr/bin/env bash
# 30-shell.sh — install oh-my-zsh (near-vanilla) and ensure our tools are on
# PATH for interactive login shells.
# Sourced by setup.sh; defines module_main.

module_main() {
  # zsh is already the default shell on modern macOS; we don't chsh.
  export RUNZSH=no CHSH=no KEEP_ZSHRC=yes

  if [[ -d "${HOME}/.oh-my-zsh" ]]; then
    log_ok "oh-my-zsh already installed"
  else
    log_info "installing oh-my-zsh (unattended)…"
    if ! retry sh -c \
        "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
        "" --unattended; then
      log_error "oh-my-zsh install failed"
      return 1
    fi
  fi

  # Ensure a .zshrc exists and sources oh-my-zsh + brew + local bin.
  local zshrc="${HOME}/.zshrc"
  [[ -f "${zshrc}" ]] || : >"${zshrc}"

  _ensure_line() { grep -qsF "$1" "${zshrc}" 2>/dev/null || printf '%s\n' "$1" >>"${zshrc}"; }

  {
    if ! grep -qs 'MacSetup PATH' "${zshrc}"; then
      printf '\n# --- MacSetup PATH ---\n'
    fi
  } >>"${zshrc}"
  _ensure_line 'export PATH="$HOME/.local/bin:$PATH"'   # Claude Code native install
  _ensure_line '[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"'

  # Keep a sane default theme if oh-my-zsh set one; don't fight KEEP_ZSHRC.
  log_ok "shell configured (oh-my-zsh, PATH ensured)"
  return 0
}
