#!/bin/bash

set -Eeuo pipefail

# Each project is expected at "$BASE_REPOS_DIR/<project>".
#
# Claude Code sessions: Claude Code creates and manages the session worktree
# beneath the repository's .claude folder, and each session carries its own
# Remote Control registration.
#
# Codex sessions: the Codex CLI has no worktree management and no per-session
# remote flag, so this script creates the Git worktree and relies on the
# machine-wide `codex remote-control` daemon for remote access.
#
# Cursor sessions: `cursor-agent worker start` registers a named private worker
# with Cursor, scoped to the directories it is given, so each session is
# individually addressable at cursor.com/agents. This script creates the Git
# worktree and runs the worker; the agent itself is started from Cursor.
#
# Where the project repositories live. Override with SPAWN_SESSION_REPOS_DIR.
BASE_REPOS_DIR="${SPAWN_SESSION_REPOS_DIR:-${HOME}/workspace}"
CODEX_WORKTREES_DIR="$BASE_REPOS_DIR/worktrees"
CURSOR_WORKTREES_DIR="$HOME/.cursor/worktrees"

usage() {
    printf 'Usage: %s [--agent claude|codex|cursor] <main-project> <display-name> [additional-project ...]\n' "${0##*/}" >&2
    printf 'The agent defaults to claude.\n' >&2
    printf 'Examples:\n' >&2
    printf '  %s artemis cross-project-login backend iphone fluttershy\n' "${0##*/}" >&2
    printf '  %s --agent codex artemis codex-login-fix\n' "${0##*/}" >&2
    printf '  %s --agent cursor artemis cursor-login-fix\n' "${0##*/}" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

AGENT=claude
while [ "$#" -gt 0 ]; do
    case "$1" in
        --agent)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            AGENT=$2
            shift 2
            ;;
        --agent=*)
            AGENT=${1#--agent=}
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            usage
            exit 2
            ;;
        *)
            break
            ;;
    esac
done

case "$AGENT" in
    claude|codex) AGENT_COMMAND_NAME=$AGENT ;;
    cursor) AGENT_COMMAND_NAME=cursor-agent ;;
    *) die "Unknown agent '$AGENT'. Use claude, codex, or cursor." ;;
esac

if [ "$#" -lt 2 ]; then
    usage
    exit 2
fi

PROJECT_NAME=$1
DISPLAY_NAME=$2
shift 2

# These values become path, Git branch, tmux session, and shell-command
# components. Keeping the character set narrow prevents invalid names and
# command injection.
SAFE_NAME_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]*$'
[[ "$PROJECT_NAME" =~ $SAFE_NAME_PATTERN ]] || \
    die "Invalid project name '$PROJECT_NAME'. Use letters, numbers, dot, underscore, or hyphen."
[[ "$DISPLAY_NAME" =~ $SAFE_NAME_PATTERN ]] || \
    die "Invalid display name '$DISPLAY_NAME'. Use letters, numbers, dot, underscore, or hyphen."

# Additional projects are exposed to the same session as extra writable
# directories. The main project alone receives the worktree.
ADDITIONAL_PROJECT_PATHS=()
SEEN_PROJECTS="|$PROJECT_NAME|"
for additional_project in "$@"; do
    [[ "$additional_project" =~ $SAFE_NAME_PATTERN ]] || \
        die "Invalid additional project name '$additional_project'. Use letters, numbers, dot, underscore, or hyphen."

    case "$SEEN_PROJECTS" in
        *"|$additional_project|"*)
            die "Project '$additional_project' was specified more than once"
            ;;
    esac

    additional_path="$BASE_REPOS_DIR/$additional_project"
    [ -d "$additional_path" ] || die "Additional project not found at $additional_path"
    ADDITIONAL_PROJECT_PATHS+=("$additional_path")
    SEEN_PROJECTS="${SEEN_PROJECTS}${additional_project}|"
done

for dependency in git tmux "$AGENT_COMMAND_NAME"; do
    command -v "$dependency" >/dev/null 2>&1 || die "Required command not found: $dependency"
done

AGENT_BIN=$(command -v "$AGENT_COMMAND_NAME")
MAIN_REPO_PATH="$BASE_REPOS_DIR/$PROJECT_NAME"

