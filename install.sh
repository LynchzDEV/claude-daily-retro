#!/usr/bin/env bash
# daily-retro install wizard.
# Interactive: lets you choose mode, schedule time, catch-up depth, history
# seeding, model pin, and scheduler backend. Re-runnable (idempotent).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="$HOME/.claude"
SKILL_SRC="$SELF_DIR/skills/daily-retro"
SKILL_DST="$CLAUDE_HOME/skills/daily-retro"
RETRO_DIR="$CLAUDE_HOME/retro"
PLIST_DST="$HOME/Library/LaunchAgents/com.claude.daily-retro.plist"

c_b="\033[1m"; c_y="\033[33m"; c_g="\033[32m"; c_r="\033[31m"; c_0="\033[0m"
say()  { printf "%b\n" "$*"; }
ask()  { local p="$1" d="$2" a; read -r -p "$(printf "%b" "$p [$d]: ")" a; printf '%s' "${a:-$d}"; }
yn()   { local p="$1" d="$2" a; read -r -p "$(printf "%b" "$p [$d]: ")" a; a="${a:-$d}"; case "$a" in [Yy]*) return 0;; *) return 1;; esac; }

say "${c_b}== daily-retro install wizard ==${c_0}"
say "Nightly continuous-improvement retrospective for Claude Code."
say ""

