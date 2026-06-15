---
name: daily-retro
description: Use when running the end-of-day self-improvement pass (the scheduled retro job), when asked to retrospect on or review what happened across today's Claude sessions, when recurring corrections / friction / repeated instructions across sessions should be turned into new or improved skills and CLAUDE.md rules, or when invoked as /daily-retro [YYYY-MM-DD] [apply|propose]. Cross-project, all repos.
---

# daily-retro

Continuous-improvement loop. Three steps. Runs over ONE target date across ALL projects.

**Args:** `/daily-retro [DATE] [MODE]`
- `DATE` — `YYYY-MM-DD`. If absent, use today.
- `MODE` — `apply` (default) or `propose`.
  - `apply`  → Step 3 modifies global `~/.claude/CLAUDE.md`, bumps the changelog, writes the registry.
  - `propose` → Step 3 modifies NOTHING. It writes ranked recommendations to `03-proposals.md` for human review. Use this when you do not want unattended edits to your config.

**Scope**: global / cross-project. Do NOT limit to one repo.

Paths (absolute):
- Output dir:      `~/.claude/retro/<DATE>/`
- Global rules:    `~/.claude/CLAUDE.md`
- Changelog:       `~/.claude/IMPR-CHANGELOG.md`
- Dedup registry:  `~/.claude/skills/daily-retro/registry.json`
- Skills root:     `~/.claude/skills/`
- Project memory:  `~/.claude/projects/*/memory/`
- Raw transcripts: `~/.claude/projects/*/*.jsonl`

Create TodoWrite with the 3 steps before starting. Do them in order. Each step writes its file before the next begins.

**Resume contract (rate-limit / crash recovery):** every step file ends with the
sentinel line `<!-- step-complete -->`. Before running a step, check whether its
output file already exists for `<DATE>` AND ends with the sentinel — if so, SKIP
the step and reuse the file. If the file exists without the sentinel it is a
partial write from an interrupted run: redo that step (overwrite). This makes
retries after a rate-limit kill cheap — typically only the step that died re-runs.
Step 3's output file is `03-applied.md` (apply mode) or `03-proposals.md` (propose
mode). The scheduler wrapper validates ALL THREE sentinels before writing the
`.done` marker — a run that skips writing the step-3 file is treated as failed
and retried, so always write it, even when zero actions were taken.

---

## Step 1 — GATHER (no judgment, max detail, 1 list-item per scenario)

Goal: a flat, exhaustive, NON-judgmental list of everything that happened across every session of `<DATE>`. Pure observation. No "why", no fix, no rating. Each scenario = one list item.

Pull from all three sources, merge, dedup near-identical events. Sources are ordered by headless reliability — transcripts are the source of truth, so this works even if claude-mem is unavailable in the unattended run:

1. **Raw transcripts (backbone)** — find `~/.claude/projects/*/*.jsonl` whose lines are dated `<DATE>` (filter on the `timestamp` field of each JSONL line; the scheduled run is the next morning at earliest, so do not rely on mtime alone). EXCLUDE noise dirs like `*claude-mem-observer-sessions*`. Walk every project dir. Scan for, and capture VERBATIM where possible:
   - user interruptions / stop events — `[Request interrupted by user]`
   - corrections ("no", "nope", "I told you", "don't", "instead", "stop")
   - repeated instructions — count repeats
   - denied/rejected tool calls — `The user doesn't want to proceed with this tool use`
   - redo / rework loops
   - moments the user expressed friction, confusion, or approval
   - record which `PROJECT` (repo dir) each event came from
2. **Built-in memory** — `~/.claude/projects/*/memory/*.md` whose body/frontmatter references `<DATE>` (especially `type: feedback` and `type: decision`).
3. **claude-mem (optional enrichment)** — IF the claude-mem MCP tools are available this run, use `timeline` filtered to `<DATE>` then `get_observations([ids])` to add summarized framing. If unavailable, skip silently.

**Recurrence tagging (effectiveness loop):** before writing the file, read the
auto-maintained rules section of `~/.claude/CLAUDE.md` and `registry.json`. For
each event that an EXISTING auto-maintained rule should have prevented, tag it
`RECURS: <registry-key>`. Otherwise `RECURS: —`. A recurrence means the rule
failed as prose — Step 3 escalates it.

Write `~/.claude/retro/<DATE>/01-events.md`:

```
# Events — <DATE>

Source coverage: transcripts(<n> files) | memory(<n> files)

- [E01] WHAT: <what happened> | PROJECT: <repo> | CONTEXT: <what Claude was doing> | SIGNAL: <user stopped/corrected/repeated xN/approved/decided> | RECURS: <registry-key or —> | QUOTE: "<verbatim or —>"
- [E02] ...

<!-- step-complete -->
```

