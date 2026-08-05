# 347 — Shipped Feature-Todos Promoted Into .docs

Docs only. No code changed.

Five feature-todo entries have shipped, so they move out of the backlog and into
the flat `.docs/` set as `plan` documents, each stamped with what actually landed.

| Was | Is | Shipped in |
|---|---|---|
| `feature-todo/021-local-install-lane.md` | `.docs/072-local-install-lane-plan.md` | `c891b50` |
| `feature-todo/022-two-tier-delete.md` | `.docs/073-two-tier-delete-plan.md` | `c08129d`, `ef5201d` |
| `feature-todo/025-sidebar-row-interaction.md` | `.docs/074-sidebar-row-interaction-plan.md` | `2b5560d` |
| `feature-todo/027-grid-destinations-and-carousel-scope.md` | `.docs/075-grid-destinations-carousel-plan.md` | `c08129d`, `16e9fca` |
| `feature-todo/028-spaces-tidy-wraps.md` | `.docs/076-spaces-tidy-wraps-plan.md` | `216aec2` |

Each gained a **Status** block under its title recording the commit, which open
questions were answered and how, and — where the implementation disagreed with
the plan — what it settled instead. Those blocks are the point of the move: a
promoted doc that still reads as a proposal is worse than one left in the
backlog.

## Renumbering, and why it was unavoidable

`.docs/` and `.docs/feature-todo/` are **two independent allocation sequences
that overlap**: `.docs/021-production-readiness-plan.md` and
`feature-todo/021-local-install-lane.md` both existed. Promotion therefore has to
renumber into the next free `.docs` indices (072–076), which is exactly the
operation CLAUDE.md warns silently breaks cross-references.

So every reference was rewritten rather than left to rot:

- `[021]` → `[072]`, `[022]` → `[073]`, `[025]` → `[074]`, `[027]` → `[075]`,
  `[028]` → `[076]` across the promoted docs, the three feature-todos that
  reference them ([023], [024], [026]), and `.change-log/337`–`344`.
- References to `.docs` siblings ([035], [038], [066], [069]) are left bare —
  they are same-directory now.
- References **back into** the backlog ([011], [024], [026]) are rewritten as
  relative links, following the convention already used at
  `feature-todo/020-capture-rednote.md:8`. A bare `[024]` inside a `.docs` file
  would otherwise read as `024-search-sort-plan.md`, which is a different
  document about a different thing.
- `.change-log` entries that named the old paths in their "Files changed"
  sections now name the new ones.

Untouched: `.change-log/082`, `083`, `.docs/009` and `.docs/020` also contain
`[021]`–`[028]` references, but those mean the **original** `.docs` documents of
those numbers and were correct before and after.

## Still in the backlog

- **[023] archive / second library** — parked by decision, not started.
- **[024] keyboard map** — K1, K2, K4 shipped (`3b507fb`); K3 (the `M` / `A`
  bindings) is outstanding, so the doc stays.
- **[026] item detail** — I1 and I2 shipped; I3 (step-instead-of-dismiss) is in
  flight, I4 is optional.

Both [024] and [026] should be promoted the same way once their remaining phases
land.

## Files changed

- `.docs/072-*` … `.docs/076-*` (moved from `feature-todo/`, renumbered, stamped)
- `.docs/feature-todo/023`, `024`, `026` (references only)
- `.change-log/337`–`342`, `344` (references and paths only)

## Migration notes

None — documentation only. Anything holding a link to a `feature-todo/021`,
`022`, `025`, `027` or `028` path will need updating; nothing in the build or the
app reads these files.
