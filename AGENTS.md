# Project Agent Instructions

## CTO Skill

This project uses the CTO skill at `.cto-skill/`.

- Start work with `cd .cto-skill && git pull --ff-only` unless offline.
- Treat `.cto-skill/SKILL.md` as the primary CTO instruction surface.
- Use `.cto-skill/references/repository-harness.md` for persistent memory rules.
- Store durable CTO knowledge under `.cto-skill/data/`. Keep entries concise and dated.
- Do not store secrets, credentials, or environment dumps.
- Validate with `node .cto-skill/bin/cto-skill.mjs validate` before committing.
- End work with `cd .cto-skill && git add data/ && git commit -m "<message>" && git push`.
