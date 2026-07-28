#!/usr/bin/env bash
# 20-homebrew.sh — install Homebrew and put it on PATH for this run and future
# login shells.
# Sourced by setup.sh; defines module_main.

module_main() {
  if have brew; then
    log_ok "Homebrew already installed ($(brew --version | head -n1))"
  else
    log_info "installing Homebrew…"
    # NONINTERACTIVE=1 makes the official installer skip its confirmation.
    if ! retry env NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
      log_error "Homebrew install failed"
      return 1
    fi
  fi

  load_brew_env
  if ! have brew; then
    log_error "brew still not on PATH after install"
    return 1
  fi

  # Persist brew shellenv to the zprofile so SSH/login shells get it too.
  local brew_bin; brew_bin="$(command -v brew)"
  local line="eval \"\$(${brew_bin} shellenv)\""
  local zprofile="${HOME}/.zprofile"
  if ! grep -qsF "${line}" "${zprofile}" 2>/dev/null; then
    printf '\n# Homebrew (added by MacSetup)\n%s\n' "${line}" >>"${zprofile}"
    log_info "added brew shellenv to ${zprofile}"
  fi

  log_ok "Homebrew ready ($(brew --prefix))"
  return 0
}
