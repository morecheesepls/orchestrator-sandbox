#!/usr/bin/env bash
#
# orchestrator.sh — Drives the Designer → Engineer → Tester loop
#
# Launches each role session and loops until the checkpoint is ready
# for human testing (or a safety limit is hit).
#
# The agent writes three files during /endsession:
#   current_role       — who just ran
#   next_role          — who should run next
#   checkpoint_status  — "yes" when ready for human testing, "blocked" when Designer is stalled on a Human decision, "done" when no work remains
#
# The script just reads these files. No output parsing.
#
# Modes:
#   interactive — runs the selected runtime through tmux so you can watch live
#   headless    — runs the selected runtime in the background, no UI
#
set -euo pipefail

# --- Defaults ---
PROJECT_DIR="$(pwd)"
MAX_ITERATIONS=100
MAX_FAILURES=3
MAX_SAME_ROLE=25
MAX_CODEX_COMPACTIONS_PER_ROLE=3
MAX_CODEX_ITERATION_LOG_BYTES=1048576
FIRST_ROLE=""
MODE=interactive
RUNTIME=claude
CODEX_EXEC_POLICY=sandboxed
CODEX_SESSION_MODE=fresh
IDLE_TIMEOUT=1200
WAIT_TIMEOUT=1800
TMUX_SESSION=""
POLL_INTERVAL=5

# --- Runtime state ---
ITERATION=0
CONSECUTIVE_FAILURES=0
CONSECUTIVE_SAME_ROLE=0
PREV_ROLE=""
PREV_HEAD=""
CURRENT_ROLE=""
LOOP_START_TIME=""
ITER_START_TIME=""
LOG_DIR=""
MASTER_LOG=""
CONFIG_FILE=""
LOOP_PID=""
PROJECT_NAME=""
ORCHESTRATOR_STOP_FILE=""

# --- Codex runtime state ---
CODEX_THREAD_ID_FILE=""
CODEX_NEEDS_REINIT_FILE=""
CODEX_INIT_COMPLETE_FILE=""
CODEX_COMPACTION_OBSERVED_FILE=""
CODEX_CONTINUITY_STATE_FILE=""
CODEX_CONTINUITY_ROLE_FILE=""
CODEX_CONTINUITY_SUMMARY_FILE=""
CODEX_ITERATION_OUTPUT_FILE=""
CODEX_LAST_COMPACTION_LOG=""
CODEX_RECOVERY_TURN_ACTIVE=false
CODEX_COMPACTIONS_TOTAL=0
CODEX_COMPACTIONS_DESIGNER=0
CODEX_COMPACTIONS_ENGINEER=0
CODEX_COMPACTIONS_TESTER=0

# --- Config persistence ---

init_runtime_state_files() {
    CODEX_THREAD_ID_FILE="$PROJECT_DIR/.orchestrator/thread_id"
    CODEX_NEEDS_REINIT_FILE="$PROJECT_DIR/.codex/needs_reinit"
    CODEX_INIT_COMPLETE_FILE="$PROJECT_DIR/.codex/init_complete"
    CODEX_COMPACTION_OBSERVED_FILE="$PROJECT_DIR/.orchestrator/codex_compaction_observed"
    CODEX_CONTINUITY_STATE_FILE="$PROJECT_DIR/.orchestrator/continuity_state"
    CODEX_CONTINUITY_ROLE_FILE="$PROJECT_DIR/.orchestrator/continuity_role"
    CODEX_CONTINUITY_SUMMARY_FILE="$PROJECT_DIR/.orchestrator/codex_continuity.md"
    ORCHESTRATOR_STOP_FILE="$PROJECT_DIR/.orchestrator/stop_requested"
}

load_config() {
    CONFIG_FILE="$PROJECT_DIR/.orchestrator/config"
    if [[ -f "$CONFIG_FILE" ]]; then
        while IFS='=' read -r key val; do
            [[ -z "$key" || "$key" == \#* ]] && continue
            val=$(echo "$val" | xargs)
            case "$key" in
                max_iterations)    MAX_ITERATIONS="$val" ;;
                max_failures)      MAX_FAILURES="$val" ;;
                max_same_role)     MAX_SAME_ROLE="$val" ;;
                max_codex_compactions_per_role) MAX_CODEX_COMPACTIONS_PER_ROLE="$val" ;;
                max_codex_iteration_log_bytes) MAX_CODEX_ITERATION_LOG_BYTES="$val" ;;
                idle_timeout)      IDLE_TIMEOUT="$val" ;;
                wait_timeout)      WAIT_TIMEOUT="$val" ;;
                mode)              MODE="$val" ;;
                runtime)           RUNTIME="$val" ;;
                codex_exec_policy) CODEX_EXEC_POLICY="$val" ;;
                codex_session_mode) CODEX_SESSION_MODE="$val" ;;
            esac
        done < "$CONFIG_FILE"
    else
        save_config
    fi

    if [[ "$CODEX_SESSION_MODE" != "fresh" && "$CODEX_SESSION_MODE" != "resume" ]]; then
        CODEX_SESSION_MODE=fresh
    fi
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<EOF
max_iterations=$MAX_ITERATIONS
max_failures=$MAX_FAILURES
max_same_role=$MAX_SAME_ROLE
max_codex_compactions_per_role=$MAX_CODEX_COMPACTIONS_PER_ROLE
max_codex_iteration_log_bytes=$MAX_CODEX_ITERATION_LOG_BYTES
idle_timeout=$IDLE_TIMEOUT
wait_timeout=$WAIT_TIMEOUT
mode=$MODE
runtime=$RUNTIME
codex_exec_policy=$CODEX_EXEC_POLICY
codex_session_mode=$CODEX_SESSION_MODE
EOF
}

# --- Logging ---
log_msg() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local msg
    if [[ -n "${PROJECT_NAME:-}" ]]; then
        msg="[$timestamp] [$PROJECT_NAME] [$level] $*"
    else
        msg="[$timestamp] [$level] $*"
    fi
    if [[ -n "${MASTER_LOG:-}" ]]; then
        echo "$msg" >> "$MASTER_LOG"
    fi
    if [[ "$MODE" == "headless" ]]; then
        echo "$msg" >&2
    fi
}

cleanup_old_logs() {
    local count
    count=$(find "$LOG_DIR" -name "orchestrator_*.log" -mtime +3 2>/dev/null | wc -l)
    if [[ "$count" -gt 0 ]]; then
        find "$LOG_DIR" -name "orchestrator_*.log" -mtime +3 -delete 2>/dev/null || true
        log_msg INFO "Cleaned $count log files older than 3 days"
    fi

    count=$(find "$LOG_DIR" -name "codex_iter_*.log" -mtime +3 2>/dev/null | wc -l)
    if [[ "$count" -gt 0 ]]; then
        find "$LOG_DIR" -name "codex_iter_*.log" -mtime +3 -delete 2>/dev/null || true
        log_msg INFO "Cleaned $count Codex iteration logs older than 3 days"
    fi
}

# --- Codex helpers ---

read_thread_id() {
    if [[ -f "$CODEX_THREAD_ID_FILE" ]]; then
        tr -d '[:space:]' < "$CODEX_THREAD_ID_FILE"
    fi
}

