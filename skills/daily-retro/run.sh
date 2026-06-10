#!/bin/bash
# daily-retro scheduler wrapper. Catch-up aware: walks back N days and runs any
# past day with no .done marker (covers powered-off misses, not just sleep).
# Today runs only at/after the configured hour. Rate-limit aware: classifies
# limit failures, waits until the advertised reset (or a fixed backoff) and
# retries. Single-instance via a lock dir. No --dangerously-skip-permissions:
# uses acceptEdits + an explicit allowlist instead.
set -uo pipefail

CLAUDE_HOME="$HOME/.claude"
RETRO_DIR="$CLAUDE_HOME/retro"
LOG="$RETRO_DIR/launchd.log"
CONFIG="$CLAUDE_HOME/skills/daily-retro/config.env"
LOCK_DIR="$RETRO_DIR/.run.lock"

# Defaults (overridable by config.env written by install.sh)
MODE="apply"
CATCHUP_DAYS=7
RUN_HOUR=18
ALLOWED="Read,Write,Edit,Bash,Grep,Glob,Skill,Agent,Task"
RETRO_MODEL=""          # empty = account default; e.g. "sonnet" to spare opus quota
RETRY_MAX=3             # rate-limit retries per date
RETRY_FALLBACK_MIN=60   # wait when the reset time can't be parsed
RETRY_CAP_MIN=300       # never wait longer than this for one retry
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"

CLAUDE_BIN="$HOME/.local/bin/claude"
[ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$(command -v claude)"
[ -n "$CLAUDE_BIN" ] || { echo "[$(date '+%F %T')] ERROR: claude binary not found" >> "$LOG"; exit 1; }

mkdir -p "$RETRO_DIR"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# --- single-instance lock (mkdir is atomic; stale if owner pid is gone) ---
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    return 0
  fi
  local owner
  owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    log "SKIP  another run holds the lock (pid $owner)"
    return 1
  fi
  log "WARN  stale lock (pid ${owner:-?}) — reclaiming"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null && echo $$ > "$LOCK_DIR/pid"
}
release_lock() { rm -rf "$LOCK_DIR"; }
trap release_lock EXIT

acquire_lock || exit 0

# Portable "date N days ago" (BSD/macOS vs GNU/Linux)
days_ago() {
  if date -v-1d +%F >/dev/null 2>&1; then date -v-"$1"d +%F; else date -d "$1 days ago" +%F; fi
}

# Epoch for a clock-time like "8:30pm" today (BSD vs GNU); empty on failure.
clock_to_epoch() {
  date -j -f "%I:%M%p" "$1" +%s 2>/dev/null || date -d "$1" +%s 2>/dev/null || true
}

is_rate_limited() {
  tail -5 "$1" 2>/dev/null | grep -qiE "hit your (session|usage) limit|usage limit (reached|hit)|rate.?limit"
}

# Seconds until the advertised reset ("resets 8:30pm (...)"), bounded by
# RETRY_CAP_MIN; falls back to RETRY_FALLBACK_MIN when unparseable.
rate_limit_wait_secs() {
  local run_log="$1" clock reset_epoch now wait_s
  clock="$(tail -5 "$run_log" 2>/dev/null | grep -oiE "resets[^0-9]*[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)" | grep -oiE "[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)" | head -1 | tr -d '[:space:]')"
  if [ -n "$clock" ]; then
    case "$clock" in
      *:*) ;;
      *)   clock="$(echo "$clock" | sed -E 's/^([0-9]{1,2})(am|pm)$/\1:00\2/i')" ;;
    esac
    reset_epoch="$(clock_to_epoch "$clock")"
    now="$(date +%s)"
    if [ -n "$reset_epoch" ]; then
      [ "$reset_epoch" -le "$now" ] && reset_epoch=$((reset_epoch + 86400))
      wait_s=$((reset_epoch - now + 120))
      [ "$wait_s" -gt $((RETRY_CAP_MIN * 60)) ] && wait_s=$((RETRY_CAP_MIN * 60))
      echo "$wait_s"; return 0
    fi
  fi
  echo $((RETRY_FALLBACK_MIN * 60))
}

invoke_claude() {
  local d="$1" run_log="$2"
  local model_args=()
  [ -n "$RETRO_MODEL" ] && model_args=(--model "$RETRO_MODEL")
  cd "$CLAUDE_HOME" || return 1
  "$CLAUDE_BIN" -p "/daily-retro $d $MODE" \
    --permission-mode acceptEdits \
    --allowedTools "$ALLOWED" \
    ${model_args[@]+"${model_args[@]}"} \
    >> "$run_log" 2>&1
}

run_for_date() {
  local d="$1"
  local day_dir="$RETRO_DIR/$d"
  local marker="$day_dir/.done"
  local run_log="$day_dir/run.log"
  [ -f "$marker" ] && return 0
  mkdir -p "$day_dir"

  local attempt=0 rc wait_s
  while :; do
    attempt=$((attempt + 1))
    log "START retro $d (mode=$MODE attempt=$attempt)"
    invoke_claude "$d" "$run_log"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      touch "$marker"
      log "DONE  retro $d"
      return 0
    fi
    if is_rate_limited "$run_log" && [ "$attempt" -le "$RETRY_MAX" ]; then
      wait_s="$(rate_limit_wait_secs "$run_log")"
      log "RATE-LIMITED retro $d (rc=$rc) — retry $attempt/$RETRY_MAX in $((wait_s / 60))m"
      sleep "$wait_s"
      continue
    fi
    log "FAIL  retro $d (rc=$rc attempts=$attempt)"
    return "$rc"
  done
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
