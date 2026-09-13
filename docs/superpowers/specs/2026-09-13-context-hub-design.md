# Context hub

## Problem

Johannes works across multiple repos/projects (homelab-infra, the Coder
workspace, the future everything-app, and others) from Claude Code sessions
running in the persistent Coder workspace. There's currently no shared place
for cross-project standing context, architecture decisions, working notes,
or task tracking that Claude Code can reliably read at the start of every
session regardless of which repo the session started in — each repo today
only has its own local `CLAUDE.md` and its own `docs/superpowers/specs`
history, with nothing tying them together. Separately, an earlier planning
pass proposed reusing the existing self-hosted GitLab instance plus a
Markdown wiki (rendered via Starlight and GitLab Pages) as a lightweight
"history machine," instead of standing up a new PM/wiki tool.

## Goals

- One new GitLab project holding cross-project context: standing CLAUDE.md
  content, ADRs, notes, runbooks, journal entries, references, and
  unrefined ideas, organized per-project.
- Automatically loaded into every Claude Code session running in the Coder
  workspace, with zero agent action required — no MCP round-trip needed
  just to see standing context.
- Active task tracking stays in GitLab Issues in this same project,
  accessible to Claude Code via the GitLab MCP server (wired up as part of
  the separate Coder-workspace MCP subproject).
- A consistent file format/label vocabulary defined once, inside the repo
  itself, so conventions hold across sessions and across whichever project
  spawned the session.
- Human-readable rendering via GitLab Pages + Starlight, searchable, no new
  server process to operate.

## Non-goals

- Migrating homelab-infra's existing `docs/superpowers/specs/` and
  `docs/superpowers/plans/` history into this repo. Those stay where they
  are — repo-local specs for repo-local work. This repo is for context
  that spans projects, or context needed before a spec exists.
- Multi-user / access-control design. Single-operator homelab, same as
  Coder itself.
- Deprecating Backstage TechDocs. Worth revisiting separately once this
  repo is live and in use for a while; not decided here.
- Building the everything-app or finishing the Supabase rollout. Both are
  tracked here only as a `project:everything-app` folder / referenced
  context, not designed in this document.

## Design

### Repo

New self-hosted GitLab project, `homelab/projects/context-hub`, matching
the existing `homelab/projects/<name>` convention (`backstage`,
`coder-workspace`, `supabase-functions`). Standard branch `main`.

### Layout

Top-level folders per project, each with the same 6 fixed content-type
subfolders:

```
context-hub/
  CLAUDE.md
  homelab-infra/
    decisions/ notes/ runbooks/ journal/ references/ ideas/
  coder-workspace/
    decisions/ notes/ runbooks/ journal/ references/ ideas/
  everything-app/
    decisions/ notes/ runbooks/ journal/ references/ ideas/
  global/
    decisions/ notes/ runbooks/ journal/ references/ ideas/
```

New projects get a new top-level folder the first time they need one;
`global/` is for anything spanning more than one project.

### Content types and file conventions

All defined once in this repo's own top-level `CLAUDE.md`, so every
session — regardless of which project repo it started from — sees the
rules before writing anything.

| Folder | Purpose | Naming | Frontmatter |
|---|---|---|---|
| `decisions/` | ADRs | `NNNN-title.md`, numbered per project | `title`, `date`, `status` (proposed/accepted/superseded), `project` |
| `notes/` | Point-in-time findings/writeups worth keeping | `YYYY-MM-DD-title.md` | `title`, `date`, `project` |
| `runbooks/` | Step-by-step operational how-tos | `title.md`, kept updated in place | `title`, `project`, `updated` |
| `journal/` | Freeform dated worklog / session handoff notes | `YYYY-MM-DD.md`, one file per day per project, appended to | `date`, `project` |
| `references/` | Durable external pointers (chart versions, API quirks, vendor gotchas) | `title.md` | `title`, `project`, `updated` |
| `ideas/` | Unrefined backlog, pre-spec concepts | `title.md` | `title`, `project`, `status` (raw/refining/promoted) |

