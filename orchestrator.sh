#!/usr/bin/env bash
#
# orchestrator.sh — Drives the Designer → Engineer → Tester loop
#
# Launches each role as a separate Claude CLI session and loops until
# the checkpoint is ready for human testing (or a safety limit is hit).
#
# The agent writes three files during /endsession:
#   current_role       — who just ran
#   next_role          — who should run next
#   checkpoint_status  — "yes" when ready for human testing
#
# The script just reads these files. No output parsing.
#
# Modes:
#   interactive — runs claude in a tmux session, you watch live
#   headless    — runs claude -p in the background, no UI
#
set -euo pipefail

# --- Defaults ---
PROJECT_DIR="$(pwd)"
MAX_ITERATIONS=100
MAX_FAILURES=3
FIRST_ROLE=""
MODE=interactive
TMUX_SESSION="orchestrator"
POLL_INTERVAL=5

# --- Runtime state ---
ITERATION=0
CONSECUTIVE_FAILURES=0
LOG_DIR=""
MASTER_LOG=""
CONFIG_FILE=""

# --- Config persistence ---

load_config() {
    CONFIG_FILE="$PROJECT_DIR/.orchestrator/config"
    if [[ -f "$CONFIG_FILE" ]]; then
        while IFS='=' read -r key val; do
            [[ -z "$key" || "$key" == \#* ]] && continue
            val=$(echo "$val" | xargs)
            case "$key" in
                max_iterations) MAX_ITERATIONS="$val" ;;
                max_failures)   MAX_FAILURES="$val" ;;
                mode)           MODE="$val" ;;
            esac
        done < "$CONFIG_FILE"
    else
        save_config
    fi
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<EOF
max_iterations=$MAX_ITERATIONS
max_failures=$MAX_FAILURES
mode=$MODE
EOF
}

# --- Logging ---
log_msg() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local msg="[$timestamp] [$level] $*"
    if [[ -n "${MASTER_LOG:-}" ]]; then
        echo "$msg" >> "$MASTER_LOG"
    fi
    # In headless mode, also print to stderr
    if [[ "$MODE" == "headless" ]]; then
        echo "$msg" >&2
    fi
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

# --- Setup menu ---

show_settings() {
    echo ""
    echo "==========================================="
    echo "  Orchestrator — Session Settings"
    echo "==========================================="
    echo ""
    echo "  Project directory:     $PROJECT_DIR"
    echo "  First role:            $FIRST_ROLE ($FIRST_ROLE_REASON)"
    echo "  Mode:                  $MODE"
    echo "  Max iterations:        $MAX_ITERATIONS"
    echo "  Max consecutive fails: $MAX_FAILURES"
    echo ""
    echo "==========================================="
}

interactive_setup() {
    load_config
    resolve_first_role

    show_settings

    while true; do
        echo ""
        echo "Commands:  set <setting> <value>  |  go  |  quit"
        echo ""
        echo "  set role <designer|engineer|tester>"
        echo "  set mode <interactive|headless>"
        echo "  set iterations <number>"
        echo "  set failures <number>"
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
            set\ project\ *)
                local val="${input#set project }"
                if [[ -d "$val" ]]; then
                    PROJECT_DIR="$val"
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

# --- tmux helpers ---

tmux_send() {
    tmux send-keys -t "$TMUX_SESSION" "$1" Enter
}

tmux_kill() {
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
}

wait_for_file_update() {
    local target="$1"
    local marker="$2"
    while true; do
        if [[ -f "$target" && "$target" -nt "$marker" ]]; then
            return 0
        fi
        sleep "$POLL_INTERVAL"
    done
}

# --- Orchestrator loop (runs in background for interactive mode) ---

run_loop() {
    while true; do
        ITERATION=$((ITERATION + 1))

        # --- Determine next role ---
        local role reason
        if [[ "$ITERATION" -eq 1 ]]; then
            role="$FIRST_ROLE"
            reason="first role"
        else
            local role_info
            role_info=$(read_next_role)
            role="${role_info%%|*}"
            reason="${role_info#*|}"
        fi

        log_msg INFO "--- Iteration $ITERATION: $role ($reason) ---"

        # --- Record session start for failure detection ---
        local marker="$LOG_DIR/session_start"
        touch "$marker"

        # --- Launch the role ---
        if [[ "$MODE" == "interactive" ]]; then
            if [[ "$ITERATION" -gt 1 ]]; then
                tmux_send "/clear"
                sleep 2
            fi
            tmux_send "/$role"
            wait_for_file_update "$PROJECT_DIR/checkpoint_status" "$marker"
            sleep 2
        else
            claude -p "/$role" < /dev/null > /dev/null 2>&1 || true
        fi

        # --- Check if /endsession ran ---
        local status_file="$PROJECT_DIR/checkpoint_status"
        if [[ -f "$status_file" && "$status_file" -nt "$marker" ]]; then
            CONSECUTIVE_FAILURES=0
            local checkpoint
            checkpoint=$(tr -d '[:space:]' < "$status_file" | tr '[:upper:]' '[:lower:]')
            log_msg INFO "Session complete: checkpoint_status=$checkpoint"

            if [[ "$checkpoint" == "yes" ]]; then
                log_msg INFO "CHECKPOINT READY FOR HUMAN TESTING"
                print_summary "checkpoint ready"
                return 0
            fi
        else
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
            log_msg WARN "Session did not produce checkpoint_status (consecutive failures: $CONSECUTIVE_FAILURES)"
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
    done
}

