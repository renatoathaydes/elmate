This project is spec-driven: the specs are maintained alongside the code and are the source of truth; the code can be both generated or hand-written, but must be and checked against them. Specs are never generated from code.

Read the specs before the code. Start at `goal-and-requirements.md` (the goal and scope), then the nearest `SPEC.md`.

A SPEC.md sits beside the code it describes and covers one genuine module. A module might mean a subfolder, but also many subfolders may belong to one module and share only one SPEC.md
A SPEC.md states intent: what a module is for, what it owns, what is it for, and why the non-obvious decisions were made.
If the work in the project results in a code change that is against what is described in SPEC.md, confirm it should be done, and if yes, make both the code change and update SPEC.md. Never diverge silently.
Every spec begins with a YAML header. id, type and title are required; the rest are used only where they carry real information:

---
id:   # a unique id, this is how other specs reference this one
type: # goal-and-requirements | architecture-design | module-design | submodule-design | task-spec
title: # full title
status: # draft | active | stale | done | deprecated
parent: # the id of the spec directly above it in scope
depends-on: # the ids of other SPEC.md files important to this one
tags: # tags describing the contents
---
