#!/bin/bash
# daily-retro scheduler wrapper. Catch-up aware: walks back N days and runs any
# past day with no .done marker (covers powered-off misses, not just sleep).
# Today runs only at/after the configured hour. Rate-limit aware: classifies
# limit failures, waits until the advertised reset (or a fixed backoff) and
# retries. Non-rate-limit failures get one generic retry and a macOS
# notification on final failure. Days with no transcripts are skipped without
# invoking Claude. .done is only written after output validation (step
# sentinels + apply-mode 03-applied.md). Bulky raw capture files are pruned
# after RETENTION_DAYS. Single-instance via a lock dir.
# No --dangerously-skip-permissions: uses acceptEdits + an explicit allowlist.
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
GENERIC_RETRY_MAX=1     # retries for non-rate-limit failures (rc!=0 or invalid output)
GENERIC_RETRY_WAIT_MIN=10
RETENTION_DAYS=30       # prune bulky raw capture files in day dirs older than this
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"

CLAUDE_BIN="$HOME/.local/bin/claude"
[ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$(command -v claude)"
[ -n "$CLAUDE_BIN" ] || { echo "[$(date '+%F %T')] ERROR: claude binary not found" >> "$LOG"; exit 1; }

mkdir -p "$RETRO_DIR"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

notify() {
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$1\" with title \"daily-retro\"" >/dev/null 2>&1
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "daily-retro" "$1" >/dev/null 2>&1
  fi
}

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

# Any transcript line for this date? (timestamps are ISO: "timestamp":"YYYY-MM-DD...)
# Avoids burning a full Claude invocation on session-less days.
has_sessions() {
  grep -rls --include='*.jsonl' "\"timestamp\":\"$1" "$CLAUDE_HOME/projects" 2>/dev/null \
    | grep -v 'claude-mem-observer-sessions' | head -1
}

# rc=0 from claude -p does not guarantee the retro ran to completion (it can
# stall on a prompt or die mid-step). Trust only the step sentinels.
retro_output_valid() {
  local day_dir="$RETRO_DIR/$1"
  grep -q 'step-complete' "$day_dir/01-events.md" 2>/dev/null || return 1
  grep -q 'step-complete' "$day_dir/02-council.md" 2>/dev/null || return 1
  if [ "$MODE" = "apply" ]; then
    grep -q 'step-complete' "$day_dir/03-applied.md" 2>/dev/null
  else
    grep -q 'step-complete' "$day_dir/03-proposals.md" 2>/dev/null
  fi
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

  if [ -z "$(has_sessions "$d")" ]; then
    mkdir -p "$day_dir"
    log "SKIP  retro $d — no sessions"
    echo "no sessions" > "$marker"
    return 0
  fi
  mkdir -p "$day_dir"

  local rl_attempt=0 generic_attempt=0 rc wait_s
  while :; do
    log "START retro $d (mode=$MODE rl_attempt=$rl_attempt generic_attempt=$generic_attempt)"
    invoke_claude "$d" "$run_log"
    rc=$?
    if [ "$rc" -eq 0 ] && retro_output_valid "$d"; then
      touch "$marker"
      log "DONE  retro $d"
      return 0
    fi
    if [ "$rc" -eq 0 ]; then
      log "INVALID retro $d — rc=0 but step sentinels missing"
      rc=99
    fi
    if is_rate_limited "$run_log" && [ "$rl_attempt" -lt "$RETRY_MAX" ]; then
      rl_attempt=$((rl_attempt + 1))
      wait_s="$(rate_limit_wait_secs "$run_log")"
      log "RATE-LIMITED retro $d (rc=$rc) — retry $rl_attempt/$RETRY_MAX in $((wait_s / 60))m"
      sleep "$wait_s"
      continue
    fi
    if ! is_rate_limited "$run_log" && [ "$generic_attempt" -lt "$GENERIC_RETRY_MAX" ]; then
      generic_attempt=$((generic_attempt + 1))
      log "RETRY retro $d (rc=$rc) — generic retry $generic_attempt/$GENERIC_RETRY_MAX in ${GENERIC_RETRY_WAIT_MIN}m"
      sleep $((GENERIC_RETRY_WAIT_MIN * 60))
      continue
    fi
    log "FAIL  retro $d (rc=$rc rl_attempts=$rl_attempt generic_attempts=$generic_attempt)"
    notify "Retro $d FAILED (rc=$rc) — see retro/$d/run.log"
    return "$rc"
  done
}

# Bulky raw capture files (raw-*.txt, user-msgs*.txt) are working scratch; the
# durable knowledge lives in 01/02/03 + registry. Prune past retention.
prune_old_raw() {
  find "$RETRO_DIR" -maxdepth 2 -type f \
    \( -name 'raw-*' -o -name 'user-msgs*' \) \
    -mtime +"$RETENTION_DAYS" -delete 2>/dev/null
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

prune_old_raw
