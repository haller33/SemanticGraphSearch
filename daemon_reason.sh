#!/usr/bin/env bash
# services.sh - start/stop background NARS pipeline services

# touch input.nal
# touch derived.nal

# original one
# In a dedicated terminal
# tail -f input.nal | python3 narsese2json.v2.py --tag input | uv run --with requests python send2graph.py &
# tail -f input.nal | ../OpenNARS-for-Applications/NAR shell >> derived.nal &
# tail -f derived.nal |
#     sh filter_derived.sh --min-confidence 0.4 --min-priority 0.8 |
#     sh extract_derived.sh | python3 narsese2json.v2.py --tag derived |
#     uv run --with requests python send2graph.py --color "#ff0000" &

# services.sh - start/stop background NARS pipeline services

# --- Configuration ---
INPUT_FILE="input.nal"
DERIVED_FILE="derived.nal"
NAR_BINARY="../OpenNARS-for-Applications/NAR"   # adjust path if needed
FILTER_SCRIPT="lua ./filter_derived.lua"
EXTRACT_SCRIPT="./extract_derived.sh"
PID_DIR="./tmp"
PID_FILE="$PID_DIR/nars_services.pids"

# ----------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------
start_services() {
    echo "Starting NARS background services..."

    mkdir -p "$PID_DIR"

    # Ensure input and derived files exist
    touch "$INPUT_FILE" "$DERIVED_FILE"

    # 1. Send input.nal to graph (tag 'input')
    tail -f "$INPUT_FILE" | python3 narsese2json.v2.py --tag input | uv run --with requests python send2graph.py &
    PID1=$!
    echo "Service 1 (input → graph) PID: $PID1"

    # 2. Feed input.nal to NARS Shell, output appended to derived.nal
    tail -f "$INPUT_FILE" | "$NAR_BINARY" shell >> "$DERIVED_FILE" &
    PID2=$!
    echo "Service 2 (input → NAR → derived.nal) PID: $PID2"

    # 3. Filter derived.nal, extract derived statements, send to graph (tag 'derived', red color)
    tail -f "$DERIVED_FILE" | "$FILTER_SCRIPT" --min-confidence 0.4 --min-priority 0.8 |
        "$EXTRACT_SCRIPT" | python3 narsese2json.v2.py --tag derived |
        uv run --with requests python send2graph.py --color "#ff0000" &
    PID3=$!
    echo "Service 3 (derived → filter → extract → graph) PID: $PID3"

    # Save PIDs with service names
    cat > "$PID_FILE" <<EOF
input_graph:$PID1
nar_shell:$PID2
derived_graph:$PID3
EOF

    echo "All services started. PIDs saved to $PID_FILE"
}

stop_services() {
    if [[ ! -f "$PID_FILE" ]]; then
        echo "PID file not found. Are services running?"
        exit 1
    fi

    echo "Stopping services:"
    while IFS=: read -r name pid; do
        echo "  - $name (PID $pid)"
        kill -TERM "$pid" 2>/dev/null
    done < "$PID_FILE"

    sleep 1
    # Force kill if still alive
    while IFS=: read -r name pid; do
        kill -KILL "$pid" 2>/dev/null
    done < "$PID_FILE"

    rm -f "$PID_FILE"
    echo "All services stopped."
}

status_services() {
    if [[ ! -f "$PID_FILE" ]]; then
        echo "No PID file found. Services are not running (or have crashed)."
        exit 1
    fi

    echo "Service status:"
    while IFS=: read -r name pid; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "  ✓ $name (PID $pid) is running."
        else
            echo "  ✗ $name (PID $pid) is NOT running."
        fi
    done < "$PID_FILE"
}

# ----------------------------------------------------------------------
# Main command parsing
# ----------------------------------------------------------------------
case "$1" in
    start)
        start_services
        ;;
    stop)
        stop_services
        ;;
    restart)
        stop_services
        sleep 2
        start_services
        ;;
    status)
        status_services
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
