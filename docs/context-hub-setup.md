# Context Hub Setup

One-time setup for the context-hub GitLab project. All GitLab-UI steps
(project creation, CI variable, labels, boards) were done upfront as this
plan's Prerequisites, before Tasks 1-4 ran — nothing manual is left except
the verification below.

---

## What's live

- GitLab Pages enabled instance-wide (Task 1): `*.pages.homelab.local`.
- `homelab/projects/context-hub`: the 6-subfolder-per-project skeleton +
  conventions (`CLAUDE.md`), a Starlight site, built by CI on every push
  to `main` (Tasks 2-3).
- homelab-infra's own `CLAUDE.md` imports context-hub's (Task 4).

**Security note:** unlike every other service on this instance (behind Keycloak
OIDC), GitLab Pages has `gitlab_pages['access_control']` unset (defaults to
`false`), so anything published here is readable by anyone on the Tailnet
without login — nothing genuinely sensitive (credentials, tokens, etc.)
should go in context-hub.

## Verification

- [ ] `https://homelab.pages.homelab.local/projects/context-hub/` renders and is searchable
      (Starlight's built-in Pagefind search box returns results for a word
      from the `global` section).
- [ ] Both boards created in Prerequisites step 4 show up under
      **Issues → Boards**, switchable via the board-picker dropdown.
- [ ] Create one test Issue with both a `project:*` and a `type:*` label;
      confirm it appears on both boards simultaneously.
- [ ] Full `@import` verification from inside the Coder workspace is
      covered by the separate Coder-MCP-wiring plan, once that plan's
      startup-script clone step is live.
