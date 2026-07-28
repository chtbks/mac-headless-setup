#!/usr/bin/env bash
# 60-xcodebuildmcp.sh — register XcodeBuildMCP with Claude Code.
#
# Corrects the source doc, which used the wrong npm package name
# (`@sentry/xcodebuildmcp`) and never actually registered the server with any
# agent. The real package is `xcodebuildmcp` (unscoped, by getsentry). We run it
# via `npx` pinned to a version for reproducibility — no global install.
#
# OpenClaw registration is intentionally left as a TODO: OpenClaw's real MCP
# mechanism is unverified (see docs/ and README). Fill in once confirmed.
#
# Sourced by setup.sh; defines module_main.

# Pin the version for reproducible builds. Bump deliberately.
XCODEBUILDMCP_VERSION="${XCODEBUILDMCP_VERSION:-latest}"

module_main() {
  load_brew_env
  export PATH="${HOME}/.local/bin:${PATH}"

  have node || { log_error "node missing (Brewfile step incomplete)"; return 1; }
  have claude || { log_error "claude missing (55-claude-code incomplete)"; return 1; }

  # Sanity-check the package resolves before wiring it up.
  log_info "verifying xcodebuildmcp@${XCODEBUILDMCP_VERSION} resolves on npm…"
  if ! retry npm view "xcodebuildmcp@${XCODEBUILDMCP_VERSION}" version >/dev/null 2>&1; then
    log_error "npm package 'xcodebuildmcp' did not resolve — check the name/version"
    return 1
  fi

  # Register with Claude Code at user scope so all projects see it.
  # If it's already registered, `claude mcp add` may error; treat as idempotent.
  if claude mcp list 2>/dev/null | grep -qi 'xcodebuildmcp'; then
    log_ok "XcodeBuildMCP already registered with Claude Code"
  else
    log_info "registering XcodeBuildMCP with Claude Code (user scope)…"
    if claude mcp add xcodebuildmcp --scope user -- \
         npx -y "xcodebuildmcp@${XCODEBUILDMCP_VERSION}" 2>&1 | tee -a "${LOG_FILE}"; then
      log_ok "registered XcodeBuildMCP"
    else
      log_error "claude mcp add failed"
      return 1
    fi
  fi

  # -------------------------------------------------------------------------
  # TODO(openclaw): register XcodeBuildMCP with OpenClaw's code agent once its
  # real MCP configuration is confirmed. Placeholder so it shows in the summary.
  # -------------------------------------------------------------------------
  add_manual_todo "Register XcodeBuildMCP with OpenClaw's code agent (mechanism TBD — see docs/openclaw-ios-agent-setup-v1.md)"

  log_info "XcodeBuildMCP wired to Claude Code; OpenClaw registration pending verification"
  return 0
}