`status: promoted` on an idea means it graduated to a real spec elsewhere
(e.g. the everything-app's own spec) — the idea file stays as a historical
record, linking to where it landed.

### Labels and boards

Issue labels mirror the folder vocabulary exactly: `project:homelab-infra`,
`project:coder-workspace`, `project:everything-app`, `project:global`
(extended as new project folders appear), plus
`type:task`/`type:idea`/`type:question`. Multiple GitLab Issue Boards are
created against this one label set — e.g. one board grouped by `project:*`
(see everything by project), another grouped by `type:*` (see all open
questions across projects). GitLab supports any number of boards per
project, so this is additive, not an either/or choice.

### Commit conventions

Conventional Commits, scoped by project folder —
`docs(homelab-infra): add ADR-0004 coder MCP wiring`,
`docs(everything-app): journal 2026-09-20` — mirroring the style already
used in homelab-infra's own git log.

### Consumption in the Coder workspace

Cloned to a fixed path in the persistent workspace, e.g.
`~/Code/gitlab/context-hub`. Every other project repo's own `CLAUDE.md`
(homelab-infra's, the future everything-app's, etc.) gets a single import
line added:

```
@~/Code/gitlab/context-hub/CLAUDE.md
```

This loads automatically at the start of every Claude Code session in the
workspace — no MCP call, no agent action, and it keeps working even if the
GitLab MCP server or network is briefly unavailable. The exact clone step
(one-time manual `git clone` vs. an addition to the Coder agent's startup
script, matching the pattern already used to auto-clone `homelab-infra`) is
an implementation-time decision for the Coder MCP-wiring subproject, not
fixed here.

### Task tracking

GitLab Issues in this same `context-hub` project remain the active task
tracker — not replaced by any of the 6 markdown folders. Read/write access
for Claude Code goes through the GitLab MCP server, whose setup belongs to
the separate Coder-workspace-MCP-wiring subproject; this spec only fixes
the label vocabulary Issues use.

### Rendering

`.gitlab-ci.yml` `pages` job building a Starlight (Astro) site from the
repo's markdown on every push to `main`, per the original plan. Starlight's
sidebar auto-groups by folder, so the per-project/per-content-type layout
above produces a navigable wiki with no extra sidebar config needed.
Requires GitLab Pages enabled instance-wide (admin one-time config,
domain/DNS) — tracked as an open prerequisite, not new here.

## Testing

- New project created, `CLAUDE.md` + the 6-folder skeleton (at least under
  `global/`) committed and pushed.
- homelab-infra's own `CLAUDE.md` gets the `@import` line; a fresh Claude
  Code session in the Coder workspace confirms the imported content is
  visible (e.g. ask it to state a rule that only lives in context-hub's
  `CLAUDE.md`).
- Create one Issue with a `project:*` label, confirm it shows up on both a
  `project:*`-grouped board and a `type:*`-grouped board.
- Push to `main`, confirm the `pages` job builds and the resulting GitLab
  Pages site renders and is searchable.

## Rollout order

1. Enable GitLab Pages instance-wide (admin config, domain/DNS) — blocking
   prerequisite, not part of this repo's own work.
2. Create `homelab/projects/context-hub`, commit the folder skeleton +
   top-level `CLAUDE.md` (conventions, label vocabulary, templates).
3. `.gitlab-ci.yml` Starlight `pages` job; verify it builds and renders.
4. Add the `@import` line to homelab-infra's `CLAUDE.md`; verify a Coder
   workspace session picks it up (depends on the repo being cloned to a
   fixed path in the workspace — coordinate with the Coder MCP-wiring
   subproject for the actual clone mechanism).
5. Create the `project:*`/`type:*` labels and at least the two boards
   described above.
6. Backfill: as the everything-app and other subprojects gain their own
   folder, add it under the same 6-subfolder skeleton.
