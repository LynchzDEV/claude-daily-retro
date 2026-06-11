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
if [ -f "$CLAUDE_HOME/settings.json" ] && command -v python3 >/dev/null 2>&1; then
  cp "$CLAUDE_HOME/settings.json" "$CLAUDE_HOME/settings.json.bak-daily-retro-uninstall"
  python3 - "$CLAUDE_HOME/settings.json" "$CLAUDE_HOME/hooks/retro-pending.sh" <<'PY'
import json, sys
p, cmd = sys.argv[1], sys.argv[2]
s = json.load(open(p))
groups = s.get('hooks', {}).get('SessionStart', [])
kept = [g for g in groups if not any(h.get('command') == cmd for h in g.get('hooks', []))]
if len(kept) != len(groups):
    s['hooks']['SessionStart'] = kept
    json.dump(s, open(p, 'w'), indent=2)
    print('removed SessionStart surfacing hook from settings.json')
PY
fi
rm -f "$CLAUDE_HOME/hooks/retro-pending.sh"; echo "removed retro-pending.sh"
echo "Kept: $CLAUDE_HOME/retro/ , $CLAUDE_HOME/IMPR-CHANGELOG.md , and any CLAUDE.md rules."
echo "To purge the auto-maintained CLAUDE.md section, delete it manually."