read_codex_context_window() {
    local config_file="$PROJECT_DIR/.codex/config.toml"
    if [[ -f "$config_file" ]]; then
        grep -E '^model_context_window' "$config_file" 2>/dev/null | sed 's/.*= *//' | tr -d '[:space:]'
    fi
}

read_codex_quicksave_token_limit() {
    local context_window
    context_window=$(read_codex_context_window)
    if [[ -n "$context_window" ]]; then
        echo $(( context_window * 75 / 100 ))
    fi
}

read_codex_auto_compact_token_limit() {
    local config_file="$PROJECT_DIR/.codex/config.toml"
    if [[ -f "$config_file" ]]; then
        grep -E '^model_auto_compact_token_limit' "$config_file" 2>/dev/null | sed 's/.*= *//' | tr -d '[:space:]'
    fi
}

describe_continuity_state() {
    if [[ -f "$CODEX_CONTINUITY_STATE_FILE" ]]; then
        tr -d '[:space:]' < "$CODEX_CONTINUITY_STATE_FILE"
    else
        echo "none"
    fi
}

shell_join() {
    local parts=()
    local arg arg_q
    for arg in "$@"; do
        printf -v arg_q '%q' "$arg"
        parts+=("$arg_q")
    done
    printf '%s' "${parts[*]}"
}

read_project_role_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        tr -d '[:space:]' < "$file" | tr '[:upper:]' '[:lower:]'
    fi
}

is_valid_role() {
    [[ "$1" =~ ^(designer|engineer|tester)$ ]]
}

# --- Role selection ---

resolve_first_role() {
    local next_role_file="$PROJECT_DIR/next_role"
    local current_role_file="$PROJECT_DIR/current_role"

    if [[ -n "$FIRST_ROLE" ]]; then
        FIRST_ROLE_REASON="manually set"
        return
    fi

    if [[ -f "$next_role_file" ]]; then
        local role
        role=$(tr -d '[:space:]' < "$next_role_file" | tr '[:upper:]' '[:lower:]')
        if [[ "$role" =~ ^(designer|engineer|tester)$ ]]; then
            FIRST_ROLE="$role"
            FIRST_ROLE_REASON="from next_role file"
            return
        fi
    fi

    if [[ -f "$current_role_file" ]]; then
        local current
        current=$(tr -d '[:space:]' < "$current_role_file" | tr '[:upper:]' '[:lower:]')
        case "$current" in
            designer) FIRST_ROLE="engineer" ;;
            engineer) FIRST_ROLE="tester" ;;
            tester)   FIRST_ROLE="designer" ;;
            *)        FIRST_ROLE="designer" ;;
        esac
        FIRST_ROLE_REASON="next after $current (from current_role)"
        return
    fi

    FIRST_ROLE="designer"
    FIRST_ROLE_REASON="default (no state files)"
}

read_next_role() {
    local next_role_file="$PROJECT_DIR/next_role"
    local current_role_file="$PROJECT_DIR/current_role"

    if [[ -f "$next_role_file" ]]; then
        local role
        role=$(tr -d '[:space:]' < "$next_role_file" | tr '[:upper:]' '[:lower:]')
        if [[ "$role" =~ ^(designer|engineer|tester)$ ]]; then
            echo "$role|next_role file"
            return
        fi
    fi

    if [[ -f "$current_role_file" ]]; then
        local current
        current=$(tr -d '[:space:]' < "$current_role_file" | tr '[:upper:]' '[:lower:]')
        case "$current" in
            designer) echo "engineer|cycle from $current (no next_role file)" ;;
            engineer) echo "tester|cycle from $current (no next_role file)" ;;
            tester)   echo "designer|cycle from $current (no next_role file)" ;;
            *)        echo "designer|default (unrecognized current_role)" ;;
        esac
        return
    fi

    echo "designer|default (no state files)"
}

# --- Time formatting ---

format_duration() {
    local secs=$1
    local h=$((secs / 3600))
    local m=$(((secs % 3600) / 60))
    local s=$((secs % 60))
    if [[ $h -gt 0 ]]; then
        printf "%dh %dm %ds" "$h" "$m" "$s"
    elif [[ $m -gt 0 ]]; then
        printf "%dm %ds" "$m" "$s"
    else
        printf "%ds" "$s"
    fi
}

# ============================================================
# Orchestrator tmux status
# ============================================================

orchestrator_tmux_send() {
    if ! tmux send-keys -t "$TMUX_SESSION" "$1" Enter 2>/dev/null; then
        log_msg ERROR "tmux send-keys failed: $1"
        return 1
    fi
}

orchestrator_tmux_kill() {
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
}

orchestrator_configure_status_bar() {
    tmux set-option -t "$TMUX_SESSION" status on 2>/dev/null || true
    tmux set-option -t "$TMUX_SESSION" status-position bottom 2>/dev/null || true
    tmux set-option -t "$TMUX_SESSION" status-interval 1 2>/dev/null || true
    tmux set-option -t "$TMUX_SESSION" status-style "bg=colour22,fg=white,bold" 2>/dev/null || true
    tmux set-option -t "$TMUX_SESSION" status-left-length 80 2>/dev/null || true
    tmux set-option -t "$TMUX_SESSION" status-right-length 80 2>/dev/null || true
    tmux set-option -t "$TMUX_SESSION" status-left " orch │ starting..." 2>/dev/null || true
    tmux set-option -t "$TMUX_SESSION" status-right "" 2>/dev/null || true
    tmux set-window-option -t "$TMUX_SESSION" window-status-format "" 2>/dev/null || true
    tmux set-window-option -t "$TMUX_SESSION" window-status-current-format "" 2>/dev/null || true
    tmux set-option -t "$TMUX_SESSION" mouse on 2>/dev/null || true
    tmux bind-key -T prefix k confirm-before -p 'kill orchestrator? (y/n) ' 'kill-session' 2>/dev/null || true
    if [[ "$RUNTIME" == "codex" && -n "$ORCHESTRATOR_STOP_FILE" ]]; then
        local stop_dir stop_dir_q stop_file_q session_q stop_command
        stop_dir="$(dirname "$ORCHESTRATOR_STOP_FILE")"
        printf -v stop_dir_q '%q' "$stop_dir"
        printf -v stop_file_q '%q' "$ORCHESTRATOR_STOP_FILE"
        printf -v session_q '%q' "$TMUX_SESSION"
        stop_command="mkdir -p $stop_dir_q; touch $stop_file_q; tmux kill-session -t $session_q"
        tmux bind-key -T root C-c if-shell -F "#{==:#{session_name},$TMUX_SESSION}" "run-shell -b \"$stop_command\"" "send-keys C-c" 2>/dev/null || true
    fi
}

orchestrator_update_status_bar() {
    [[ "$MODE" != "interactive" ]] && return
    [[ -z "$LOOP_START_TIME" ]] && return

    local now elapsed formatted
    now=$(date +%s)
    elapsed=$((now - LOOP_START_TIME))
    formatted=$(format_duration "$elapsed")

    local role_label="${CURRENT_ROLE:-starting}"
    local left=" orch │ iter $ITERATION: $role_label"
    local stop_hint=""
    if [[ "$RUNTIME" == "codex" ]]; then
        stop_hint=" │ C-c stop"
    fi
    local right="elapsed: $formatted │ fails: $CONSECUTIVE_FAILURES$stop_hint "

    tmux set-option -t "$TMUX_SESSION" status-left "$left" 2>/dev/null || true
    tmux set-option -t "$TMUX_SESSION" status-right "$right" 2>/dev/null || true
}

