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
  _check "git (system CLT)"        git --version
  _check "Git LFS filters"         bash -c 'git config --global --get filter.lfs.process >/dev/null 2>&1'
  _check "swiftlint"               command -v swiftlint
  _check "swift-format"            command -v swift-format
  _check "Chatbooks build secrets" test -f "${HOME}/.chatbooks-build.env"
  _check "node"                    node --version
  _check "jq"                      jq --version
  _check "python@3.14"             command -v python3.14
  _check "lastpass-cli"            command -v lpass
  _check "oh-my-zsh"               test -d "${HOME}/.oh-my-zsh"
  _check "gh (GitHub CLI)"         command -v gh
  _check "GitHub authenticated"    bash -c 'gh auth status --hostname github.com >/dev/null 2>&1'
  _check "chtbks org reachable"    bash -c 'gh repo list chtbks --limit 1 >/dev/null 2>&1'
  _check "git identity set"        bash -c 'test -n "$(git config --global user.email)"'
  _check "Claude Code"             command -v claude
  _check "xcodebuildmcp CLI"       command -v xcodebuildmcp
  _check "xcodes"                  command -v xcodes
  _check "full Xcode selected"     bash -c 'xcode-select -p 2>/dev/null | grep -q Xcode.app'
  _check "tailscale binary"        command -v tailscale
  _check "tailscale connected"     bash -c 'tailscale status >/dev/null 2>&1 && ! tailscale status 2>/dev/null | grep -qi "Logged out"'
  _check "Remote Login (SSH) on"   bash -c 'sudo -n systemsetup -getremotelogin 2>/dev/null | grep -qi On'

  # --- Agent hosts ----------------------------------------------------------
  _check "tmux"                    command -v tmux
  _check "Codex CLI"               command -v codex
  _check "Codex authenticated"     bash -c 'codex login status >/dev/null 2>&1'
  _check "Codex remote control"    bash -c 'codex remote-control start >/dev/null 2>&1'
  _check "Cursor CLI"              command -v cursor-agent
  _check "Cursor authenticated"    bash -c 'cursor-agent status >/dev/null 2>&1'

  # --- Hermes + session launcher -------------------------------------------
  _check "hermes CLI"              command -v hermes
  _check "Hermes config"           test -f "${HOME}/.hermes/config.yaml"
  _check "Hermes Slack channel"    bash -c 'grep -qE "^\s*slack:" "${HOME}/.hermes/config.yaml" 2>/dev/null'
  _check "Hermes gateway running"  bash -c 'pgrep -f "hermes.*gateway" >/dev/null 2>&1'
  _check "session launcher"        test -x "${HOME}/spawn-session.sh"
  _check "spawn-session skill"     test -f "${HOME}/.hermes/skills/autonomous-ai-agents/spawn-claude-session/SKILL.md"
  _check "ticketflow CLI"          test -x "${HOME}/.local/bin/ticketflow"
  _check "ticketflow config"       test -f "${HOME}/.config/ticketflow/env"
  _check "ticketflow doctor"       ticketflow doctor
  _check "ticketflow launchd job"  launchctl print "gui/$(id -u)/ai.chatbooks.ticketflow"

  log_info "doctor: ${pass} OK, ${fail} missing/incomplete"
  # Always succeed — diagnostics shouldn't mark the run failed.
  return 0
}