[ -d "$MAIN_REPO_PATH" ] || die "Base repository not found at $MAIN_REPO_PATH"
git -C "$MAIN_REPO_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    die "Not a Git repository: $MAIN_REPO_PATH"
git -C "$MAIN_REPO_PATH" remote get-url origin >/dev/null 2>&1 || \
    die "Repository has no 'origin' remote: $MAIN_REPO_PATH"

# The remote display name can be reused. Filesystem, Git, and tmux resources
# cannot, so keep a separate unique internal name for those.
INTERNAL_NAME_STEM="${PROJECT_NAME}-${DISPLAY_NAME}-$(date +%Y%m%d-%H%M%S)-$$"
INTERNAL_NAME=$INTERNAL_NAME_STEM
SUFFIX=0

# Claude Code places its own worktree under the repository; Codex and Cursor
# worktrees are created by this script, each in the location that tool's own
# tooling expects to find them.
case "$AGENT" in
    claude) WORKTREE_BRANCH_PREFIX=worktree- ;;
    codex) WORKTREE_BRANCH_PREFIX=codex/ ;;
    cursor) WORKTREE_BRANCH_PREFIX=cursor/ ;;
esac

session_worktree_path_for() {
    case "$AGENT" in
        claude) printf '%s\n' "$MAIN_REPO_PATH/.claude/worktrees/$1" ;;
        codex) printf '%s\n' "$CODEX_WORKTREES_DIR/${PROJECT_NAME}_$1" ;;
        cursor) printf '%s\n' "$CURSOR_WORKTREES_DIR/$PROJECT_NAME/$1" ;;
    esac
}

while [ -e "$(session_worktree_path_for "$INTERNAL_NAME")" ] || \
      git -C "$MAIN_REPO_PATH" show-ref --verify --quiet "refs/heads/${WORKTREE_BRANCH_PREFIX}${INTERNAL_NAME}" || \
      tmux has-session -t "${AGENT}-$INTERNAL_NAME" 2>/dev/null; do
    SUFFIX=$((SUFFIX + 1))
    INTERNAL_NAME="${INTERNAL_NAME_STEM}-${SUFFIX}"
done

WORKTREE_BRANCH="${WORKTREE_BRANCH_PREFIX}${INTERNAL_NAME}"
git check-ref-format "refs/heads/$WORKTREE_BRANCH" >/dev/null || \
    die "Generated invalid worktree branch name: $WORKTREE_BRANCH"

TMUX_SESSION="${AGENT}-${INTERNAL_NAME}"
SESSION_WORKTREE_PATH=$(session_worktree_path_for "$INTERNAL_NAME")
TMUX_CREATED=false
WORKTREE_CREATED=false
COMPLETED=false