# ============================================================
# Claude Runtime Adapter
# ============================================================

claude_tmux_send() {
    orchestrator_tmux_send "$1"
}

claude_tmux_kill() {
    orchestrator_tmux_kill
}

claude_configure_status_bar() {
    orchestrator_configure_status_bar
}

claude_update_status_bar() {
    orchestrator_update_status_bar
}

claude_wait_for_status_file() {
    local target="$1"
    local idle_nudge_sent=false
    local start_time hard_deadline
    start_time=$(date +%s)
    hard_deadline=$((start_time + WAIT_TIMEOUT))

    while true; do
        if [[ -f "$target" ]]; then
            return 0
        fi
        if [[ "$MODE" == "interactive" ]] && ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            log_msg WARN "tmux session died without writing $target"
            return 1
        fi

        # Hard timeout — prevents indefinite polling
        if [[ "$WAIT_TIMEOUT" -gt 0 ]]; then
            local now_check
            now_check=$(date +%s)
            if [[ $now_check -ge $hard_deadline ]]; then
                log_msg ERROR "Wait timeout (${WAIT_TIMEOUT}s) — checkpoint_status never written"
                return 1
            fi
        fi

        runtime_update_status_bar

        if [[ "$MODE" == "interactive" ]] && [[ "$idle_nudge_sent" == false ]] && [[ "$IDLE_TIMEOUT" -gt 0 ]]; then
            local now elapsed
            now=$(date +%s)
            elapsed=$(( now - start_time ))
            if [[ $elapsed -ge $IDLE_TIMEOUT ]]; then
                local snap1 snap2
                snap1=$(tmux capture-pane -t "$TMUX_SESSION" -p 2>/dev/null || echo "")
                sleep 10
                snap2=$(tmux capture-pane -t "$TMUX_SESSION" -p 2>/dev/null || echo "")
                if [[ "$snap1" == "$snap2" ]]; then
                    log_msg WARN "Idle timeout (${IDLE_TIMEOUT}s) — sending /endsession nudge"
                    if claude_tmux_send "/endsession"; then
                        idle_nudge_sent=true
                    else
                        log_msg ERROR "Failed to send idle nudge — tmux session may be unresponsive"
                    fi
                else
                    start_time=$(date +%s)
                    hard_deadline=$((start_time + WAIT_TIMEOUT))
                    log_msg INFO "Idle timeout reached but Claude still active — timer reset"
                fi
            fi
        fi

        sleep "$POLL_INTERVAL"
    done
}

claude_wait_for_ready() {
    local timeout=60
    local elapsed=0
    local need_zero=false

    if tmux capture-pane -t "$TMUX_SESSION" -p 2>/dev/null | grep -qE '\([1-9][0-9]*%\)'; then
        need_zero=true
    fi

    while [[ $elapsed -lt $timeout ]]; do
        local pane
        pane=$(tmux capture-pane -t "$TMUX_SESSION" -p 2>/dev/null || echo "")

        if [[ "$need_zero" == true ]]; then
            if echo "$pane" | grep -qE '\(0%\)'; then
                log_msg INFO "Claude Code ready (${elapsed}s)"
                return 0
            fi
        else
            if echo "$pane" | grep -qE '\([0-9]+%\)'; then
                log_msg INFO "Claude Code ready (${elapsed}s)"
                return 0
            fi
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done
    log_msg WARN "Claude Code readiness timeout after ${timeout}s — proceeding anyway"
    return 0
}

claude_wait_for_idle() {
    local timeout=30
    local elapsed=0
    sleep 2
    while [[ $elapsed -lt $timeout ]]; do
        local snap1 snap2
        snap1=$(tmux capture-pane -t "$TMUX_SESSION" -p 2>/dev/null || echo "")
        sleep 2
        snap2=$(tmux capture-pane -t "$TMUX_SESSION" -p 2>/dev/null || echo "")
        if [[ "$snap1" == "$snap2" ]]; then
            return 0
        fi
        elapsed=$((elapsed + 2))
    done
    return 0
}

# Claude runtime interface
claude_runtime_validate() {
    if [[ "$MODE" == "interactive" ]] && ! command -v tmux &>/dev/null; then
        echo "Error: interactive mode requires tmux. Install it or set mode to headless." >&2
        exit 1
    fi
}

claude_runtime_start_interactive_session() {
    claude_tmux_kill
    log_msg INFO "Creating tmux session: $TMUX_SESSION"
    if ! tmux new-session -d -s "$TMUX_SESSION" -c "$PROJECT_DIR" "claude" 2>/dev/null; then
        log_msg ERROR "Failed to create tmux session: $TMUX_SESSION"
        return 1
    fi
    claude_configure_status_bar
    claude_wait_for_ready
}

claude_runtime_prepare_iteration() {
    if [[ "$MODE" == "interactive" ]] && [[ "$ITERATION" -gt 1 ]]; then
        if ! claude_tmux_send "/clear"; then
            log_msg ERROR "Failed to send /clear during iteration prep"
            return 1
        fi
        claude_wait_for_ready
    fi
}

claude_runtime_enter_role() {
    if [[ "$MODE" == "interactive" ]]; then
        log_msg INFO "Sending /$CURRENT_ROLE to session"
        if ! claude_tmux_send "/$CURRENT_ROLE"; then
            log_msg ERROR "Failed to send /$CURRENT_ROLE — session may be dead"
            return 1
        fi
    fi
}

claude_runtime_wait_for_completion() {
    if [[ "$MODE" == "interactive" ]]; then
        if ! claude_wait_for_status_file "$PROJECT_DIR/checkpoint_status"; then
            return 1
        fi
        claude_wait_for_idle
    fi
}

claude_runtime_recover_interactive_session() {
    log_msg INFO "Recovering tmux session: $TMUX_SESSION"
    claude_tmux_kill
    if ! tmux new-session -d -s "$TMUX_SESSION" -c "$PROJECT_DIR" "claude" 2>/dev/null; then
        log_msg ERROR "Failed to recover tmux session: $TMUX_SESSION"
        return 1
    fi
    claude_configure_status_bar
    claude_wait_for_ready
}

claude_runtime_finish_iteration() {
    : # No-op for Claude — state files are sufficient
}

claude_runtime_run_headless_role() {
    claude -p "/$CURRENT_ROLE" < /dev/null > /dev/null 2>&1 || true
}

claude_runtime_attach() {
    tmux attach -t "$TMUX_SESSION" 2>/dev/null || true
}

claude_runtime_session_alive() {
    tmux has-session -t "$TMUX_SESSION" 2>/dev/null
}

claude_runtime_cleanup() {
    log_msg INFO "Cleaning up tmux session: $TMUX_SESSION"
    claude_tmux_kill
}

# ============================================================
# Codex Runtime Adapter (Skeleton)
# ============================================================

codex_role_core_path() {
    echo ".agents/skills/$1/SKILL.md"
}

codex_validate_role_prompt_contract() {
    local role core_path
    for role in designer engineer tester; do
        core_path="$PROJECT_DIR/$(codex_role_core_path "$role")"
        if [[ ! -f "$core_path" ]]; then
            echo "Error: missing Codex role core: $(codex_role_core_path "$role")" >&2
            exit 1
        fi
    done
}

