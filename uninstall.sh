#!/usr/bin/env bash
# Remove daily-retro scheduler + skill. Leaves your retro/ outputs and
# CLAUDE.md edits intact (remove those by hand if you want).
set -uo pipefail
CLAUDE_HOME="$HOME/.claude"
PLIST_DST="$HOME/Library/LaunchAgents/com.claude.daily-retro.plist"

if [ -f "$PLIST_DST" ]; then
  launchctl unload "$PLIST_DST" 2>/dev/null || true
  rm -f "$PLIST_DST"; echo "removed launchd job"
fi
if command -v crontab >/dev/null 2>&1; then
  crontab -l 2>/dev/null | grep -v "daily-retro/run.sh" | crontab - 2>/dev/null || true
  echo "removed any crontab entry"
fi
rm -rf "$CLAUDE_HOME/skills/daily-retro"; echo "removed skill"
echo "Kept: $CLAUDE_HOME/retro/ , $CLAUDE_HOME/IMPR-CHANGELOG.md , and any CLAUDE.md rules."
echo "To purge the auto-maintained CLAUDE.md section, delete it manually."
