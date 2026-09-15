#!/usr/bin/env bash
# 57-cursor.sh — install the Cursor CLI (`cursor-agent`).
#
# Cursor's remote surface is a named private worker: `cursor-agent worker start
# --name <name> --worker-dir <dir>` registers with Cursor and returns a
# cursor.com/agents#workerId=… link, so unlike Codex each session IS individually
# addressable. This module also installs a persistent worker for the existing
# main checkouts. Separate, temporary worktree workers can still be started by
# bin/spawn-session.sh (installed by 92-agent-sessions).
#
# Login is interactive (browser), so it is a checkpoint.
#
# Sourced by setup.sh; defines module_main.

module_main() {
  export PATH="${HOME}/.local/bin:${PATH}"

  _cursor_install || return 1
  _cursor_login
  _cursor_service || return 1
  return 0
}

_cursor_service() {
  if ! cursor-agent status >/dev/null 2>&1; then
    add_manual_todo "After Cursor login and cloning repos, run: ./bin/install-cursor-service"
    return 0
  fi
  local workspace="${WORKSPACE_DIR:-${HOME}/workspace}" project
  local roots=()
  for project in artemis iphone backend fluttershy chatty-family; do
    [[ -d "${workspace}/${project}" ]] && roots+=("${workspace}/${project}")
  done
  if [[ "${#roots[@]}" -eq 0 ]]; then
    log_warn "No Cursor repository roots exist yet; deferring the persistent worker"
    add_manual_todo "After cloning repos, run: ./bin/install-cursor-service /absolute/repo/path [more/repo/paths]"
    return 0
  fi
  have python3 || { log_error "python3 missing; install Python 3, then retry 57-cursor"; return 1; }
  run_logged "install Cursor login/recovery worker" \
    python3 "${REPO_ROOT}/bin/install-cursor-service" "${roots[@]}"
}

_cursor_install() {
  if have cursor-agent; then
    log_ok "Cursor CLI already installed ($(cursor-agent --version 2>/dev/null || echo present))"
    return 0
  fi

  log_info "installing Cursor CLI (official installer)…"
  if ! retry bash -c 'curl -fsSL https://cursor.com/install | bash'; then
    log_error "Cursor CLI install failed"
    return 1
  fi
  hash -r 2>/dev/null || true

  if ! have cursor-agent; then
    log_warn "cursor-agent not on PATH yet; ensure ~/.local/bin is on PATH (30-shell handles login shells)"
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
  have cursor-agent || { log_error "cursor-agent not on PATH after install"; return 1; }
  log_ok "Cursor CLI ready ($(cursor-agent --version 2>/dev/null || echo present))"
  return 0
}

_cursor_login() {
  # `cursor-agent status` exits non-zero when signed out; a worker cannot
  # register with Cursor without it.
  if cursor-agent status >/dev/null 2>&1; then
    log_ok "Cursor authenticated ($(cursor-agent status 2>/dev/null | head -n1))"
    return 0
  fi

  local instructions
  instructions=$(cat <<'EOF'
Cursor needs a login before a worker can register. On this machine:

    cursor-agent login

Set NO_OPEN_BROWSER=1 first if you are on SSH and want the URL printed instead
of a browser launch.

Press Enter once the login has completed (nothing to paste).
EOF
)
  checkpoint "Run 'cursor-agent login' so Cursor workers can register" "${instructions}" >/dev/null

  if cursor-agent status >/dev/null 2>&1; then
    log_ok "Cursor authenticated"
  else
    log_warn "Cursor still signed out — 'spawn-session.sh --agent cursor' will refuse to launch"
  fi
  return 0
}
