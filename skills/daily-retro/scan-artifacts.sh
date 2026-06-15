#!/bin/bash
# scan-artifacts.sh — health re-scan of EXISTING hook scripts (Feature #1).
# Catches silent rot of already-shipped artifacts (e.g. a stray 0x08 byte that
# turns a hook into a no-op). Deterministic checks only: syntax + control-byte
# scan. Behavioral smoke tests stay per-artifact in SKILL.md's Liveness gate.
#
# Scans every local script wired into settings.json hooks.* — the real set of
# active hooks — not the registry (which does not store reliable file paths).
#
# Exit 0 = all clean (or nothing to scan). Exit 1 = at least one FAIL.
# Portable to bash 3.2 (macOS) — no mapfile.
set -uo pipefail

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SETTINGS="$CLAUDE_HOME/settings.json"
[ -f "$SETTINGS" ] || { echo "no settings.json at $SETTINGS"; exit 0; }

FILES=()
while IFS= read -r line; do
  [ -n "$line" ] && FILES+=("$line")
done < <(python3 - "$SETTINGS" "$CLAUDE_HOME" << 'PY'
import json, sys, os, shlex
settings, home = sys.argv[1], sys.argv[2]
try:
    cfg = json.load(open(settings)).get("hooks", {})
except Exception as e:
    print(f"__ERR__ cannot parse settings.json: {e}"); sys.exit(0)
seen = set()
for event, groups in cfg.items():
    for g in groups or []:
        for h in g.get("hooks", []) or []:
            cmd = h.get("command", "")
            if not cmd: continue
            for tok in shlex.split(cmd, posix=True):
                p = os.path.expanduser(tok.replace("$HOME", os.path.expanduser("~")))
                if os.path.isfile(p) and p.startswith(home) and p not in seen:
                    seen.add(p); print(p); break
PY
)

[ "${#FILES[@]}" -eq 0 ] && { echo "no local hook scripts to scan"; exit 0; }

fails=0
for f in "${FILES[@]}"; do
  case "$f" in __ERR__*) echo "FAIL settings.json: ${f#__ERR__ }"; fails=$((fails+1)); continue;; esac

  bad=$(python3 -c "
import sys
d=open(sys.argv[1],'rb').read()
print(','.join(hex(b) for b in set(d) if b<9 or (11<=b<32 and b!=27) or b==127))
" "$f")
  if [ -n "$bad" ]; then
    echo "FAIL $f: stray control bytes $bad"; fails=$((fails+1)); continue
  fi

  case "$f" in
    *.py)  err=$(python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$f" 2>&1) ;;
    *)     err=$(bash -n "$f" 2>&1) ;;
  esac
  if [ -n "$err" ]; then
    echo "FAIL $f: syntax — ${err##*: }"; fails=$((fails+1)); continue
  fi

  echo "PASS $f"
done

[ "$fails" -gt 0 ] && { echo "SCAN: $fails artifact(s) FAILED"; exit 1; }
echo "SCAN: all clean"; exit 0
