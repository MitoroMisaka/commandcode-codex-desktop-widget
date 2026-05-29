#!/bin/bash
# Widget health watchdog — runs every 5 minutes, logs status.
# Usage: nohup bash scripts/watchdog.sh &

LOG="$HOME/.hermes/logs/widget-watchdog.log"
WIDGET_LOG="$HOME/.hermes/logs/widget.log"
APP_NAME="CommandCodeCodexWidget"

mkdir -p "$(dirname "$LOG")"

while true; do
    PID=$(pgrep -f "$APP_NAME" | head -1)
    NOW=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ -z "$PID" ]; then
        echo "[$NOW] DEAD — process not found" >> "$LOG"
    else
        ELAPSED=$(ps -o etime= -p "$PID" 2>/dev/null | tr -d ' ')
        CHILDREN=$(pgrep -P "$PID" 2>/dev/null | wc -l | tr -d ' ')
        LAST_LOG=$(tail -1 "$WIDGET_LOG" 2>/dev/null)
        LAST_TS=$(echo "$LAST_LOG" | grep -oE '^\[[0-9:.]+\]' | tr -d '[]')
        
        # Check if last log entry is older than 5 minutes
        STALE="ok"
        if [ -n "$LAST_TS" ]; then
            LAST_SEC=$(echo "$LAST_TS" | awk -F: '{ print ($1 * 3600) + ($2 * 60) + $3 }')
            NOW_SEC=$(date +%H:%M:%S | awk -F: '{ print ($1 * 3600) + ($2 * 60) + $3 }')
            DIFF=$((NOW_SEC - LAST_SEC))
            if [ "$DIFF" -gt 600 ]; then
                STALE="STALE(last_log_${DIFF}s_ago)"
            fi
        fi
        
        echo "[$NOW] OK pid=$PID elapsed=$ELAPSED children=$CHILDREN $STALE | $LAST_LOG" >> "$LOG"
    fi
    
    sleep 300
done
