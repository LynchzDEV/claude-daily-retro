# claude-daily-retro

A nightly **continuous-improvement retrospective** for [Claude Code](https://claude.com/claude-code).

Every evening it reviews *everything that happened across all of that day's Claude
sessions* — every correction, interruption, repeated instruction, rework loop, and
win — then runs a 3-lens "council" over each one (like a scrum retro) and turns the
top findings into **new/improved skills and `CLAUDE.md` rules** — with a dedup gate so
it improves what already exists instead of piling up duplicates.

It's the loop that makes your Claude setup get better while you sleep.

---

## What it does (3 steps)

1. **Gather** — reads your local session transcripts (`~/.claude/projects/*/*.jsonl`)
   + built-in memory across *all* projects for the target day, and writes a flat,
   non-judgmental list of everything that happened → `~/.claude/retro/<date>/01-events.md`.
2. **Council** — 3 parallel sub-agent lenses (Historian / Root-cause / Action-engineer)
   analyze every event: what / why / how to respond / how to prevent / what to build →
   `02-council.md`.
3. **Act** — ranks the top 3, runs a **dedup gate** (improve existing, never duplicate),
   and either:
   - **apply mode** → auto-edits global `~/.claude/CLAUDE.md` (in a demarcated
     auto-section it never lets itself overwrite your hand-written rules), bumps
     `~/.claude/IMPR-CHANGELOG.md`, updates a registry; or
   - **propose mode** → writes recommendations to `03-proposals.md` and changes nothing.

Runs unattended via a scheduler (macOS launchd / Linux cron) at a time you pick, with a
**7-day catch-up** so a powered-off evening isn't lost.

> No `--dangerously-skip-permissions`. It runs headless with `--permission-mode acceptEdits`
> and an explicit tool allowlist.

---

## Install

### Option A — the wizard (skill **and** scheduler, recommended)

```bash
git clone https://github.com/LynchzDEV/claude-daily-retro.git
cd claude-daily-retro
./install.sh
```

The wizard asks you to choose: **apply vs propose** mode, run time, catch-up depth,
whether to seed history skip-markers, and the scheduler backend. Re-run it any time to
change settings. Uninstall with `./uninstall.sh`.

### Option B — Claude Code plugin (skill only, cross-platform)

```
/plugin marketplace add LynchzDEV/claude-daily-retro
/plugin install daily-retro@lynchzdev
```

Gives you the `/daily-retro` skill. Run it manually (`/daily-retro 2026-01-31 propose`)
or wire your own scheduler. No OS job is installed this way (plugins can't register cron).

---

## Usage

```
/daily-retro                      # today, apply mode (or your config default)
/daily-retro 2026-01-31           # a specific day
/daily-retro 2026-01-31 propose   # review-only, edits nothing
```

Outputs land in `~/.claude/retro/<date>/`.

---

## Modes

| Mode | What Step 3 does |
|------|------------------|
| `propose` (safe default in wizard) | Writes `03-proposals.md` with ranked, deduped recommendations + proposed diffs. **Edits nothing.** |
| `apply` | Auto-creates/improves skills, edits the auto-section of `~/.claude/CLAUDE.md`, bumps the changelog + registry. |

Start with `propose`, read a few nights of output, then switch to `apply` if you trust it.

---

## ⚠️ Before you trust apply mode

- It **edits your global `~/.claude/CLAUDE.md`** — affecting every project. It only writes
  inside a `## Continuous-improvement rules (auto-maintained by daily-retro)` section and
  never edits your hand-written rules, but review the diffs.
- It runs Claude **headless with file-write permission** on a schedule. Read `install.sh`
  and `skills/daily-retro/SKILL.md` first.
- It reads your **session transcripts** locally. Nothing is sent anywhere beyond your normal
  Claude Code usage.
- Token cost: a full nightly run spawns several sub-agents. `propose` and `apply` cost the same.

---

## Linux: systemd timer (alternative to cron)

```ini
# ~/.config/systemd/user/daily-retro.service
[Service]
Type=oneshot
ExecStart=%h/.claude/skills/daily-retro/run.sh

# ~/.config/systemd/user/daily-retro.timer
[Timer]
OnCalendar=*-*-* 18:00:00
Persistent=true     # back-fills missed runs after boot
[Install]
WantedBy=timers.target
```
```bash
systemctl --user enable --now daily-retro.timer
```

---

## Files it manages

```
~/.claude/skills/daily-retro/SKILL.md        the 3-step skill
~/.claude/skills/daily-retro/run.sh          scheduler wrapper (catch-up)
~/.claude/skills/daily-retro/config.env      your wizard choices
~/.claude/skills/daily-retro/registry.json   dedup manifest
~/.claude/retro/<date>/                       per-day outputs
~/.claude/IMPR-CHANGELOG.md                   versioned action log
~/Library/LaunchAgents/com.claude.daily-retro.plist   (macOS)
```

## License

MIT © LynchzDEV
