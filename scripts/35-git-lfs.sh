#!/usr/bin/env bash
# 35-git-lfs.sh — install Git LFS filters globally.
#
# The Chatbooks iOS repo stores its Flutter frameworks and kernel_blob.bin via
# Git LFS (.gitattributes). Without the LFS filters installed, clones pull
# pointer files instead of the real binaries and the build fails. `git lfs
# install` wires the smudge/clean filters into the user's global git config so
# every subsequent clone/pull fetches LFS objects.
#
# Sourced by setup.sh; defines module_main.

module_main() {
  load_brew_env
  have git-lfs || { log_error "git-lfs not installed (Brewfile step incomplete)"; return 1; }

  # Idempotent: safe to run repeatedly; --skip-repo avoids needing a repo here.
  if git config --global --get filter.lfs.process >/dev/null 2>&1; then
    log_ok "Git LFS filters already configured"
    return 0
  fi

  log_info "installing Git LFS filters (global)…"
  if git lfs install --skip-repo >>"${LOG_FILE}" 2>&1; then
    log_ok "Git LFS installed ($(git lfs version 2>/dev/null | head -n1))"
    return 0
  fi
  log_error "git lfs install failed"
  return 1
}
