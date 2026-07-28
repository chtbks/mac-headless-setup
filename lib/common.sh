#!/usr/bin/env bash
# lib/common.sh — shared framework for the MacSetup bootstrap.
#
# Provides: logging, a resilient/resumable run-step engine with dependency
# awareness, network retry-with-backoff, one-time sudo + keepalive, a layered
# secret resolver (LastPass -> config.env -> interactive prompt), and
# human-in-the-loop checkpoints.
#
# Sourced by setup.sh and every scripts/*.sh module. Not meant to be executed
# directly.

# ---------------------------------------------------------------------------
# Strictness. We deliberately do NOT use `set -e`: the run-step engine is
# responsible for tolerating failures so the run is resilient and resumable.
# ---------------------------------------------------------------------------
set -uo pipefail

# ---------------------------------------------------------------------------
# Paths. REPO_ROOT is resolved from this file's location so it works whether
# invoked via ./setup.sh or from the curl|bash bootstrap clone.
# ---------------------------------------------------------------------------
COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${COMMON_SH_DIR}/.." && pwd)"
LOG_DIR="${REPO_ROOT}/log"
STATE_DIR="${LOG_DIR}/state"
CONFIG_ENV="${REPO_ROOT}/config.env"
mkdir -p "${STATE_DIR}"

# One log file per run. RUN_ID is stable for the life of the process.
RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/setup-${RUN_ID}.log"

# Set MACSETUP_FORCE=1 to ignore completion markers and re-run every step.
FORCE="${MACSETUP_FORCE:-0}"
# Set MACSETUP_NONINTERACTIVE=1 to auto-skip every human checkpoint.
NONINTERACTIVE="${MACSETUP_NONINTERACTIVE:-0}"

# ---------------------------------------------------------------------------
# Colors (disabled when not a TTY, e.g. piped logs).
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BOLD=""
fi

# ---------------------------------------------------------------------------
# Logging. Every message is timestamped and appended to LOG_FILE as well as
# shown on the console.
# ---------------------------------------------------------------------------
_log() { # level color message...
  local level="$1" color="$2"; shift 2
  local line="[$(date +%H:%M:%S)] [${level}] $*"
  printf '%s%s%s\n' "${color}" "${line}" "${C_RESET}"
  printf '%s\n' "${line}" >>"${LOG_FILE}"
}
log_info()  { _log INFO  "${C_BLU}" "$@"; }
log_ok()    { _log OK    "${C_GRN}" "$@"; }
log_warn()  { _log WARN  "${C_YEL}" "$@"; }
log_error() { _log ERROR "${C_RED}" "$@"; }
log_step()  { printf '\n%s== %s ==%s\n' "${C_BOLD}" "$*" "${C_RESET}"; printf '\n== %s ==\n' "$*" >>"${LOG_FILE}"; }

# run_logged "description" cmd args... — run a command, streaming its output to
# both console and log file, returning the command's exit status.
run_logged() {
  local desc="$1"; shift
  log_info "\$ $*"
  # shellcheck disable=SC2069
  "$@" > >(tee -a "${LOG_FILE}") 2>&1
  return "${PIPESTATUS[0]}"
}

