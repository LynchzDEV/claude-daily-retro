#!/bin/bash
# stats.sh — read-only daily-retro status report (Feature #2).
# Assembles the picture you would otherwise hand-build from registry.json +
# IMPR-CHANGELOG.md + retro/<date>/ dirs. Writes nothing.
set -uo pipefail
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

python3 - "$CLAUDE_HOME" << 'PY'
import json, os, sys, re, glob
home = sys.argv[1]
reg_path = os.path.join(home, "skills/daily-retro/registry.json")
chg_path = os.path.join(home, "IMPR-CHANGELOG.md")
retro_dir = os.path.join(home, "retro")

def hr(t): print("\n== %s ==" % t)

# --- artifact inventory + escalation pressure ---
reg = {}
if os.path.isfile(reg_path):
    reg = json.load(open(reg_path))
arts = {k: v for k, v in reg.items() if isinstance(v, dict) and "type" in v}
by_type = {}
for v in arts.values():
    by_type[v["type"]] = by_type.get(v["type"], 0) + 1
hr("Artifacts (%d)" % len(arts))
for t in sorted(by_type):
    print("  %-12s %d" % (t, by_type[t]))

hr("Escalation pressure (recurrences — high = rule keeps failing)")
ranked = sorted(arts.items(), key=lambda kv: kv[1].get("recurrences", 0), reverse=True)
for k, v in ranked[:8]:
    r = v.get("recurrences", 0)
    flag = "  <-- HOOK-DUE (>=3)" if r >= 3 and v["type"] != "hook" else ""
    print("  %2d  %-40s %s%s" % (r, k[:40], v["type"], flag))

# --- deferred ---
deferred = reg.get("_deferred", {})
if isinstance(deferred, dict):
    hr("Deferred (%d)" % len(deferred))
    for k, v in deferred.items():
        state = "RESOLVED" if str(v).startswith("RESOLVED") else "open"
        print("  [%s] %s" % (state, k))

# --- run history ---
hr("Run history (last 10 dates)")
days = sorted(glob.glob(os.path.join(retro_dir, "20*")))[-10:]
for d in days:
    date = os.path.basename(d)
    done = os.path.isfile(os.path.join(d, ".done"))
    ev = "?"
    for src in (os.path.join(d, "03-applied.md"), os.path.join(d, "02-council.md")):
        if os.path.isfile(src):
            m = re.search(r"[Ee]vents[:* ]+(\d{1,3})\b", open(src, errors="ignore").read())
            if m: ev = m.group(1); break
    marker = open(os.path.join(d, ".done")).read().strip()[:20] if done else "(no .done)"
    print("  %s  events=%-4s %s" % (date, ev, marker))

# --- version ---
hr("Version")
if os.path.isfile(chg_path):
    m = re.search(r"^##\s*([\d.]+)", open(chg_path, errors="ignore").read(), re.M)
    print("  changelog head: %s" % (m.group(1) if m else "?"))
print()
PY
