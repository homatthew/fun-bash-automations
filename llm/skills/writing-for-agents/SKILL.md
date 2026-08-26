---
name: writing-for-agents
description: Use when creating, editing, or pruning AGENTS.md, CLAUDE.md, SKILL.md, or other instructions that agents consume.
---

# Writing for agents

Write the shortest instructions that reliably change behavior.

- Keep universal behavior in always-loaded files. Put branch-specific detail
  behind a pointer that says when to read it.
- Give each rule one source of truth. Do not copy facts the agent can cheaply
  read from code, configuration, or tool help.
- Keep one trigger for each real branch. Synonyms do not create new branches.
- Prefer positive target behavior. Keep prohibitions for real guardrails.
- Give workflows observable completion criteria.
- Remove stale branches, duplicated rules, and advice the model already follows
  without instruction.
- For every line, ask: does it change behavior, and is this its narrowest useful
  scope? Delete or move it when the answer is no.
