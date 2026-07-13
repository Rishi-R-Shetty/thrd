# Open Questions

Escalations from subagents awaiting orchestrator resolution. The orchestrator reads this at the start of every session, resolves each question, logs the resolution in `.claude/decisions.md`, updates the affected phase plan, and clears the entry.

Format:
```
Q{N} [T{taskID}]: {question}. Options I see: (a) …, (b) …. My weak preference: (a) because …
```

---

<!-- No open questions. Q1 [T11] resolved 2026-07-13 → D10 (Models/ canonical; option a). -->
