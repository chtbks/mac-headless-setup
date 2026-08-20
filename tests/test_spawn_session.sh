#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

export HOME="${TEST_ROOT}/home"
export USER="ticketflow-test"
export TEST_TMUX_LOG="${TEST_ROOT}/tmux.log"
mkdir -p "${HOME}/.local/bin" "${HOME}/workspace/chatty-family/.git"

cat >"${HOME}/.local/bin/git" <<'FAKE_GIT'
#!/usr/bin/env bash
case "$*" in
  *"show-ref --verify"*) exit 1 ;;
  *) exit 0 ;;
esac
FAKE_GIT

cat >"${HOME}/.local/bin/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
printf '%q ' "$@" >>"${TEST_TMUX_LOG}"
printf '\n' >>"${TEST_TMUX_LOG}"
target=''
previous=''
for argument in "$@"; do
  if [[ "${previous}" == "-t" || "${previous}" == "-s" ]]; then target="${argument%%:*}"; fi
  previous="${argument}"
done
case "${1:-}" in
  has-session) [[ -f "${HOME}/tmux-${target}" ]] ;;
  new-session) touch "${HOME}/tmux-${target}" ;;
  kill-session) rm -f "${HOME}/tmux-${target}" ;;
  display-message) [[ "${FAKE_TMUX_DEAD:-0}" == "1" ]] && printf '1\n' || printf '0\n' ;;
  capture-pane) printf 'Enable Remote Control? (y/n)\n' ;;
esac
FAKE_TMUX

cat >"${HOME}/.local/bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
exit 0
FAKE_CLAUDE

cat >"${HOME}/.local/bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP

chmod +x "${HOME}/.local/bin/"*

PROMPT_FILE="${TEST_ROOT}/prompt.txt"
# Deliberately literal: proves a prompt cannot execute shell syntax.
# shellcheck disable=SC2016
printf '%s\n' 'Run /cb-all for ticket with spaces and $(touch /tmp/ticketflow-injection).' >"${PROMPT_FILE}"

JSON_OUTPUT="$("${ROOT_DIR}/bin/spawn-session.sh" --prompt-file "${PROMPT_FILE}" --json chatty-family MEMS-123 2>"${TEST_ROOT}/json.stderr")"
/usr/bin/python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["status"] == "running"; assert value["display_name"] == "MEMS-123"; assert value["additional_dirs"] == []' <<<"${JSON_OUTPUT}"
grep -Fq '/cb-all' "${TEST_TMUX_LOG}"
[[ ! -e /tmp/ticketflow-injection ]]

LEGACY_OUTPUT="$("${ROOT_DIR}/bin/spawn-session.sh" chatty-family legacy-session 2>&1)"
grep -Fq 'Remote session is running.' <<<"${LEGACY_OUTPUT}"
grep -Fq 'Claude session: legacy-session' <<<"${LEGACY_OUTPUT}"

set +e
FAKE_TMUX_DEAD=1 "${ROOT_DIR}/bin/spawn-session.sh" chatty-family failed-session >"${TEST_ROOT}/failure.log" 2>&1
FAILURE_STATUS=$?
set -e
[[ "${FAILURE_STATUS}" -ne 0 ]]
if find "${HOME}" -maxdepth 1 -name 'tmux-*failed-session*' | grep -q .; then
  printf 'failed launch left a tmux session behind\n' >&2
  exit 1
fi
grep -Fq 'kill-session' "${TEST_TMUX_LOG}"

printf 'spawn-session compatibility tests passed\n'