# --- Summary ---

print_summary() {
    local reason="$1"
    log_msg INFO "========================================="
    log_msg INFO "Orchestrator Summary"
    log_msg INFO "========================================="
    log_msg INFO "Exit reason:  $reason"
    log_msg INFO "Iterations:   $ITERATION"
    log_msg INFO "Log:          $MASTER_LOG"
    log_msg INFO "========================================="
}

# --- Signal handling ---

cleanup() {
    if [[ "$MODE" == "interactive" ]]; then
        tmux_kill
    fi
    if [[ -n "${MASTER_LOG:-}" ]]; then
        log_msg INFO "Interrupted."
        print_summary "interrupted"
    fi
    exit 130
}

trap cleanup SIGINT SIGTERM

# --- Main ---

main() {
    if [[ ! -d "$PROJECT_DIR" ]]; then
        echo "Error: project directory does not exist: $PROJECT_DIR" >&2
        exit 1
    fi

    cd "$PROJECT_DIR"

    # Setup menu
    interactive_setup

    # Verify tmux for interactive mode
    if [[ "$MODE" == "interactive" ]] && ! command -v tmux &>/dev/null; then
        echo "Error: interactive mode requires tmux. Install it or set mode to headless." >&2
        exit 1
    fi

    # Set up logging
    LOG_DIR="$PROJECT_DIR/.orchestrator"
    mkdir -p "$LOG_DIR"
    MASTER_LOG="$LOG_DIR/orchestrator_$(date '+%Y%m%d_%H%M%S').log"

    log_msg INFO "Orchestrator started"
    log_msg INFO "Project:    $PROJECT_DIR"
    log_msg INFO "First role: $FIRST_ROLE"
    log_msg INFO "Mode:       $MODE"
    log_msg INFO "Max iters:  $MAX_ITERATIONS"
    log_msg INFO "Max fails:  $MAX_FAILURES"

    # Add .orchestrator to .gitignore if not already there
    if [[ ! -f "$PROJECT_DIR/.gitignore" ]] || ! grep -q '^\.orchestrator/' "$PROJECT_DIR/.gitignore" 2>/dev/null; then
        echo '.orchestrator/' >> "$PROJECT_DIR/.gitignore"
    fi

    if [[ "$MODE" == "interactive" ]]; then
        # Clean up any old session
        tmux_kill

        # Start claude in a detached tmux session
        tmux new-session -d -s "$TMUX_SESSION" -c "$PROJECT_DIR" "claude"
        sleep 3

        # Run the orchestrator loop in the background.
        # When the loop finishes, it kills the tmux session,
        # which causes tmux attach to return and the user sees the summary.
        (
            run_loop || true
            tmux_kill
        ) &
        local loop_pid=$!

        # Show tips before attaching
        echo "==========================================="
        echo "  Attaching to live session..."
        echo ""
        echo "  Ctrl+B then D  — detach (agent keeps working)"
        echo "  tmux attach -t $TMUX_SESSION  — reattach"
        echo "  Ctrl+C          — stop the orchestrator"
        echo "==========================================="
        echo ""
        sleep 2

        # Attach the user to the tmux session — they watch the agent work.
        # This blocks until the session ends or the user detaches.
        tmux attach -t "$TMUX_SESSION" 2>/dev/null || true

        # If the user manually detached (tmux session still alive), offer reattach.
        # If the loop finished and killed the session, go straight to summary.
        while tmux has-session -t "$TMUX_SESSION" 2>/dev/null; do
            echo ""
            echo "Detached. Agent is still working."
            echo "Press Enter to reattach, or Ctrl+C to stop."
            read -r
            tmux attach -t "$TMUX_SESSION" 2>/dev/null || true
        done
        wait "$loop_pid" 2>/dev/null || true

        # Show summary
        echo ""
        echo "==========================================="
        tail -8 "$MASTER_LOG"
        echo "==========================================="
    else
        # Headless: run the loop directly
        run_loop
        exit $?
    fi
}

main "$@"