# --- preflight ---
CLAUDE_BIN="$HOME/.local/bin/claude"; [ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  say "${c_r}claude CLI not found on PATH or ~/.local/bin. Install Claude Code first.${c_0}"; exit 1
fi
say "Found claude: ${c_g}$CLAUDE_BIN${c_0}"
OS="$(uname -s)"
say "OS: ${c_g}$OS${c_0}"

# node is needed by Claude Code hooks (SessionEnd etc.) inside the headless run.
NODE_BIN="$(command -v node || true)"
if [ -n "$NODE_BIN" ]; then
  say "Found node:   ${c_g}$NODE_BIN${c_0} (hooks will work in headless runs)"
else
  say "${c_y}node not found on PATH — Claude Code hooks will fail inside scheduled runs.${c_0}"
fi
say ""

# --- what it does / consent ---
say "${c_y}This tool reads your local session transcripts and can EDIT your global"
say "~/.claude/CLAUDE.md automatically (in 'apply' mode). It runs Claude headless"
say "with file-write permissions on a schedule. Review the README before continuing.${c_0}"
yn "Continue?" "Y" || { say "Aborted."; exit 0; }
say ""

# --- skill copy ---
if yn "Copy the daily-retro skill into ~/.claude/skills?" "Y"; then
  mkdir -p "$SKILL_DST"
  cp "$SKILL_SRC/SKILL.md" "$SKILL_DST/SKILL.md"
  cp "$SKILL_SRC/run.sh"   "$SKILL_DST/run.sh"
  chmod +x "$SKILL_DST/run.sh"
  say "  skill installed -> $SKILL_DST"
else
  say "  skipped skill copy (using plugin-installed skill). Scheduler still uses $SKILL_DST/run.sh — ensure it exists."
  mkdir -p "$SKILL_DST"; cp "$SKILL_SRC/run.sh" "$SKILL_DST/run.sh"; chmod +x "$SKILL_DST/run.sh"
fi
say ""

# --- mode ---
say "${c_b}Mode${c_0}"
say "  propose = SAFE. Writes recommendations to retro/<date>/03-proposals.md. Edits nothing."
say "  apply   = autonomous. Auto-edits ~/.claude/CLAUDE.md + changelog with a dedup gate."
if yn "Use autonomous 'apply' mode? (No = safe 'propose' mode)" "N"; then MODE="apply"; else MODE="propose"; fi
say "  -> mode = ${c_g}$MODE${c_0}"
say ""

# --- schedule ---
RUN_HOUR="$(ask "Run hour (0-23)" "18")"
RUN_MIN="$(ask "Run minute (0-59)" "0")"
CATCHUP_DAYS="$(ask "Catch-up days (back-fill missed runs)" "7")"
say ""

# --- model pin ---
say "${c_b}Model${c_0}"
say "  The retro shares your account rate limit. Pinning a cheaper model (e.g."
say "  'sonnet' or 'haiku') spares your premium quota at the cost of some analysis depth."
RETRO_MODEL="$(ask "Model for retro runs (empty = account default)" "")"
say ""

# --- config.env ---
ALLOWED="Read,Write,Edit,Bash,Grep,Glob,Skill,Agent,Task"
cat > "$SKILL_DST/config.env" <<CFG
MODE="$MODE"
CATCHUP_DAYS=$CATCHUP_DAYS
RUN_HOUR=$RUN_HOUR
ALLOWED="$ALLOWED"
RETRO_MODEL="$RETRO_MODEL"
RETRY_MAX=3
RETRY_FALLBACK_MIN=60
RETRY_CAP_MIN=300
CFG
say "Wrote $SKILL_DST/config.env"

# --- bootstrap files ---
mkdir -p "$RETRO_DIR"
[ -f "$SKILL_DST/registry.json" ] || echo '{}' > "$SKILL_DST/registry.json"
if [ ! -f "$CLAUDE_HOME/IMPR-CHANGELOG.md" ]; then
  cat > "$CLAUDE_HOME/IMPR-CHANGELOG.md" <<CHL
# IMPR-CHANGELOG

Continuous-improvement log. Maintained by the daily-retro skill.
Semver: minor = new skill/hook; patch = existing artifact / CLAUDE.md rule improved.

## 0.1.0 — installed
- daily-retro installed via wizard.
CHL
  say "Initialized ~/.claude/IMPR-CHANGELOG.md"
fi

# --- seed history markers ---
days_ago() { if date -v-1d +%F >/dev/null 2>&1; then date -v-"$1"d +%F; else date -d "$1 days ago" +%F; fi; }
if yn "Seed skip-markers for the past $CATCHUP_DAYS days (so first run does NOT reprocess history)?" "Y"; then
  for ((i=CATCHUP_DAYS; i>=1; i--)); do d="$(days_ago "$i")"; mkdir -p "$RETRO_DIR/$d"; touch "$RETRO_DIR/$d/.done"; done
  say "  seeded $CATCHUP_DAYS markers."
fi
say ""

# --- scheduler ---
say "${c_b}Scheduler${c_0}"
case "$OS" in
  Darwin)
    if yn "Install macOS launchd job at ${RUN_HOUR}:${RUN_MIN} daily?" "Y"; then
      BIN_DIR="$(dirname "$CLAUDE_BIN")"
      PATHV="$BIN_DIR:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      # Hooks inside the headless run need node; launchd jobs don't inherit your
      # shell PATH, so bake the node dir (and mise shims, if any) into the plist.
      [ -n "$NODE_BIN" ] && PATHV="$(dirname "$NODE_BIN"):$PATHV"
      [ -d "$HOME/.local/share/mise/shims" ] && PATHV="$HOME/.local/share/mise/shims:$PATHV"
      mkdir -p "$(dirname "$PLIST_DST")"
      sed -e "s|__HOME__|$HOME|g" -e "s|__HOUR__|$RUN_HOUR|g" -e "s|__MINUTE__|$RUN_MIN|g" -e "s|__PATH__|$PATHV|g" \
        "$SELF_DIR/templates/com.claude.daily-retro.plist.template" > "$PLIST_DST"
      launchctl unload "$PLIST_DST" 2>/dev/null || true
      launchctl load "$PLIST_DST" && say "  launchd job loaded: $PLIST_DST"
      say "  (RunAtLoad fired; with markers seeded it does nothing now.)"
    fi
    ;;
  Linux)
    say "  Linux detected. Options: cron or systemd timer."
    if yn "Add a crontab entry at ${RUN_HOUR}:${RUN_MIN} daily?" "Y"; then
      LINE="$RUN_MIN $RUN_HOUR * * * $SKILL_DST/run.sh"
      ( crontab -l 2>/dev/null | grep -v "daily-retro/run.sh"; echo "$LINE" ) | crontab -
      say "  crontab updated: $LINE"
      say "  NOTE: cron does not back-fill while powered off; run.sh catch-up handles boots."
    else
      say "  Skipped. systemd timer example is in the README."
    fi
    ;;
  *)
    say "  Unsupported OS for auto-scheduling. Run manually or wire your own scheduler:"
    say "    $SKILL_DST/run.sh"
    ;;
esac

say ""
say "${c_g}Done.${c_0}"
say "Test now:  ${c_b}claude -p \"/daily-retro \$(date +%F) propose\"${c_0}"
say "Logs:      $RETRO_DIR/launchd.log   Outputs: $RETRO_DIR/<date>/"
say "Uninstall: $SELF_DIR/uninstall.sh"
