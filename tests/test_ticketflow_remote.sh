#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

mkdir -p "${TEST_ROOT}/bin"
export TEST_REMOTE_LOG="${TEST_ROOT}/remote.log"

cat >"${TEST_ROOT}/bin/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
last=''
for argument in "$@"; do last="${argument}"; done
exec zsh -lc "${last}"
FAKE_SSH

cat >"${TEST_ROOT}/remote-ticketflow" <<'FAKE_TICKETFLOW'
#!/usr/bin/env bash
printf '%s\n' "$#" "$1" "$2" >"${TEST_REMOTE_LOG}"
FAKE_TICKETFLOW

chmod +x "${TEST_ROOT}/bin/ssh" "${TEST_ROOT}/remote-ticketflow"

export PATH="${TEST_ROOT}/bin:${PATH}"
export TICKETFLOW_REMOTE_HOST='test-agent'
export TICKETFLOW_REMOTE_COMMAND="${TEST_ROOT}/remote-ticketflow"

TICKET="https://chatbookstown.atlassian.net/browse/MEMS-123?note=a b&literal=\$(touch ${TEST_ROOT}/injection)"
"${ROOT_DIR}/bin/ticketflow-remote" "${TICKET}"

[[ "$(sed -n '1p' "${TEST_REMOTE_LOG}")" == '2' ]]
[[ "$(sed -n '2p' "${TEST_REMOTE_LOG}")" == 'start' ]]
[[ "$(sed -n '3p' "${TEST_REMOTE_LOG}")" == "${TICKET}" ]]
[[ ! -e "${TEST_ROOT}/injection" ]]

"${ROOT_DIR}/bin/ticketflow-remote" --help >/dev/null 2>&1
if "${ROOT_DIR}/bin/ticketflow-remote" >/dev/null 2>&1; then
    printf 'missing ticket unexpectedly succeeded\n' >&2
    exit 1
fi

printf 'ticketflow-remote tests passed\n'