cleanup() {
    status=$?
    trap - EXIT

    if [ "$COMPLETED" != true ]; then
        printf 'Launch failed; cleaning up newly created resources...\n' >&2

        if [ "$TMUX_CREATED" = true ] && tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            tmux kill-session -t "$TMUX_SESSION" >/dev/null 2>&1 || true
        fi

        # Claude Code owns its own worktree lifecycle; only clean up worktrees
        # this script created for Codex and Cursor.
        if [ "$WORKTREE_CREATED" = true ]; then
            git -C "$MAIN_REPO_PATH" worktree remove --force "$SESSION_WORKTREE_PATH" >/dev/null 2>&1 || true
            git -C "$MAIN_REPO_PATH" branch -D "$WORKTREE_BRANCH" >/dev/null 2>&1 || true
        fi
    fi

    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Codex remote access is machine-wide: a single app-server daemon carries every
# thread on this host, so it must be running and enrolled before a session is
# worth starting. `codex remote-control start` is idempotent and exits non-zero
# when the daemon cannot reach the remote-control service.
if [ "$AGENT" = codex ]; then
    printf 'Ensuring the Codex remote-control daemon is running and enrolled...\n'
    if ! REMOTE_CONTROL_OUTPUT=$("$AGENT_BIN" remote-control start 2>&1); then
        printf '%s\n' "$REMOTE_CONTROL_OUTPUT" >&2
        die "Codex remote control is not available on this machine, so a remote Codex session cannot be started. Fix the enrollment error above (see 'codex remote-control start'), then retry."
    fi
    printf '%s\n' "$REMOTE_CONTROL_OUTPUT"
fi

# A Cursor worker can only register with Cursor when the CLI is signed in, and a
# worker that cannot register is not reachable from cursor.com/agents.
if [ "$AGENT" = cursor ]; then
    printf 'Checking Cursor authentication...\n'
    if ! CURSOR_STATUS_OUTPUT=$("$AGENT_BIN" status 2>&1); then
        printf '%s\n' "$CURSOR_STATUS_OUTPUT" >&2
        die "Cursor CLI is not signed in, so the worker cannot register with Cursor. Run 'cursor-agent login', then retry."
    fi
    printf '%s\n' "$CURSOR_STATUS_OUTPUT"
fi

if [ "$AGENT" != claude ]; then
    printf 'Creating Git worktree %s on branch %s...\n' "$SESSION_WORKTREE_PATH" "$WORKTREE_BRANCH"
    mkdir -p "$(dirname "$SESSION_WORKTREE_PATH")"
    git -C "$MAIN_REPO_PATH" worktree add -b "$WORKTREE_BRANCH" "$SESSION_WORKTREE_PATH" HEAD >/dev/null || \
        die "Failed to create worktree at $SESSION_WORKTREE_PATH"
    WORKTREE_CREATED=true
fi

# Start an inert pane first so its environment can be set before the agent
# starts. remain-on-exit keeps startup errors available for inspection.
if [ "$AGENT" = claude ]; then
    TMUX_START_DIR="$MAIN_REPO_PATH"
else
    TMUX_START_DIR="$SESSION_WORKTREE_PATH"
fi
tmux new-session -d -s "$TMUX_SESSION" -c "$TMUX_START_DIR"
TMUX_CREATED=true
tmux set-option -t "$TMUX_SESSION" remain-on-exit on
tmux set-environment -t "$TMUX_SESSION" PATH "$PATH"
tmux set-environment -t "$TMUX_SESSION" HOME "$HOME"
tmux set-environment -t "$TMUX_SESSION" USER "${USER:-$(id -un)}"

# Build the command as an array, then shell-escape every element for tmux.
AGENT_COMMAND_PARTS=("$AGENT_BIN")
if [ "$AGENT" = claude ]; then
    # Claude owns worktree creation, branch selection, and lifecycle cleanup.
    # Any additional project directories remain regular shared directories.
    AGENT_COMMAND_PARTS+=(--worktree "$INTERNAL_NAME")
    if [ "${#ADDITIONAL_PROJECT_PATHS[@]}" -gt 0 ]; then
        AGENT_COMMAND_PARTS+=(--add-dir)
        AGENT_COMMAND_PARTS+=("${ADDITIONAL_PROJECT_PATHS[@]}")
    fi
    AGENT_COMMAND_PARTS+=(--name "$DISPLAY_NAME" --remote-control "$DISPLAY_NAME" --permission-mode auto)
elif [ "$AGENT" = cursor ]; then
    # The worker is the remote surface: it registers with Cursor under the
    # display name and exposes only the directories given here. Its first
    # --worker-dir is the assignment identity, so the worktree comes first. No
    # agent runs locally; agents are started against this worker from Cursor.
    AGENT_COMMAND_PARTS+=(worker start --name "$DISPLAY_NAME" --worker-dir "$SESSION_WORKTREE_PATH")
    for additional_path in "${ADDITIONAL_PROJECT_PATHS[@]+"${ADDITIONAL_PROJECT_PATHS[@]}"}"; do
        AGENT_COMMAND_PARTS+=(--worker-dir "$additional_path")
    done
else
    # Codex takes one --add-dir per directory. Trust is granted for this launch
    # only, through -c, so nothing has to be recorded as a trusted project in
    # ~/.codex/config.toml. Codex resolves trust at the repository root rather
    # than the worktree path, so the main repository has to be trusted too or
    # the interface blocks on a trust prompt. --sandbox workspace-write with
    # -a never is the unattended equivalent of Claude's auto permission mode.
    AGENT_COMMAND_PARTS+=(--cd "$SESSION_WORKTREE_PATH")
    for additional_path in "${ADDITIONAL_PROJECT_PATHS[@]+"${ADDITIONAL_PROJECT_PATHS[@]}"}"; do
        AGENT_COMMAND_PARTS+=(--add-dir "$additional_path")
    done
    AGENT_COMMAND_PARTS+=(--sandbox workspace-write -a never)
    # Repeated `-c projects."<path>".trust_level=...` flags replace each other
    # instead of merging, so every path goes into one inline TOML table. Only
    # the directories this session was asked for are trusted; trusted projects
    # recorded in ~/.codex/config.toml are deliberately not inherited. Every
    # path here is built from validated names under $BASE_REPOS_DIR, so none of
    # them can carry a quote into the TOML value.
    CODEX_TRUST_TOML='projects={'
    CODEX_TRUST_SEPARATOR=''
    for trusted_path in "$SESSION_WORKTREE_PATH" "$MAIN_REPO_PATH" \
        "${ADDITIONAL_PROJECT_PATHS[@]+"${ADDITIONAL_PROJECT_PATHS[@]}"}"; do
        CODEX_TRUST_TOML+="${CODEX_TRUST_SEPARATOR}\"${trusted_path}\"={trust_level=\"trusted\"}"
        CODEX_TRUST_SEPARATOR=','
    done
    CODEX_TRUST_TOML+='}'
    AGENT_COMMAND_PARTS+=(-c "$CODEX_TRUST_TOML")
fi
printf -v AGENT_COMMAND '%q ' "${AGENT_COMMAND_PARTS[@]}"
AGENT_COMMAND="exec ${AGENT_COMMAND% }"

case "$AGENT" in
    claude) printf 'Starting Claude Code Remote Control in tmux session %s...\n' "$TMUX_SESSION" ;;
    codex) printf 'Starting Codex in tmux session %s...\n' "$TMUX_SESSION" ;;
    cursor) printf 'Starting the Cursor worker in tmux session %s...\n' "$TMUX_SESSION" ;;
