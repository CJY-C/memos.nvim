# Refactoring Notes

This document tracks remaining structural work for `memos.nvim`. Items that
were completed during the latest core refactor are listed separately so future
changes do not reopen solved problems.

---

## Completed Refactors

- **List session encapsulation**: list state is held in `ListSession` instances,
  with per-state caches for `NORMAL`, `ARCHIVED`, and `TEMPLATES`.
- **Constructor-based API client**: `lua/memos/api.lua` exposes `api.new(...)`
  and supports static config tables or dynamic config getters.
- **Pure Lua split editing**: normal split and vsplit editing use Neovim Lua
  window APIs instead of `vim.cmd("split")` / `vim.cmd("vsplit")`.
- **Dynamic list keymaps**: list buffer mappings are rebound from current config
  and support disabling mappings with `false`.
- **List keymap extraction**: list keymap binding, dynamic rebinding cleanup,
  fallback keys, and disabled-key handling live in `lua/memos/ui/keymaps.lua`.
- **Automated smoke/unit tests**: `./scripts/smoke-test.sh` runs a headless load
  check and Plenary specs from `tests/`.
- **Relation render indexing**: list rendering uses an in-memory relation index
  instead of scanning all cached memos for every rendered row.
- **Edit buffer/save extraction**: edit-buffer opening, setup, auto-save, save
  dispatch, and return-to-list behavior live in `lua/memos/ui/buffers.lua`
  behind the existing `require("memos.ui")` public wrappers.
- **List rendering extraction**: list line composition, item metadata,
  highlights, relation loading rows, and missing relation detection live in
  `lua/memos/ui/render.lua`.
- **Render application extraction**: rendered list lines, item metadata,
  highlights, and missing relation fetch triggers are applied to Neovim buffers
  by `lua/memos/ui/render_apply.lua`.
- **Relation action extraction**: add, multi-add, selection, and unlink
  workflows live in `lua/memos/ui/relation_actions.lua`.
- **Relation expansion extraction**: outgoing/incoming expansion, collapse-all
  behavior, and lazy missing-relation detail fetching live in
  `lua/memos/ui/relation_expand.lua`.
- **Selected item extraction**: current-row item lookup, memo resolution, edit
  dispatch, copy ID, and selected cache removal live in
  `lua/memos/ui/selection.lua`.
- **Memo action extraction**: pin, archive/restore, delete, visibility, and
  create-time workflows live in `lua/memos/ui/memo_actions.lua`.
- **List flow extraction**: list fetch, search, pagination, state cache
  switching, and stale-cache callback handling live in
  `lua/memos/ui/list_flow.lua`.
- **List window extraction**: list buffer creation, float window management,
  list focusing, toggling, quitting, and template-list switching live in
  `lua/memos/ui/list_window.lua`.
- **Status helper extraction**: refresh-state coordination, public statusline
  text, and list header status text live in `lua/memos/ui/status.lua`.
- **Search filter extraction**: plain text, tag, and raw CEL search-filter
  building lives in `lua/memos/ui/search.lua` behind the existing
  `require("memos.ui").build_search_filter(...)` wrapper.
- **Template create request count**: new templates are created, then archived
  with a follow-up PATCH because the Memos create API does not accept archive
  state in the create payload.
- **Shared memo PATCH helper**: memo field updates use `Client:patch_memo(...)`
  to preserve consistent PATCH URLs, bodies, masks, and callback handling.

---

## Remaining Refactoring Opportunities

### 1. `lua/memos/ui.lua` Module Size

`ui.lua` still owns list sessions, context construction, and public command
wrappers.

- **Risk**: changes in one UI area can accidentally affect unrelated behavior.
- **Suggested direction**: extract internal modules behind the existing
  `require("memos.ui")` public API. The next practical boundary is command
  coordination around templates and list-session public wrappers.

### 2. Relation Detail Fetch Fan-out

Expanding relation rows lazy-loads missing related memos one request per cache
miss.

- **Risk**: expanding a memo with many uncached relations can produce many
  concurrent requests.
- **Suggested direction**: keep the current lazy default, but consider a small
  concurrency queue or batch endpoint only after confirming server support and
  documenting request counts.
