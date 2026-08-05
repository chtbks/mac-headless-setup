#!/usr/bin/env bash
# 92-agent-sessions.sh — install the remote-session launcher and the Hermes skill
# that drives it.
#
# Two artifacts:
#   ~/spawn-session.sh                  the launcher (bin/spawn-session.sh here)
#   ~/.hermes/skills/autonomous-ai-agents/spawn-claude-session/
#                                       the skill Hermes loads to call it
#
# One launcher covers all three agents; `--agent` defaults to claude and the
# skill only passes codex/cursor when the user explicitly asks. See
# docs/remote-agent-sessions.md for why each agent's remote path differs.
#
# Sourced by setup.sh; defines module_main.

WORKSPACE_DIR="${WORKSPACE_DIR:-${HOME}/workspace}"
HERMES_HOME="${HERMES_HOME:-${HOME}/.hermes}"
LAUNCHER_DEST="${LAUNCHER_DEST:-${HOME}/spawn-session.sh}"
SKILL_DEST_DIR="${HERMES_HOME}/skills/autonomous-ai-agents/spawn-claude-session"

module_main() {
  export PATH="${HOME}/.local/bin:${PATH}"

  have tmux || { log_error "tmux missing (Brewfile step incomplete) — the launcher runs every session in tmux"; return 1; }
  have git  || { log_error "git missing"; return 1; }

  _install_launcher || return 1
  _install_skill    || return 1
  _report_agents
  return 0
}

# --- launcher --------------------------------------------------------------
_install_launcher() {
  local src="${REPO_ROOT}/bin/spawn-session.sh"
  [[ -f "${src}" ]] || { log_error "missing ${src}"; return 1; }

  if ! bash -n "${src}"; then
    log_error "${src} has a syntax error; refusing to install"
    return 1
  fi

  # Keep a backup when replacing a launcher that differs, so local edits made
  # directly on the host are recoverable.
  if [[ -f "${LAUNCHER_DEST}" ]] && ! cmp -s "${src}" "${LAUNCHER_DEST}"; then
    local backup="${LAUNCHER_DEST}.macsetup.bak.$(date +%s)"
    cp "${LAUNCHER_DEST}" "${backup}"
    log_warn "replacing ${LAUNCHER_DEST} (backup: ${backup})"
  fi

  install -m 0755 "${src}" "${LAUNCHER_DEST}"
  log_ok "installed launcher at ${LAUNCHER_DEST}"

  if [[ ! -d "${WORKSPACE_DIR}" ]]; then
    log_warn "${WORKSPACE_DIR} does not exist yet — the launcher resolves projects beneath it"
    add_manual_todo "Clone the project repositories into ${WORKSPACE_DIR} (the launcher takes a direct child name as its project argument)"
  fi
  return 0
}

# --- Hermes skill ----------------------------------------------------------
_install_skill() {
  local tmpl_dir="${REPO_ROOT}/templates/hermes-skills/spawn-claude-session"
  local tmpl="${tmpl_dir}/SKILL.md.tmpl"
  [[ -f "${tmpl}" ]] || { log_error "missing ${tmpl}"; return 1; }

  mkdir -p "${SKILL_DEST_DIR}/agents"

  # The skill text names absolute paths, so render ${HOME}/${WORKSPACE_DIR}.
  local rendered="${SKILL_DEST_DIR}/SKILL.md"
  if [[ -f "${rendered}" ]]; then
    cp "${rendered}" "${rendered}.macsetup.bak.$(date +%s)"
  fi
  HOME="${HOME}" WORKSPACE_DIR="${WORKSPACE_DIR}" _render_skill "${tmpl}" "${rendered}"
  log_ok "installed skill at ${rendered}"

  if [[ -f "${tmpl_dir}/agents/openai.yaml" ]]; then
    cp "${tmpl_dir}/agents/openai.yaml" "${SKILL_DEST_DIR}/agents/openai.yaml"
  fi

  # Hermes snapshots the skill prompt; a running gateway needs a nudge to notice.
  if have hermes && pgrep -f 'hermes.*gateway' >/dev/null 2>&1; then
    add_manual_todo "Restart the Hermes gateway so it reloads the updated skill: hermes gateway run --replace"
  fi
  return 0
}

# _render_skill <src> <dst> — substitute ${HOME} and ${WORKSPACE_DIR}. envsubst
# is limited to those two names so nothing else in the prose is touched.
_render_skill() {
  local src="$1" dst="$2"
  if have envsubst; then
    envsubst '${HOME} ${WORKSPACE_DIR}' <"${src}" >"${dst}"
  else
    sed -e "s|\${WORKSPACE_DIR}|${WORKSPACE_DIR}|g" \
        -e "s|\${HOME}|${HOME}|g" \
        "${src}" >"${dst}"
  fi
}

# --- report ----------------------------------------------------------------
# Which agents the launcher can actually reach right now.
_report_agents() {
  local agent bin
  for agent in claude codex cursor; do
    case "${agent}" in
      cursor) bin=cursor-agent ;;
      *)      bin="${agent}" ;;
    esac
    if have "${bin}"; then
      log_ok "launcher agent available: --agent ${agent} (${bin})"
    else
      log_warn "launcher agent unavailable: --agent ${agent} (${bin} not installed)"
    fi
  done
  log_info "usage: ${LAUNCHER_DEST} [--agent claude|codex|cursor] <project> <display-name> [additional-project ...]"
  return 0
}