codex_runtime_validate() {
    if ! command -v codex &>/dev/null; then
        echo "Error: Codex CLI not found. Install it or set runtime to claude." >&2
        exit 1
    fi
    codex_validate_role_prompt_contract
}

codex_build_startup_prompt() {
    local role="$1"
    local role_core
    role_core="$(codex_role_core_path "$role")"
    local prompt="You are the $role for this project."
    prompt="$prompt Read AGENTS.md and docs/framework/ for shared policy."
    prompt="$prompt Read $role_core for your role entry workflow."
    prompt="$prompt Then begin your work."
    echo "$prompt"
}

codex_build_recovery_prompt() {
    local role="$1"
    local role_core
    role_core="$(codex_role_core_path "$role")"
    local prompt="RECOVERY TURN: The orchestrator observed Codex context compaction in a prior turn."
    prompt="$prompt You are the $role for this project."
    prompt="$prompt Read AGENTS.md, docs/framework/, and $role_core to reload governing rules."
    prompt="$prompt Read project_tracker.md and any active state files: checkpoint_status, current_role, next_role."
    if [[ -f "$CODEX_CONTINUITY_SUMMARY_FILE" ]]; then
        prompt="$prompt Read .orchestrator/codex_continuity.md for the observed compaction event and routing decision."
    fi
    prompt="$prompt Continue from durable project state; do not run first-session setup or ask what to work on unless project state is absent."
    prompt="$prompt When the turn is complete, use the normal endsession workflow so checkpoint_status, current_role, and next_role are refreshed."
    echo "$prompt"
}

codex_build_role_prompt() {
    local role="$1"

    if codex_recovery_required; then
        codex_build_recovery_prompt "$role"
    else
        codex_build_startup_prompt "$role"
    fi
}

codex_iteration_log_file() {
    printf '%s/codex_iter_%03d.log' "$LOG_DIR" "$ITERATION"
}

codex_recovery_required() {
    local state
    state="$(describe_continuity_state)"
    [[ "$state" == "recovery_required" || -f "$CODEX_NEEDS_REINIT_FILE" ]]
}

codex_increment_compaction_count() {
    case "$CURRENT_ROLE" in
        designer) CODEX_COMPACTIONS_DESIGNER=$((CODEX_COMPACTIONS_DESIGNER + 1)) ;;
        engineer) CODEX_COMPACTIONS_ENGINEER=$((CODEX_COMPACTIONS_ENGINEER + 1)) ;;
        tester) CODEX_COMPACTIONS_TESTER=$((CODEX_COMPACTIONS_TESTER + 1)) ;;
    esac
    CODEX_COMPACTIONS_TOTAL=$((CODEX_COMPACTIONS_TOTAL + 1))
}

codex_compactions_for_current_role() {
    case "$CURRENT_ROLE" in
        designer) echo "$CODEX_COMPACTIONS_DESIGNER" ;;
        engineer) echo "$CODEX_COMPACTIONS_ENGINEER" ;;
        tester) echo "$CODEX_COMPACTIONS_TESTER" ;;
        *) echo 0 ;;
    esac
}

codex_detect_compaction_in_log() {
    local output_file="$1"
    [[ -f "$output_file" ]] && grep -qiE 'context[[:space:]]+compacted' "$output_file"
}

codex_trim_iteration_log() {
    local output_file="$1"
    [[ -f "$output_file" ]] || return 0
    [[ "$MAX_CODEX_ITERATION_LOG_BYTES" -gt 0 ]] || return 0

    local size tmp_file
    size=$(wc -c < "$output_file" 2>/dev/null || echo 0)
    [[ "$size" -le "$MAX_CODEX_ITERATION_LOG_BYTES" ]] && return 0

    tmp_file="${output_file}.tmp"
    {
        printf '[orchestrator] log trimmed to last %s bytes from original %s bytes\n' "$MAX_CODEX_ITERATION_LOG_BYTES" "$size"
        tail -c "$MAX_CODEX_ITERATION_LOG_BYTES" "$output_file"
    } > "$tmp_file" && mv "$tmp_file" "$output_file"
    log_msg INFO "Trimmed Codex iteration log to $MAX_CODEX_ITERATION_LOG_BYTES bytes: $output_file"
}

codex_persist_compaction_observed() {
    local output_file="$1"
    local timestamp thread_id
    timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    thread_id="$(read_thread_id)"

    mkdir -p "$(dirname "$CODEX_COMPACTION_OBSERVED_FILE")" "$(dirname "$CODEX_NEEDS_REINIT_FILE")"
    CODEX_LAST_COMPACTION_LOG="$output_file"
    codex_increment_compaction_count

    cat > "$CODEX_COMPACTION_OBSERVED_FILE" <<EOF
timestamp=$timestamp
iteration=$ITERATION
role=$CURRENT_ROLE
mode=$MODE
thread_id=${thread_id:-unknown}
log=$output_file
EOF
    echo "recovery_required" > "$CODEX_CONTINUITY_STATE_FILE"
    echo "$CURRENT_ROLE" > "$CODEX_CONTINUITY_ROLE_FILE"
    : > "$CODEX_NEEDS_REINIT_FILE"

    cat > "$CODEX_CONTINUITY_SUMMARY_FILE" <<EOF
# Codex Compaction Recovery

- Observed: $timestamp
- Iteration: $ITERATION
- Role: $CURRENT_ROLE
- Mode: $MODE
- Thread id: ${thread_id:-unknown}
- Log: $output_file
- Recovery state: recovery_required

The orchestrator observed Codex context compaction in the terminal stream. Reload governing rules and project state, then continue the Designer/Engineer/Tester loop from durable files.
EOF

    log_msg WARN "Codex context compaction observed for $CURRENT_ROLE in $output_file; recovery_required state written"
}

codex_mark_recovered() {
    rm -f "$CODEX_NEEDS_REINIT_FILE" "$CODEX_INIT_COMPLETE_FILE"
    echo "recovered" > "$CODEX_CONTINUITY_STATE_FILE" 2>/dev/null || true
    log_msg INFO "Codex compaction recovery complete — cleared needs_reinit"
}

codex_select_recovery_role() {
    local checkpoint current next
    checkpoint=""
    if [[ -f "$PROJECT_DIR/checkpoint_status" ]]; then
        checkpoint=$(tr -d '[:space:]' < "$PROJECT_DIR/checkpoint_status" | tr '[:upper:]' '[:lower:]')
    fi
    current="$(read_project_role_file "$PROJECT_DIR/current_role")"
    next="$(read_project_role_file "$PROJECT_DIR/next_role")"

    if [[ -n "$checkpoint" ]] && is_valid_role "$current" && is_valid_role "$next"; then
        echo "$next|Codex recovery after compaction; handoff complete (checkpoint_status=$checkpoint, current_role=$current, next_role=$next)"
        return
    fi

    local continuity_role
    continuity_role="$(read_project_role_file "$CODEX_CONTINUITY_ROLE_FILE")"
    if is_valid_role "$continuity_role"; then
        echo "$continuity_role|Codex recovery after compaction; handoff incomplete or ambiguous, retrying observed role"
        return
    fi

    if is_valid_role "$current"; then
        echo "$current|Codex recovery after compaction; continuity_role absent, using current_role"
        return
    fi

    echo "$FIRST_ROLE|Codex recovery after compaction; project state absent, using first role"
}