esac
tmux respawn-pane -k -t "$TMUX_SESSION:0.0" "$AGENT_COMMAND"

# Authentication and option errors normally terminate immediately. Watch the
# initial output long enough to handle Claude's one-time Remote Control consent
# prompt, long enough for Codex to draw its interface, and long enough for the
# Cursor worker to report that it registered. Only that exact Claude prompt is
# approved automatically; unrelated prompts remain untouched for the user to
# inspect.
REMOTE_CONTROL_APPROVED=false
STARTUP_OUTPUT=''
STARTUP_ATTEMPT=0
STARTUP_ATTEMPT_LIMIT=20
[ "$AGENT" = claude ] || STARTUP_ATTEMPT_LIMIT=120
while [ "$STARTUP_ATTEMPT" -lt "$STARTUP_ATTEMPT_LIMIT" ]; do
    STARTUP_ATTEMPT=$((STARTUP_ATTEMPT + 1))
    PANE_DEAD=$(tmux display-message -p -t "$TMUX_SESSION:0.0" '#{pane_dead}')
    if [ "$PANE_DEAD" = 1 ]; then
        break
    fi

    STARTUP_OUTPUT=$(tmux capture-pane -p -t "$TMUX_SESSION:0.0" -S -100)

    if [ "$AGENT" = codex ]; then
        case "$STARTUP_OUTPUT" in
            *'OpenAI Codex'*)
                break
                ;;
        esac
    elif [ "$AGENT" = cursor ]; then
        case "$STARTUP_OUTPUT" in
            *'Worker is now running'*)
                break
                ;;
        esac
    elif [ "$REMOTE_CONTROL_APPROVED" = false ]; then
        case "$STARTUP_OUTPUT" in
            *'Enable Remote Control? (y/n)'*)
                printf 'Approving Claude Code Remote Control for this account...\n'
                tmux send-keys -t "$TMUX_SESSION:0.0" y Enter
                REMOTE_CONTROL_APPROVED=true
                sleep 2
                break
                ;;
        esac
    fi

    sleep 0.25
done

PANE_DEAD=$(tmux display-message -p -t "$TMUX_SESSION:0.0" '#{pane_dead}')
if [ "$PANE_DEAD" = 1 ]; then
    printf '%s exited during startup. tmux output:\n' "$AGENT" >&2
    tmux capture-pane -p -t "$TMUX_SESSION:0.0" -S -100 >&2 || true
    exit 1
fi

