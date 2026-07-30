## Commit Messages

Format: `[type]: [scope] - [message]` (max 80 chars)

- Types: `fix`, `feat`, `refactor`, `style`, `chore`
- Scope: component or section name (e.g. `navbar`, `webgl`, `styles`)
- Be precise, avoid filler words like "add", "and"
- Example: `feat: hero - parallax scroll effect`

## Documentation Workflow

- **Changes**: After completing changes, add a changelog entry to `.change-log/`
  - Format: `xxx-description.md`
  - Where xxx is the index number of the file.
  - Include summary, files changed, and migration notes
- **Design docs**: Long-form feature documentation lives in `.docs/` as a flat set
  - Format: `xxx-<feature>-<kind>.md` (e.g. `001-glass-overview.md`,
    `002-glass-research.md`, `003-glass-design.md`, `004-glass-plan.md`)
  - Where xxx is the index number of the file.
  - Kinds: `overview` (synthesis, decisions, index), `research`, `design` (spec),
    `plan` (implementation plan). A measured exercise may also produce
    `protocol` (how the measurement is run), `results` and `verification`.
  - One file per kind — merge related notes rather than scattering files
  - A doc may own a sibling `xxx-results/` directory for raw artifacts (traces,
    captures) that are too bulky to inline.
  - Indices are allocation-order, not a sort key, and are **never reused** — docs
    cross-reference each other by number in prose and in relative links, so
    renumbering an existing doc silently breaks them. Two docs currently share
    `039` and `059`; leave them, and take the next free number.


## Tooling
 Tooling/versions: You are building an app using Xcode 26 on macOS 26. Without this, Claude may give faulty guidance