codex_check_recovery_loop_protection() {
    local role_count
    role_count="$(codex_compactions_for_current_role)"
    if [[ "$MAX_CODEX_COMPACTIONS_PER_ROLE" -gt 0 && "$role_count" -ge "$MAX_CODEX_COMPACTIONS_PER_ROLE" ]]; then
        log_msg ERROR "Codex compaction recovery loop: $role_count compactions observed for $CURRENT_ROLE"
        log_msg ERROR "Last compaction log: ${CODEX_LAST_COMPACTION_LOG:-unknown}"
        log_msg ERROR "Observed state: checkpoint_status=$(test -f "$PROJECT_DIR/checkpoint_status" && tr -d '[:space:]' < "$PROJECT_DIR/checkpoint_status" || echo missing), current_role=$(read_project_role_file "$PROJECT_DIR/current_role"), next_role=$(read_project_role_file "$PROJECT_DIR/next_role")"
        print_summary "codex compaction recovery loop"
        return 1
    fi
    return 0
}

codex_runtime_start_interactive_session() {
    # Codex interactive uses tmux to wrap codex exec
    orchestrator_tmux_kill
    log_msg INFO "Creating Codex tmux session: $TMUX_SESSION"
    if ! tmux new-session -d -s "$TMUX_SESSION" -c "$PROJECT_DIR" "bash" 2>/dev/null; then
        log_msg ERROR "Failed to create Codex tmux session: $TMUX_SESSION"
        return 1
    fi
    orchestrator_configure_status_bar
    sleep 1
}

codex_runtime_prepare_iteration() {
    : # Codex starts fresh each turn via codex exec
}

codex_runtime_enter_role() {
    local prompt
    prompt=$(codex_build_role_prompt "$CURRENT_ROLE")

    local exec_options=()
    if [[ "$CODEX_EXEC_POLICY" == "bypass" ]]; then
        exec_options+=(--dangerously-bypass-approvals-and-sandbox)
    fi

    local command_parts=(codex exec)
    if [[ "$CODEX_SESSION_MODE" == "resume" ]]; then
        local thread_id
        thread_id=$(read_thread_id)
        if [[ -n "$thread_id" ]]; then
            command_parts=(codex exec resume)
            command_parts+=("${exec_options[@]}" "$thread_id" -)
        else
            command_parts+=("${exec_options[@]}" -)
            log_msg WARN "Codex session mode is resume, but no thread id exists — starting fresh"
        fi
    else
        command_parts+=("${exec_options[@]}" -)
    fi

    if [[ "$MODE" == "interactive" ]]; then
        # Write prompt to temp file for tmux
        local prompt_file prompt_file_q output_file output_file_q command
        prompt_file=$(mktemp)
        echo "$prompt" > "$prompt_file"
        printf -v prompt_file_q '%q' "$prompt_file"
        output_file="$(codex_iteration_log_file)"
        CODEX_ITERATION_OUTPUT_FILE="$output_file"
        : > "$output_file"
        printf -v output_file_q '%q' "$output_file"
        command="$(shell_join "${command_parts[@]}")"
        log_msg INFO "Sending codex exec for $CURRENT_ROLE (output: $output_file)"
        if ! tmux send-keys -t "$TMUX_SESSION" "$command < $prompt_file_q 2>&1 | tee -a $output_file_q; rm -f $prompt_file_q" Enter 2>/dev/null; then
            log_msg ERROR "Failed to send codex exec command — session may be dead"
            rm -f "$prompt_file"
            return 1
        fi
    fi
}

codex_runtime_wait_for_completion() {
    if [[ "$MODE" == "interactive" ]]; then
        if ! claude_wait_for_status_file "$PROJECT_DIR/checkpoint_status"; then
            return 1
        fi
    fi
}

codex_runtime_recover_interactive_session() {
    codex_runtime_start_interactive_session
}

codex_runtime_finish_iteration() {
    local observed_compaction=false

    if [[ -n "${CODEX_ITERATION_OUTPUT_FILE:-}" ]] && codex_detect_compaction_in_log "$CODEX_ITERATION_OUTPUT_FILE"; then
        codex_persist_compaction_observed "$CODEX_ITERATION_OUTPUT_FILE"
        observed_compaction=true
    fi
    if [[ -n "${CODEX_ITERATION_OUTPUT_FILE:-}" ]]; then
        codex_trim_iteration_log "$CODEX_ITERATION_OUTPUT_FILE"
    fi

    if [[ "$CODEX_RECOVERY_TURN_ACTIVE" == true && "$observed_compaction" == false && -f "$PROJECT_DIR/checkpoint_status" ]]; then
        codex_mark_recovered
    elif [[ "$observed_compaction" == false && -f "$CODEX_INIT_COMPLETE_FILE" ]]; then
        rm -f "$CODEX_NEEDS_REINIT_FILE" "$CODEX_INIT_COMPLETE_FILE"
        log_msg INFO "Codex reinit complete — cleared needs_reinit"
    elif [[ "$observed_compaction" == false && -f "$PROJECT_DIR/checkpoint_status" && "$(describe_continuity_state)" != "recovery_required" ]]; then
        echo "complete" > "$CODEX_CONTINUITY_STATE_FILE" 2>/dev/null || true
    fi

    CODEX_RECOVERY_TURN_ACTIVE=false
    CODEX_ITERATION_OUTPUT_FILE=""
}

codex_runtime_run_headless_role() {
    local prompt
    prompt=$(codex_build_role_prompt "$CURRENT_ROLE")

    local exec_options=()
    if [[ "$CODEX_EXEC_POLICY" == "bypass" ]]; then
        exec_options+=(--dangerously-bypass-approvals-and-sandbox)
    fi

    if [[ "$CODEX_SESSION_MODE" == "resume" ]]; then
        local thread_id
        thread_id=$(read_thread_id)
        if [[ -n "$thread_id" ]]; then
            CODEX_ITERATION_OUTPUT_FILE="$(codex_iteration_log_file)"
            log_msg INFO "Running codex exec resume for $CURRENT_ROLE (output: $CODEX_ITERATION_OUTPUT_FILE)"
            printf '%s\n' "$prompt" | codex exec resume "${exec_options[@]}" "$thread_id" - > "$CODEX_ITERATION_OUTPUT_FILE" 2>&1 || true
            return
        fi
        log_msg WARN "Codex session mode is resume, but no thread id exists — starting fresh"
    fi

    CODEX_ITERATION_OUTPUT_FILE="$(codex_iteration_log_file)"
    log_msg INFO "Running codex exec for $CURRENT_ROLE (output: $CODEX_ITERATION_OUTPUT_FILE)"
    printf '%s\n' "$prompt" | codex exec "${exec_options[@]}" - > "$CODEX_ITERATION_OUTPUT_FILE" 2>&1 || true
}

codex_runtime_attach() {
    tmux attach -t "$TMUX_SESSION" 2>/dev/null || true
}

codex_runtime_session_alive() {
    tmux has-session -t "$TMUX_SESSION" 2>/dev/null
}

codex_update_status_bar() {
    # Keep Codex visually aligned with Claude Code's orchestrator tmux bar.
    orchestrator_update_status_bar
}

