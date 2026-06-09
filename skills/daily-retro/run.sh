#!/bin/bash
# daily-retro scheduler wrapper. Catch-up aware: walks back N days and runs any
# past day with no .done marker (covers powered-off misses, not just sleep).
# Today runs only at/after the configured hour. No --dangerously-skip-permissions:
# uses acceptEdits + an explicit allowlist instead.
set -uo pipefail

CLAUDE_HOME="$HOME/.claude"
RETRO_DIR="$CLAUDE_HOME/retro"
LOG="$RETRO_DIR/launchd.log"
CONFIG="$CLAUDE_HOME/skills/daily-retro/config.env"

# Defaults (overridable by config.env written by install.sh)
MODE="apply"
CATCHUP_DAYS=7
RUN_HOUR=18
ALLOWED="Read,Write,Edit,Bash,Grep,Glob,Skill,Agent,Task"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"

CLAUDE_BIN="$HOME/.local/bin/claude"
[ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$(command -v claude)"
[ -n "$CLAUDE_BIN" ] || { echo "[$(date '+%F %T')] ERROR: claude binary not found" >> "$LOG"; exit 1; }

mkdir -p "$RETRO_DIR"

# Portable "date N days ago" (BSD/macOS vs GNU/Linux)
days_ago() {
  if date -v-1d +%F >/dev/null 2>&1; then date -v-"$1"d +%F; else date -d "$1 days ago" +%F; fi
}

run_for_date() {
  local d="$1"
  local day_dir="$RETRO_DIR/$d"
  local marker="$day_dir/.done"
  [ -f "$marker" ] && return 0
  mkdir -p "$day_dir"
  echo "[$(date '+%F %T')] START retro $d (mode=$MODE)" >> "$LOG"
  cd "$CLAUDE_HOME" || return 1
  "$CLAUDE_BIN" -p "/daily-retro $d $MODE" \
    --permission-mode acceptEdits \
    --allowedTools "$ALLOWED" \
    >> "$day_dir/run.log" 2>&1
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    touch "$marker"
    echo "[$(date '+%F %T')] DONE  retro $d" >> "$LOG"
  else
    echo "[$(date '+%F %T')] FAIL  retro $d (rc=$rc)" >> "$LOG"
  fi
}

HOUR=$(date +%H)

# Catch-up: oldest-first so changelog versions land in chronological order.
for ((i=CATCHUP_DAYS; i>=1; i--)); do
  run_for_date "$(days_ago "$i")"
done

# Today only once past the configured hour.
if [ "$((10#$HOUR))" -ge "$((10#$RUN_HOUR))" ]; then
  run_for_date "$(date +%F)"
fi
