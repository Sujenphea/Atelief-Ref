# 349 — The Last Two Shipped Docs Promoted

Docs only. No code changed.

`.change-log/347` promoted five shipped feature-todos into `.docs/` and listed
[024] and [026] as still-in-flight. Both have now landed, so they follow the same
route. **347's "Still in the backlog" section is superseded by this entry** — it
is left as written, because it was true when it was written.

| Was | Is | Shipped in |
|---|---|---|
| `feature-todo/024-keyboard-map-and-shortcuts-page.md` | `.docs/077-keyboard-map-plan.md` | `3b507fb` (K1/K2/K4), `0826991` (K3) |
| `feature-todo/026-item-detail-gaps.md` | `.docs/078-item-detail-gaps-plan.md` | `ef5201d` (I2), `16e9fca` (I1), `53d58bc` (I3) |

Both gained a **Status** block recording the commits, which open questions were
answered and how, and where the implementation settled something the plan did not
anticipate — [077]'s seventh `.sidebar` scope and the Home ⌫ hole, [078]'s
collection-stamped step gate and the `Menu` → `.popover` forced by the shared
destination list.

## References

Same treatment as 347, and the same reason: the two sequences overlap, so
promotion renumbers, and CLAUDE.md is explicit that renumbering silently breaks
cross-references.

- `[024]` → `[077]`, `[026]` → `[078]` across `.docs/072`–`076` (which cited them
  as relative links back into the backlog — now bare, since they are siblings),
  `feature-todo/011` and `feature-todo/023`, and `.change-log/337`, `344`, `346`,
  `348`.
- `.change-log/347` is **deliberately untouched**. It is the record of the earlier
  move; rewriting its backlog list would have made it describe a state that never
  existed.

## What remains in feature-todo

`008`, `011`, `012`, `013`, `014`, `016`, `017`, `018`, `019`, `020`, and:

- **[023] archive / second library** — parked by decision, never started. The one
  doc from this batch of nine that shipped nothing.

Every other issue raised in this round is now in `.docs/` with a Status block.

## Files changed

- `.docs/077-keyboard-map-plan.md`, `.docs/078-item-detail-gaps-plan.md` (moved,
  renumbered, stamped)
- `.docs/072`–`076`, `feature-todo/011`, `feature-todo/023` (references only)
- `.change-log/337`, `344`, `346`, `348` (references only)

## Migration notes

None — documentation only.