codex_runtime_cleanup() {
    orchestrator_tmux_kill
}

# ============================================================
# Runtime Dispatch Layer
# ============================================================

runtime_validate() {
    case "$RUNTIME" in
        claude) claude_runtime_validate ;;
        codex)  codex_runtime_validate ;;
    esac
}

runtime_update_status_bar() {
    case "$RUNTIME" in
        claude) claude_update_status_bar ;;
        codex)  codex_update_status_bar ;;
    esac
}

runtime_start_interactive_session() {
    case "$RUNTIME" in
        claude) claude_runtime_start_interactive_session ;;
        codex)  codex_runtime_start_interactive_session ;;
    esac
}

runtime_prepare_iteration() {
    case "$RUNTIME" in
        claude) claude_runtime_prepare_iteration ;;
        codex)  codex_runtime_prepare_iteration ;;
    esac
}

runtime_enter_role() {
    case "$RUNTIME" in
        claude) claude_runtime_enter_role ;;
        codex)  codex_runtime_enter_role ;;
    esac
}

runtime_wait_for_completion() {
    case "$RUNTIME" in
        claude) claude_runtime_wait_for_completion ;;
        codex)  codex_runtime_wait_for_completion ;;
    esac
}

runtime_recover_interactive_session() {
    case "$RUNTIME" in
        claude) claude_runtime_recover_interactive_session ;;
        codex)  codex_runtime_recover_interactive_session ;;
    esac
}

runtime_finish_iteration() {
    case "$RUNTIME" in
        claude) claude_runtime_finish_iteration ;;
        codex)  codex_runtime_finish_iteration ;;
    esac
}

runtime_run_headless_role() {
    case "$RUNTIME" in
        claude) claude_runtime_run_headless_role ;;
        codex)  codex_runtime_run_headless_role ;;
    esac
}

runtime_attach() {
    case "$RUNTIME" in
        claude) claude_runtime_attach ;;
        codex)  codex_runtime_attach ;;
    esac
}

runtime_session_alive() {
    case "$RUNTIME" in
        claude) claude_runtime_session_alive ;;
        codex)  codex_runtime_session_alive ;;
    esac
}

runtime_cleanup() {
    case "$RUNTIME" in
        claude) claude_runtime_cleanup ;;
        codex)  codex_runtime_cleanup ;;
    esac
}

# --- Setup menu ---

show_settings() {
    echo ""
    echo "==========================================="
    echo "  Orchestrator — Session Settings"
    echo "==========================================="
    echo ""
    echo "  Project:       $PROJECT_DIR"
    echo "  First role:    $FIRST_ROLE ($FIRST_ROLE_REASON)"
    echo "  Runtime:       $RUNTIME"
    echo "  Mode:          $MODE"
    echo "  Iterations:    $MAX_ITERATIONS (max $MAX_FAILURES consecutive failures, max $MAX_SAME_ROLE consecutive same-role-no-commit iterations)"
    if [[ "$IDLE_TIMEOUT" -gt 0 ]]; then
        echo "  Idle timeout:  ${IDLE_TIMEOUT}s ($((IDLE_TIMEOUT / 60))m)"
    else
        echo "  Idle timeout:  disabled"
    fi
    if [[ "$WAIT_TIMEOUT" -gt 0 ]]; then
        echo "  Wait timeout:  ${WAIT_TIMEOUT}s ($((WAIT_TIMEOUT / 60))m)"
    else
        echo "  Wait timeout:  disabled"
    fi

    if [[ "$RUNTIME" == "codex" ]]; then
        local continuity_summary context_window quicksave_limit compact_limit
        continuity_summary="$(describe_continuity_state)"
        context_window="$(read_codex_context_window)"
        quicksave_limit="$(read_codex_quicksave_token_limit)"
        compact_limit="$(read_codex_auto_compact_token_limit)"
        echo ""
        echo "  --- Codex ---"
        echo "  Exec policy:   $CODEX_EXEC_POLICY"
        echo "  Session mode:  $CODEX_SESSION_MODE"
        echo "  Compaction:    controller-observed from orchestrator Codex output"
        if [[ "$CODEX_SESSION_MODE" == "resume" ]]; then
            local thread_id
            thread_id="$(read_thread_id)"
            echo "  Thread id:     ${thread_id:-none}"
        fi
        echo "  Continuity:    $continuity_summary"
        echo "  Iter logs:     .orchestrator/codex_iter_NNN.log (age/size-cleaned)"
        echo "  Log cap:       $MAX_CODEX_ITERATION_LOG_BYTES bytes"
        echo "  Manual TUI:    not covered unless launched through this orchestrator"
        [[ -n "$context_window" ]] && echo "  Context:       $context_window tokens"
        [[ -n "$quicksave_limit" ]] && echo "  Quicksave at:  $quicksave_limit input tokens (75%)"
        [[ -n "$compact_limit" ]] && echo "  Compact at:    $compact_limit input tokens (80%)"
    fi

    echo ""
    echo "==========================================="
}

