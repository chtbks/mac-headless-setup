#!/usr/bin/env bash
# 99-verify.sh — doctor: report the state of everything we set up. Never fails
# the run (it's diagnostic); it just prints a health table to console + log.
# Sourced by setup.sh; defines module_main.

module_main() {
  load_brew_env
  export PATH="${HOME}/.local/bin:${PATH}"

  local pass=0 fail=0

  _check() { # label  test-command...
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
      log_ok "OK   ${label}"; pass=$((pass+1))
    else
      log_warn "MISS ${label}"; fail=$((fail+1))
    fi
  }

  _check "Command Line Tools"      xcode-select -p
  _check "Homebrew"                brew --version
  _check "git (brew)"              git --version
  _check "node"                    node --version
  _check "jq"                      jq --version
  _check "lastpass-cli"            command -v lpass
  _check "oh-my-zsh"               test -d "${HOME}/.oh-my-zsh"
  _check "gh (GitHub CLI)"         command -v gh
  _check "GitHub authenticated"    bash -c 'gh auth status --hostname github.com >/dev/null 2>&1'
  _check "chtbks org reachable"    bash -c 'gh repo list chtbks --limit 1 >/dev/null 2>&1'
  _check "git identity set"        bash -c 'test -n "$(git config --global user.email)"'
  _check "Claude Code"             command -v claude
  _check "XcodeBuildMCP registered" bash -c 'claude mcp list 2>/dev/null | grep -qi xcodebuildmcp'
  _check "xcodes"                  command -v xcodes
  _check "full Xcode selected"     bash -c 'xcode-select -p 2>/dev/null | grep -q Xcode.app'
  _check "tailscale binary"        command -v tailscale
  _check "tailscale connected"     bash -c 'tailscale status >/dev/null 2>&1 && ! tailscale status 2>/dev/null | grep -qi "Logged out"'
  _check "Remote Login (SSH) on"   bash -c 'sudo -n systemsetup -getremotelogin 2>/dev/null | grep -qi On'
  _check "openclaw CLI"            command -v openclaw

  log_info "doctor: ${pass} OK, ${fail} missing/incomplete"
  # Always succeed — diagnostics shouldn't mark the run failed.
  return 0
}