if [ "$AGENT" = codex ]; then
    case "$STARTUP_OUTPUT" in
        *'OpenAI Codex'*) ;;
        *)
            printf 'Codex did not finish drawing its interface. tmux output:\n' >&2
            tmux capture-pane -p -t "$TMUX_SESSION:0.0" -S -100 >&2 || true
            exit 1
            ;;
    esac
fi

# The worker prints its cursor.com URL once it has registered, so a missing
# "Worker is now running" means the session is not reachable remotely. The URL
# wraps across pane lines, so unwrap before reading the worker id out of it.
CURSOR_WORKER_URL=''
if [ "$AGENT" = cursor ]; then
    case "$STARTUP_OUTPUT" in
        *'Worker is now running'*) ;;
        *)
            printf 'The Cursor worker did not register with Cursor. tmux output:\n' >&2
            tmux capture-pane -p -t "$TMUX_SESSION:0.0" -S -100 >&2 || true
            exit 1
            ;;
    esac

    CURSOR_WORKER_ID=$(printf '%s' "$STARTUP_OUTPUT" | tr -d '\n' | \
        sed -n 's/.*agents#workerId=\([0-9a-fA-F-]\{36\}\).*/\1/p' | head -1)
    if [ -n "$CURSOR_WORKER_ID" ]; then
        CURSOR_WORKER_URL="https://cursor.com/agents#workerId=$CURSOR_WORKER_ID"
    fi
fi

COMPLETED=true
printf '\nRemote session is running.\n'
printf '  Agent:          %s\n' "$AGENT"
if [ "$AGENT" = claude ]; then
    printf '  Claude session: %s\n' "$DISPLAY_NAME"
    printf '  tmux session:   %s\n' "$TMUX_SESSION"
    printf '  Worktree:       managed by Claude Code (%s)\n' "$INTERNAL_NAME"
elif [ "$AGENT" = cursor ]; then
    printf '  Worker name:    %s\n' "$DISPLAY_NAME"
    printf '  tmux session:   %s\n' "$TMUX_SESSION"
    printf '  Worktree:       %s (branch %s)\n' "$SESSION_WORKTREE_PATH" "$WORKTREE_BRANCH"
else
    printf '  Session label:  %s (local only; Codex names its own threads)\n' "$DISPLAY_NAME"
    printf '  tmux session:   %s\n' "$TMUX_SESSION"
    printf '  Worktree:       %s (branch %s)\n' "$SESSION_WORKTREE_PATH" "$WORKTREE_BRANCH"
fi
if [ "${#ADDITIONAL_PROJECT_PATHS[@]}" -gt 0 ]; then
    printf '  Additional dirs:\n'
    for additional_path in "${ADDITIONAL_PROJECT_PATHS[@]}"; do
        printf '    - %s\n' "$additional_path"
    done
fi
if [ "$AGENT" = codex ]; then
    printf '\nReach it from the ChatGPT app:\n'
    printf '  This machine is enrolled for Codex remote control, which is machine-wide\n'
    printf '  rather than per session. Pick this host in the app, then open the thread in\n'
    printf '  %s\n' "$SESSION_WORKTREE_PATH"
    printf '  or start a new one there.\n'
    printf '  First-time pairing: codex remote-control pair\n'
fi
if [ "$AGENT" = cursor ]; then
    printf '\nReach it from Cursor:\n'
    printf '  The worker is registered with Cursor as %s. Start an agent against it\n' "$DISPLAY_NAME"
    printf '  from Cursor on the web or your phone; no agent runs locally until you do.\n'
    if [ -n "$CURSOR_WORKER_URL" ]; then
        printf '  Run agents: %s\n' "$CURSOR_WORKER_URL"
    else
        printf '  Run agents: https://cursor.com/agents (find the worker by name)\n'
    fi
fi
printf '\nManage locally:\n'
printf '  Attach: tmux attach -t %q\n' "$TMUX_SESSION"
printf '  Logs:   tmux capture-pane -p -t %q -S -100\n' "$TMUX_SESSION"
printf '  Stop:   tmux kill-session -t %q\n' "$TMUX_SESSION"
if [ "$AGENT" != claude ]; then
    printf '  Remove worktree: git -C %q worktree remove %q && git -C %q branch -D %q\n' \
        "$MAIN_REPO_PATH" "$SESSION_WORKTREE_PATH" "$MAIN_REPO_PATH" "$WORKTREE_BRANCH"
fi