interactive_setup() {
    init_runtime_state_files
    load_config
    resolve_first_role

    show_settings

    while true; do
        echo ""
        echo "Commands:  set <setting> <value>  |  go  |  quit"
        echo ""
        echo "  set role <designer|engineer|tester>"
        echo "  set mode <interactive|headless>"
        echo "  set runtime <claude|codex>"
        echo "  set codex-exec <sandboxed|bypass>"
        echo "  set codex-session <fresh|resume>"
        echo "  set iterations <number>"
        echo "  set failures <number>"
        echo "  set idle-timeout <seconds>   (0 to disable)"
        echo "  set wait-timeout <seconds>   (0 to disable, max wait per iteration)"
        echo "  set project <path>"
        echo ""
        read -rp "> " input

        input=$(echo "$input" | xargs)

        case "$input" in
            go|GO|Go)
                echo ""
                return
                ;;
            quit|QUIT|Quit|exit|q)
                echo "Exiting."
                exit 0
                ;;
            set\ role\ *)
                local val="${input#set role }"
                val=$(echo "$val" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
                if [[ "$val" =~ ^(designer|engineer|tester)$ ]]; then
                    FIRST_ROLE="$val"
                    FIRST_ROLE_REASON="manually set"
                    show_settings
                else
                    echo "  Invalid role. Use: designer, engineer, or tester"
                fi
                ;;
            set\ mode\ *)
                local val="${input#set mode }"
                val=$(echo "$val" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
                if [[ "$val" == "interactive" || "$val" == "headless" ]]; then
                    MODE="$val"
                    save_config
                    show_settings
                else
                    echo "  Invalid mode. Use: interactive or headless"
                fi
                ;;
            set\ runtime\ *)
                local val="${input#set runtime }"
                val=$(echo "$val" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
                if [[ "$val" == "claude" || "$val" == "codex" ]]; then
                    RUNTIME="$val"
                    save_config
                    show_settings
                else
                    echo "  Invalid runtime. Use: claude or codex"
                fi
                ;;
            set\ codex-exec\ *)
                local val="${input#set codex-exec }"
                val=$(echo "$val" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
                if [[ "$val" == "sandboxed" || "$val" == "bypass" ]]; then
                    CODEX_EXEC_POLICY="$val"
                    save_config
                    show_settings
                else
                    echo "  Invalid Codex exec policy. Use: sandboxed or bypass"
                fi
                ;;
            set\ codex-session\ *)
                local val="${input#set codex-session }"
                val=$(echo "$val" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
                if [[ "$val" == "fresh" || "$val" == "resume" ]]; then
                    CODEX_SESSION_MODE="$val"
                    save_config
                    show_settings
                else
                    echo "  Invalid Codex session mode. Use: fresh or resume"
                fi
                ;;
            set\ iterations\ *)
                local val="${input#set iterations }"
                if [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -gt 0 ]]; then
                    MAX_ITERATIONS="$val"
                    save_config
                    show_settings
                else
                    echo "  Invalid number. Must be a positive integer."
                fi
                ;;
            set\ failures\ *)
                local val="${input#set failures }"
                if [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -gt 0 ]]; then
                    MAX_FAILURES="$val"
                    save_config
                    show_settings
                else
                    echo "  Invalid number. Must be a positive integer."
                fi
                ;;
            set\ same-role\ *)
                local val="${input#set same-role }"
                if [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -gt 0 ]]; then
                    MAX_SAME_ROLE="$val"
                    save_config
                    show_settings
                else
                    echo "  Invalid number. Must be a positive integer."
                fi
                ;;
            set\ idle-timeout\ *)
                local val="${input#set idle-timeout }"
                if [[ "$val" =~ ^[0-9]+$ ]]; then
                    IDLE_TIMEOUT="$val"
                    save_config
                    show_settings
                else
                    echo "  Invalid number. Must be a non-negative integer (0 to disable)."
                fi
                ;;
            set\ wait-timeout\ *)
                local val="${input#set wait-timeout }"
                if [[ "$val" =~ ^[0-9]+$ ]]; then
                    WAIT_TIMEOUT="$val"
                    save_config
                    show_settings
                else
                    echo "  Invalid number. Must be a non-negative integer (0 to disable)."
                fi
                ;;
            set\ project\ *)
                local val="${input#set project }"
                if [[ -d "$val" ]]; then
                    PROJECT_DIR="$val"
                    FIRST_ROLE=""
                    FIRST_ROLE_REASON=""
                    init_runtime_state_files
                    load_config
                    resolve_first_role
                    show_settings
                else
                    echo "  Directory does not exist: $val"
                fi
                ;;
            "")
                ;;
            *)
                echo "  Unknown command. Type 'go' to launch or 'quit' to exit."
                ;;
        esac
    done
}

# --- Orchestrator loop ---

run_loop() {
    LOOP_START_TIME=$(date +%s)

    while true; do
        if [[ -f "$ORCHESTRATOR_STOP_FILE" ]]; then
            log_msg INFO "Stop requested from tmux"
            print_summary "interrupted"
            return 130
        fi

        ITERATION=$((ITERATION + 1))
        ITER_START_TIME=$(date +%s)

        # --- Determine next role ---
        local role reason
        CODEX_RECOVERY_TURN_ACTIVE=false
        if [[ "$RUNTIME" == "codex" ]] && codex_recovery_required; then
            local recovery_info
            recovery_info=$(codex_select_recovery_role)
            role="${recovery_info%%|*}"
            reason="${recovery_info#*|}"
            CODEX_RECOVERY_TURN_ACTIVE=true
            log_msg WARN "Codex recovery routing: role=$role; reason=$reason; checkpoint_status=$(test -f "$PROJECT_DIR/checkpoint_status" && tr -d '[:space:]' < "$PROJECT_DIR/checkpoint_status" || echo missing); current_role=$(read_project_role_file "$PROJECT_DIR/current_role"); next_role=$(read_project_role_file "$PROJECT_DIR/next_role")"
        elif [[ "$ITERATION" -eq 1 ]]; then
            role="$FIRST_ROLE"
            reason="first role"
        else
            local role_info
            role_info=$(read_next_role)
            role="${role_info%%|*}"
            reason="${role_info#*|}"
        fi

        CURRENT_ROLE="$role"

        if [[ "$RUNTIME" == "codex" ]] && [[ "$CODEX_RECOVERY_TURN_ACTIVE" == true ]]; then
            if ! codex_check_recovery_loop_protection; then
                return 1
            fi
        fi

        local current_head
        current_head=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "")

        if [[ -n "$PREV_ROLE" && "$role" == "$PREV_ROLE" && -n "$current_head" && "$current_head" == "$PREV_HEAD" ]]; then
            CONSECUTIVE_SAME_ROLE=$((CONSECUTIVE_SAME_ROLE + 1))
        else
            CONSECUTIVE_SAME_ROLE=1
        fi
        PREV_ROLE="$role"
        PREV_HEAD="$current_head"

        log_msg INFO "--- Iteration $ITERATION: $role ($reason) [runtime=$RUNTIME] [same-role-no-commit streak=$CONSECUTIVE_SAME_ROLE] ---"
        runtime_update_status_bar

        # --- Delete checkpoint_status so we can detect a fresh write ---
        rm -f "$PROJECT_DIR/checkpoint_status"
        log_msg INFO "Cleared checkpoint_status"

        # --- Launch the role ---
        if ! runtime_prepare_iteration; then
            log_msg WARN "Prepare iteration failed — recovering session"
            runtime_recover_interactive_session || true
            continue
        fi

        if [[ "$MODE" == "interactive" ]]; then
            if ! runtime_enter_role; then
                log_msg WARN "Enter role failed — recovering session"
                runtime_recover_interactive_session || true
                continue
            fi
            if ! runtime_wait_for_completion; then
                if [[ -f "$ORCHESTRATOR_STOP_FILE" ]]; then
                    log_msg INFO "Stop requested from tmux"
                    print_summary "interrupted"
                    return 130
                fi
                log_msg WARN "Wait for completion failed — recovering session"
                runtime_recover_interactive_session || true
            fi
            runtime_finish_iteration
        else
            runtime_run_headless_role
            runtime_finish_iteration
        fi

        # --- Log iteration duration ---
        local iter_end iter_duration iter_formatted
        iter_end=$(date +%s)
        iter_duration=$((iter_end - ITER_START_TIME))
        iter_formatted=$(format_duration "$iter_duration")

        # --- Check if /endsession ran ---
        local status_file="$PROJECT_DIR/checkpoint_status"
        if [[ -f "$status_file" ]]; then
            CONSECUTIVE_FAILURES=0
            local checkpoint
            checkpoint=$(tr -d '[:space:]' < "$status_file" | tr '[:upper:]' '[:lower:]')
            log_msg INFO "Session complete: checkpoint_status=$checkpoint (${iter_formatted})"

            if [[ "$checkpoint" == "yes" ]]; then
                log_msg INFO "CHECKPOINT READY FOR HUMAN TESTING — automated-role work exhausted"
                print_summary "checkpoint ready"
                return 0
            elif [[ "$checkpoint" == "blocked" ]]; then
                log_msg INFO "DESIGNER BLOCKED ON HUMAN — orchestrator yielding until Human unblocks PT-3.0 items"
                print_summary "designer blocked"
                return 0
            elif [[ "$checkpoint" == "done" ]]; then
                log_msg INFO "ALL WORK COMPLETE — no remaining tasks for any role"
                print_summary "all work complete"
                return 0
            fi
        else
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
            log_msg WARN "Session did not produce checkpoint_status after ${iter_formatted} (consecutive failures: $CONSECUTIVE_FAILURES)"
        fi

        # --- Safety limits ---
        if [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
            log_msg WARN "Max iterations reached ($MAX_ITERATIONS)"
            print_summary "max iterations"
            return 1
        fi

        if [[ "$CONSECUTIVE_FAILURES" -ge "$MAX_FAILURES" ]]; then
            log_msg ERROR "$MAX_FAILURES consecutive failures — stopping"
            print_summary "consecutive failures"
            return 1
        fi

        if [[ "$MAX_SAME_ROLE" -gt 0 && "$CONSECUTIVE_SAME_ROLE" -ge "$MAX_SAME_ROLE" ]]; then
            log_msg ERROR "$MAX_SAME_ROLE consecutive iterations of $role with no new commits — stopping to prevent runaway"
            print_summary "same-role loop"
            return 1
        fi
    done
}