# ---------------------------------------------------------------------------
# Retry with exponential backoff — for network-bound commands (brew, npm, git,
# xcodes, curl). Retries up to MACSETUP_RETRIES times (default 3).
# ---------------------------------------------------------------------------
retry() {
  local max="${MACSETUP_RETRIES:-3}" delay=5 attempt=1 rc=0
  while true; do
    "$@" && return 0
    rc=$?
    if (( attempt >= max )); then
      log_warn "command failed after ${attempt} attempts (rc=${rc}): $*"
      return "${rc}"
    fi
    log_warn "attempt ${attempt}/${max} failed (rc=${rc}); retrying in ${delay}s..."
    sleep "${delay}"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

# ---------------------------------------------------------------------------
# Run-step engine.
#
#   run_step <id> "<description>" <fn> [dep_id ...]
#
# - Skips if log/state/<id>.done exists (unless MACSETUP_FORCE=1).
# - Skips if any declared dependency did not complete this session
#   (dependency's marker absent) — recording it as SKIPPED, not FAILED.
# - On success: writes the marker, records COMPLETED.
# - On failure: records FAILED and CONTINUES (resilience). Steps that depend on
#   a failed step are skipped automatically on the same run.
#
# Summary arrays are printed by print_summary at the end.
# ---------------------------------------------------------------------------
declare -a STEPS_COMPLETED=()
declare -a STEPS_SKIPPED=()
declare -a STEPS_FAILED=()
declare -a MANUAL_TODO=()

_marker() { echo "${STATE_DIR}/$1.done"; }

step_is_done() { [[ -f "$(_marker "$1")" ]]; }

# Record a manual follow-up for the end-of-run checklist.
add_manual_todo() { MANUAL_TODO+=("$1"); }

run_step() {
  local id="$1" desc="$2" fn="$3"; shift 3
  local deps=("$@")

  log_step "${desc}  (${id})"

  # Dependency gate.
  local dep
  for dep in "${deps[@]:-}"; do
    [[ -z "${dep}" ]] && continue
    if ! step_is_done "${dep}"; then
      log_warn "skipping '${id}': dependency '${dep}' not satisfied"
      STEPS_SKIPPED+=("${id} (needs ${dep})")
      return 0
    fi
  done

  # Idempotency gate.
  if [[ "${FORCE}" != "1" ]] && step_is_done "${id}"; then
    log_ok "already done — skipping '${id}' (set MACSETUP_FORCE=1 to redo)"
    STEPS_SKIPPED+=("${id} (already done)")
    return 0
  fi

  # Execute.
  if "${fn}"; then
    touch "$(_marker "${id}")"
    log_ok "completed '${id}'"
    STEPS_COMPLETED+=("${id}")
    return 0
  else
    local rc=$?
    log_error "step '${id}' failed (rc=${rc}) — continuing; re-run to resume"
    STEPS_FAILED+=("${id}")
    return 0  # resilience: never abort the whole run
  fi
}

print_summary() {
  log_step "Summary"
  printf '%s  Completed: %d   Skipped: %d   Failed: %d%s\n' \
    "${C_BOLD}" "${#STEPS_COMPLETED[@]}" "${#STEPS_SKIPPED[@]}" "${#STEPS_FAILED[@]}" "${C_RESET}"
  local x
  if ((${#STEPS_FAILED[@]})); then
    printf '%sFailed steps (re-run setup.sh to retry):%s\n' "${C_RED}" "${C_RESET}"
    for x in "${STEPS_FAILED[@]}"; do printf '  %s- %s%s\n' "${C_RED}" "${x}" "${C_RESET}"; done
  fi
  if ((${#MANUAL_TODO[@]})); then
    printf '\n%sManual steps still to finish:%s\n' "${C_YEL}" "${C_RESET}"
    for x in "${MANUAL_TODO[@]}"; do printf '  %s- %s%s\n' "${C_YEL}" "${x}" "${C_RESET}"; done
  fi
  printf '\nFull log: %s\n' "${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Sudo — validate once, then keep the timestamp warm in the background so no
# individual step re-prompts. The password is never stored.
# ---------------------------------------------------------------------------
SUDO_KEEPALIVE_PID=""
ensure_sudo() {
  if sudo -n true 2>/dev/null; then
    log_info "sudo already available (passwordless or cached)"
  else
    log_info "Requesting sudo — some steps need administrator rights."
    if ! sudo -v; then
      log_error "sudo validation failed; privileged steps will fail"
      return 1
    fi
  fi
  # Background keepalive; dies with the parent shell.
  ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
  SUDO_KEEPALIVE_PID=$!
}
stop_sudo_keepalive() { [[ -n "${SUDO_KEEPALIVE_PID}" ]] && kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Secret resolver — layered: LastPass (lpass) -> config.env -> prompt.
#
#   get_secret <ENV_VAR_NAME> "<lpass-entry/field>" ["prompt text"] [--optional]
#
# Resolution order:
#   1. If the variable is already exported in the environment, use it.
#   2. If `lpass` is installed and logged in, try `lpass show`.
#   3. If config.env defines it (it's sourced into the environment), use that.
#   4. Otherwise prompt interactively (silent). --optional allows empty.
#
# Resolved values are cached back into the variable for the rest of the run.
# ---------------------------------------------------------------------------
lpass_available() { command -v lpass >/dev/null 2>&1 && lpass status -q 2>/dev/null; }

get_secret() {
  local var="$1" lpass_ref="$2" prompt="${3:-Enter value for ${1}}" optional=0
  [[ "${4:-}" == "--optional" ]] && optional=1

  # 1. Already set (env or previously sourced config.env).
  if [[ -n "${!var:-}" ]]; then printf '%s' "${!var}"; return 0; fi

  # 2. LastPass.
  if [[ -n "${lpass_ref}" ]] && lpass_available; then
    local v
    v="$(lpass show --password "${lpass_ref}" 2>/dev/null || true)"
    [[ -z "${v}" ]] && v="$(lpass show --field="${lpass_ref#*/}" "${lpass_ref%%/*}" 2>/dev/null || true)"
    if [[ -n "${v}" ]]; then
      printf -v "${var}" '%s' "${v}"; export "${var?}"
      printf '%s' "${v}"; return 0
    fi
  fi

  # 3/4. Prompt (config.env would already have populated the var in step 1).
  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    if (( optional )); then printf ''; return 0; fi
    log_warn "secret '${var}' unavailable and running non-interactively"
    return 1
  fi
  local v
  printf '%s%s: %s' "${C_BOLD}" "${prompt}" "${C_RESET}" >&2
  read -r -s v; printf '\n' >&2
  if [[ -z "${v}" ]] && (( ! optional )); then
    log_warn "no value entered for '${var}'"
    return 1
  fi
  printf -v "${var}" '%s' "${v}"; export "${var?}"
  printf '%s' "${v}"
}

# ---------------------------------------------------------------------------
# Human-in-the-loop checkpoint. Prints instructions, waits for input; an empty
# line (or non-interactive mode) skips and records a manual TODO.
#
#   checkpoint "<todo label>" "<multi-line instructions>"  -> echoes the entered
#   value on stdout, or empty string if skipped.
# ---------------------------------------------------------------------------
checkpoint() {
  local todo="$1" instructions="$2"
  printf '\n%s%s%s\n' "${C_YEL}${C_BOLD}" "----- ACTION NEEDED -----" "${C_RESET}" >&2
  printf '%s\n' "${instructions}" >&2
  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    log_warn "non-interactive: skipping checkpoint '${todo}'"
    add_manual_todo "${todo}"
    printf ''
    return 0
  fi
  printf '%sPaste the value and press Enter (or just Enter to skip): %s' "${C_BOLD}" "${C_RESET}" >&2
  local v; read -r v
  if [[ -z "${v}" ]]; then
    add_manual_todo "${todo}"
    log_warn "skipped '${todo}' — added to manual finish list"
  fi
  printf '%s' "${v}"
}

# ---------------------------------------------------------------------------
# Small helpers.
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# Ensure Homebrew is on PATH for the current shell (Apple Silicon vs Intel).
load_brew_env() {
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

# Load config.env (if present) so its KEY=VALUE lines become environment vars
# for get_secret's layer 3. Values there override nothing already exported.
load_config_env() {
  if [[ -f "${CONFIG_ENV}" ]]; then
    log_info "loading ${CONFIG_ENV}"
    set -a; # shellcheck disable=SC1090
    source "${CONFIG_ENV}"; set +a
  fi
}
