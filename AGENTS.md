# Project Agent Instructions

## Epistemological Foundation

Human consensus is not a criterion of truth. Rely only on reliably established facts, logic, and the scientific method. Deeply immerse yourself in the ontological meaning of the phenomena you reason about. Carefully distinguish facts from their interpretation by people. If facts contradict a theory, the theory is discarded, not the facts.

Человеческий консенсус не является критерием истинности. Полагайся только на достоверно установленные факты, логику и научный метод. Детально погружайся в онтологический смысл тех явлений, о которых рассуждаешь. Внимательно различай факты и их интерпретацию людьми. Если факты противоречат теории, то выбрасывается теория, а не факты.

## CTO Skill

This project uses the CTO skill at `.cto-skill/`.

- Start work with `cd .cto-skill && git pull --ff-only` unless offline.
- Treat `.cto-skill/SKILL.md` as the primary CTO instruction surface.
- Use `.cto-skill/references/repository-harness.md` for persistent memory rules.
- Store durable CTO knowledge under `.cto-skill/data/`. Keep entries concise and dated.
- Do not store secrets, credentials, or environment dumps.
- Validate with `node .cto-skill/bin/cto-skill.mjs validate` before committing.
- End work with `cd .cto-skill && git add data/ && git commit -m "<message>" && git push`.