# --- Summary ---

print_summary() {
    local reason="$1"
    local total_elapsed total_formatted
    total_elapsed=$(( $(date +%s) - LOOP_START_TIME ))
    total_formatted=$(format_duration "$total_elapsed")

    log_msg INFO "========================================="
    log_msg INFO "Orchestrator Summary"
    log_msg INFO "========================================="
    log_msg INFO "Exit reason:  $reason"
    log_msg INFO "Runtime:      $RUNTIME"
    log_msg INFO "Iterations:   $ITERATION"
    log_msg INFO "Total time:   $total_formatted"
    log_msg INFO "Log:          $MASTER_LOG"
    log_msg INFO "========================================="
}

# --- Signal handling ---

cleanup() {
    local reason="${1:-interrupted}"
    if [[ -n "$LOOP_PID" ]]; then
        kill "$LOOP_PID" 2>/dev/null
        wait "$LOOP_PID" 2>/dev/null || true
    fi
    runtime_cleanup
    if [[ -n "${MASTER_LOG:-}" ]]; then
        if [[ "$reason" == "disconnected" ]]; then
            log_msg WARN "Terminal disconnected (SIGHUP). Orchestrator stopped — relaunch after reconnecting."
        else
            log_msg INFO "Interrupted."
        fi
        print_summary "$reason"
    fi
    exit 130
}

trap cleanup SIGINT SIGTERM
trap 'cleanup disconnected' SIGHUP

# --- Main ---

main() {
    if [[ ! -d "$PROJECT_DIR" ]]; then
        echo "Error: project directory does not exist: $PROJECT_DIR" >&2
        exit 1
    fi

    # Setup menu
    interactive_setup

    if [[ ! -d "$PROJECT_DIR" ]]; then
        echo "Error: project directory does not exist: $PROJECT_DIR" >&2
        exit 1
    fi

    cd "$PROJECT_DIR"
    PROJECT_NAME="$(basename "$PROJECT_DIR")"
    TMUX_SESSION="orch-$PROJECT_NAME"

    runtime_validate

    # Set up logging
    LOG_DIR="$PROJECT_DIR/.orchestrator"
    mkdir -p "$LOG_DIR"
    init_runtime_state_files
    rm -f "$ORCHESTRATOR_STOP_FILE"
    MASTER_LOG="$LOG_DIR/orchestrator_$(date '+%Y%m%d_%H%M%S').log"

    log_msg INFO "Orchestrator started"
    log_msg INFO "Project:    $PROJECT_DIR"
    log_msg INFO "First role: $FIRST_ROLE"
    log_msg INFO "Mode:       $MODE"
    log_msg INFO "Runtime:    $RUNTIME"
    log_msg INFO "Max iters:  $MAX_ITERATIONS"
    log_msg INFO "Max fails:  $MAX_FAILURES"
    log_msg INFO "Max same-role: $MAX_SAME_ROLE"
    if [[ "$RUNTIME" == "codex" ]]; then
        log_msg INFO "Codex compaction recovery: controller-observed from orchestrator output"
        log_msg INFO "Codex compaction logs: $LOG_DIR/codex_iter_NNN.log"
        log_msg INFO "Codex iteration log cap: $MAX_CODEX_ITERATION_LOG_BYTES bytes"
        log_msg INFO "Max Codex compactions per role: $MAX_CODEX_COMPACTIONS_PER_ROLE"
    fi
    if [[ "$IDLE_TIMEOUT" -gt 0 ]]; then
        log_msg INFO "Idle timeout: ${IDLE_TIMEOUT}s ($((IDLE_TIMEOUT / 60))m)"
    else
        log_msg INFO "Idle timeout: disabled"
    fi
    if [[ "$WAIT_TIMEOUT" -gt 0 ]]; then
        log_msg INFO "Wait timeout: ${WAIT_TIMEOUT}s ($((WAIT_TIMEOUT / 60))m)"
    else
        log_msg INFO "Wait timeout: disabled"
    fi

    cleanup_old_logs

    # Add .orchestrator to .gitignore if not already there
    if [[ ! -f "$PROJECT_DIR/.gitignore" ]] || ! grep -q '^\.orchestrator/' "$PROJECT_DIR/.gitignore" 2>/dev/null; then
        echo '.orchestrator/' >> "$PROJECT_DIR/.gitignore"
    fi

    if [[ "$MODE" == "interactive" ]]; then
        log_msg INFO "Starting interactive session"
        if ! runtime_start_interactive_session; then
            log_msg ERROR "Failed to start interactive session — aborting"
            exit 1
        fi

        (
            run_loop || true
            log_msg INFO "Loop exited — cleaning up"
            runtime_cleanup
        ) &
        LOOP_PID=$!
        log_msg INFO "Background loop started (PID: $LOOP_PID)"

        echo "==========================================="
        echo "  Attaching to live session..."
        echo ""
        echo "  While attached (inside tmux):"
        if [[ "$RUNTIME" == "codex" ]]; then
            echo "    Ctrl+C          — stop the orchestrator"
        fi
        echo "    Ctrl+B then D  — detach (agent keeps working)"
        echo "    Ctrl+B then k  — stop the orchestrator (kills tmux; confirm with y)"
        echo ""
        echo "  After detaching (outer shell):"
        echo "    tmux attach -t $TMUX_SESSION  — reattach"
        echo "    Ctrl+C                        — stop the orchestrator"
        echo ""
        if [[ "$RUNTIME" != "codex" ]]; then
            echo "  Ctrl+C while attached interrupts the current agent turn, not the orchestrator."
        fi
        echo "==========================================="
        echo ""
        sleep 2

        runtime_attach
        if [[ -f "$ORCHESTRATOR_STOP_FILE" ]]; then
            cleanup interrupted
        fi

        while runtime_session_alive; do
            echo ""
            echo "Detached. Agent is still working."
            echo "Press Enter to reattach, or Ctrl+C to stop."
            read -r
            runtime_attach
            if [[ -f "$ORCHESTRATOR_STOP_FILE" ]]; then
                cleanup interrupted
            fi
        done
        kill "$LOOP_PID" 2>/dev/null || true
        wait "$LOOP_PID" 2>/dev/null || true

        echo ""
        echo "==========================================="
        tail -9 "$MASTER_LOG"
        echo "==========================================="
    else
        run_loop
        exit $?
    fi
}

main "$@"
