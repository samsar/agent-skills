# agent-skills

Personal [Agent Skills](https://agentskills.io): folders with a `SKILL.md` that Claude Code,
Codex, Cursor, Gemini CLI, Copilot and other skills-compatible agents load on demand.

| Skill | What it does |
|---|---|
| [`tla-plus`](skills/tla-plus/SKILL.md) | Model a concurrent or distributed design in TLA+/PlusCal and check it exhaustively with TLC, spec-first or from existing code. |
| [`lean4`](skills/lean4/SKILL.md) | Prove small, critical pure logic correct in Lean 4, then differential-test the production code against the proven model. |
| [`fuzzing`](skills/fuzzing/SKILL.md) | Coverage-guided fuzzing of code that handles untrusted input: harness, oracle, seeds, run, then triage, minimize and lock in each crash as a regression test. |

## Install

```bash
git clone git@github.com:samsar/agent-skills.git ~/projects/agent-skills
~/projects/agent-skills/install.sh
```

`install.sh` symlinks each folder in `skills/` into `~/.claude/skills/`. Claude Code and
Cursor both read that directory. For agents that read `~/.agents/skills/` (e.g. Codex):

```bash
SKILL_DIRS="$HOME/.claude/skills $HOME/.agents/skills" ./install.sh
```

The skills are symlinks, so `git pull` is enough to update them, and edits made by an agent
land directly in this repo.

## Adding a skill

1. Create `skills/<name>/SKILL.md`. The `name` must match the folder: lowercase letters,
   digits and hyphens.
2. Reference bundled files relative to the skill folder (`scripts/foo.sh`), not by absolute path.
3. Run `./install.sh`.
4. This repo is public, so check the skill for private details (employer, internal URLs, tokens)
   before pushing.