Rules: one scenario per line, stable id `E01..En`. Detailed but do NOT invent (missing field → `—`). No interpretation. Include positives too. End with the sentinel.

---

## Step 2 — COUNCIL (3 lenses, scrum retrospective)

Read `01-events.md`. Size the council to the day:

- **< 10 events** → NO subagents. Analyze all events yourself, applying the three lenses below in sequence. (Spawning agents for a quiet day wastes quota — the nightly run shares the user's rate limit.)
- **≥ 10 events** → **3 subagents in parallel** (Agent tool, `general-purpose`), one per lens; each lens processes ALL events through its single perspective; you then synthesize. Never more than 3 agents total.

1. **Historian** — confirm exactly what happened and the precise trigger.
2. **Root-cause** — why it happened; cross-event PATTERNS (shared root causes).
3. **Action-engineer** — how to respond next time, how to prevent, and the concrete artifact (SKILL / CLAUDE_RULE / HOOK / NONE), with IMPACT and FREQUENCY.

Synthesize the three lenses into `~/.claude/retro/<DATE>/02-council.md` — every event id × every answer:

```
# Council — <DATE>

## [E01] <short title>
- What:    <historian>
- Why:     <root-cause + class>
- Respond: <action-engineer>
- Prevent: <action-engineer>
- Action:  <SKILL:<name> | CLAUDE_RULE:<one-liner> | HOOK:<desc> | NONE>
- Impact:  <high|med|low>  Frequency: <count>

## Patterns
- P1 <name> — events: ...
## Ranked actions
- <deduped shortlist by Impact x Frequency, marking NEW vs IMPROVEMENT vs ESCALATION>

<!-- step-complete -->
```

---

## Step 3 — ACT (top 3, WITH dedup gate)

Read `01-events.md` + `02-council.md`. Rank by `Impact × Frequency`. Take **top 3** with a non-NONE Action.

### Dedup gate (mandatory — improve, never duplicate)
Before creating anything:
1. Read `registry.json` — created before?
2. `ls ~/.claude/skills/` + read candidate SKILL.md frontmatter — does a skill already cover this?
3. `grep ~/.claude/CLAUDE.md` — does a rule already cover this?
4. Search `~/.claude/projects/*/memory/` for an existing note.

**If a covering artifact EXISTS → IMPROVE it in place. Only if nothing covers it → CREATE new.**

### Escalation gate (recurrence → stronger artifact)
For every event tagged `RECURS: <key>`: increment that registry entry's
`recurrences` counter (add the field if missing). A rule that recurs has failed
as prose — do NOT just reword it. Escalate up the enforcement ladder:
CLAUDE_RULE (advisory) → sharpened rule with trigger phrases → HOOK (mechanical
block). 2+ recurrences = propose/create the hook this run.

### Deferred revisit (every run)
Read `_deferred` in `registry.json`. For each entry, re-check whether its
blocker still holds (e.g. "node runtime unavailable" — test `command -v node`;
"project-specific" — is there now a matching project skill to route into?).
Unblocked → treat it as a 4th action this run (it pre-paid its analysis).
Still blocked → leave, but refresh its note with today's date if anything changed.
Resolved/obsolete → mark it `RESOLVED <date> — <how>`.

**Existing-artifact health re-scan (every run):** run
`bash ~/.claude/skills/daily-retro/scan-artifacts.sh`. It re-checks every hook
script wired into `settings.json` for stray control bytes + syntax errors —
silent rot that the Liveness gate only catches at creation time (this is how a
live verify-gate.sh sat dead for a day). Any `FAIL` line → open a fix action
THIS run (strip the bad bytes / fix syntax, re-run until clean), note it in
`03-applied.md`. A failed re-scan blocks `03-applied.md` from claiming an
all-clean run.

### Conflict gate
If a proposed rule contradicts an existing hand-written user rule, DO NOT blind-write it. Either re-scope it so it refines rather than contradicts, or defer it (record under `_deferred`) and note the conflict.

### Liveness gate (executable artifacts MUST be smoke-tested — applies the verify-before-done rule to the retro itself)
ANY artifact this run CREATES or EDITS that is executable — a hook script, a
helper script, anything wired into `settings.json` — must PASS a smoke test in
this same run before it may be marked RESOLVED, recorded as created, or counted
toward the version bump. Reading the code is NOT a test (a verify-gate.sh once
shipped with stray `\x08` bytes mangling all three regexes — the whole hook was
a silent no-op, yet was marked RESOLVED unverified).

Procedure per executable artifact:
1. **Syntax check** — `bash -n <script>` for shell; for python, `ast.parse` the file.
2. **Control-byte scan** — reject any stray control byte (esp. `0x08` backspace, `0x1b` esc) outside `\t`/`\n`:
   `python3 -c "import sys;d=open(sys.argv[1],'rb').read();bad=[hex(b) for b in d if b<9 or (11<=b<32 and b!=27) or b==127];sys.exit('CONTROL BYTES: '+','.join(bad) if bad else 0)" <script>`
3. **Behavioral smoke test** — feed synthetic input for EACH branch and assert output:
   - POSITIVE/trigger path produces the expected effect (e.g. a warn-hook: feed input that should warn → assert the warning text appears),
   - NEGATIVE path stays silent (feed input that should NOT trigger → assert no output).
   A hook that can never reach its trigger branch is dead and FAILS this gate.
4. **Pass → record as created/RESOLVED + bump version. FAIL → leave in `_deferred`
   as `created-but-unverified: <reason>`, do NOT mark RESOLVED, do NOT bump for it,
   and state the failure in `03-applied.md`.**

Smoke-test commands + their output go into `03-applied.md` as proof — same standard the verify-gate hook enforces on UI work.

### Apply — BRANCH ON MODE
**If MODE = propose:** write the top 3 (with dedup/conflict findings and exact proposed diffs) to `~/.claude/retro/<DATE>/03-proposals.md`, ending with the sentinel. Make NO changes to CLAUDE.md, changelog, registry, or skills. Stop after writing it.

**If MODE = apply:**
- Skill-worthy & not covered → create `~/.claude/skills/<name>/SKILL.md` (follow writing-skills conventions). Covered → improve existing.
- **Hook-worthy (executable artifact — highest blast radius, runs every session):** governed by `HOOK_APPROVAL` in `config.env` (default `stage`):
  - `stage` → write the COMPLETE hook to `~/.claude/retro/pending/hooks/<name>` and add a `_deferred` entry `created-pending-confirm: <why>`. Do NOT wire it into `settings.json` and do NOT bump the version yet. `retro-pending.sh` surfaces it next interactive session; a human-present session smoke-tests it (Liveness gate), copies it into `~/.claude/hooks/`, wires `settings.json`, then deletes the staged copy and flips the registry entry to live + bumps the version. This keeps unattended runs from silently activating executable code in every session.
  - `auto` → create + wire into `settings.json` this run, but ONLY after it PASSES the Liveness gate in-run; on any gate failure fall back to `stage`.
- Rule-worthy → append/refine a rule in `~/.claude/CLAUDE.md` under a clearly demarcated `## Continuous-improvement rules (auto-maintained by daily-retro)` section. NEVER edit the user's hand-written rules; only add/maintain within that section. Cite the retro date + event ids in each rule.
- Record every change in `registry.json`:
  ```json
  { "<artifact-key>": { "type": "skill|claude_rule|hook", "name": "...",
    "created": "<DATE>", "updated": ["<DATE>"], "source_events": ["E0x"],
    "recurrences": 0, "summary": "..." } }
  ```
- Bump `~/.claude/IMPR-CHANGELOG.md` (semver): **minor** = new skill/hook created; **patch** = only improvements/rules.
- **Unwritable project target (sandbox):** when an action needs a file inside a
  project repo (hookify rule, project skill, repo doc) and the write fails with
  a permission error (macOS TCC blocks launchd from `~/Desktop` etc.), do NOT
  just defer it. Write the COMPLETE artifact to
  `~/.claude/retro/pending/<repo-name>/<relative-path-in-repo>` and record the
  pointer in the registry `_deferred` entry. A SessionStart hook surfaces
  pending artifacts in the next interactive session; that session installs them
  and deletes the staged copy.
- **LAST, always:** write `~/.claude/retro/<DATE>/03-applied.md` listing exactly
  what changed (rules added/escalated with their text, skills touched, registry
  keys, deferred revisits, version bump) and end with the sentinel. Write it
  ONLY after every change above is applied — the wrapper treats it as the
  apply-mode completion proof. Zero actions taken → still write it, stating so.

### Consolidation pass (growth control — apply mode only)
The auto-maintained section is loaded into EVERY session's context; it must not
grow unbounded. When it exceeds **10 rules**, consolidate in the same run:
merge rules sharing a root cause into one tighter rule (union of event ids),
compress wording, and retire rules with `recurrences: 0` that have not been
updated in 30+ days (move their text into the registry entry as
`retired: "<date> — <text>"`, delete from CLAUDE.md). Log every merge/retire in
the changelog. Net rule count must DECREASE in a consolidation run.

---

## Finish
Print a short summary: date, mode, #events, recurrences detected, top-3 actions (created vs improved vs escalated vs proposed), deferred items revisited, new version. The scheduler wrapper writes the `.done` marker only after exit code 0 AND validating the three step sentinels — do not write it yourself.
