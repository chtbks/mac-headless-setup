#!/usr/bin/env bash
# 60-xcodebuildmcp.sh — install the XcodeBuildMCP CLI globally.
#
# We use XcodeBuildMCP as a command-line tool, not as a registered MCP server.
# A global npm install puts two binaries on PATH:
#   - `xcodebuildmcp`         (the CLI)
#   - `xcodebuildmcp-doctor`  (environment diagnostics)
#
# NOTE: the source doc's package name `@sentry/xcodebuildmcp` is wrong; the real
# package is `xcodebuildmcp` (unscoped, by getsentry).
#
# Sourced by setup.sh; defines module_main.

# Pin for reproducibility; bump deliberately. Set to a version or "latest".
XCODEBUILDMCP_VERSION="${XCODEBUILDMCP_VERSION:-latest}"

module_main() {
  load_brew_env

  have node || { log_error "node missing (Brewfile step incomplete)"; return 1; }
  have npm  || { log_error "npm missing (node install incomplete)"; return 1; }

  if have xcodebuildmcp; then
    log_ok "xcodebuildmcp CLI already installed ($(_xbmcp_version))"
  else
    log_info "installing xcodebuildmcp CLI globally (npm)…"
    if ! retry npm install -g "xcodebuildmcp@${XCODEBUILDMCP_VERSION}"; then
      log_error "npm install -g xcodebuildmcp failed"
      return 1
    fi
    hash -r 2>/dev/null || true
    have xcodebuildmcp || { log_error "xcodebuildmcp not on PATH after install"; return 1; }
    log_ok "installed xcodebuildmcp CLI ($(_xbmcp_version))"
  fi

  log_info "xcodebuildmcp CLI ready — run 'xcodebuildmcp-doctor' to verify the Xcode/simulator environment"
  return 0
}

# Report the installed version from npm metadata (don't execute the CLI bare —
# with no recognized args it may start the stdio server and block).
_xbmcp_version() {
  npm ls -g xcodebuildmcp --depth=0 2>/dev/null \
    | sed -nE 's/.*xcodebuildmcp@([0-9][0-9.]*).*/\1/p' | head -n1
}
