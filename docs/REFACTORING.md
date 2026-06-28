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
- **Automated smoke/unit tests**: `./scripts/smoke-test.sh` runs a headless load
  check and Plenary specs from `tests/`.
- **Relation render indexing**: list rendering uses an in-memory relation index
  instead of scanning all cached memos for every rendered row.

---

## Remaining Refactoring Opportunities

### 1. `lua/memos/ui.lua` Module Size

`ui.lua` still owns list sessions, rendering, relation actions, buffer editing,
save/create dispatch, statusline state, and public command wrappers.

- **Risk**: changes in one UI area can accidentally affect unrelated behavior.
- **Suggested direction**: extract internal modules behind the existing
  `require("memos.ui")` public API. Good first boundaries are relation helpers,
  rendering helpers, and edit-buffer/save helpers.

### 2. Template Creation Request Count

Creating a new template currently creates a memo and then archives it.

- **Risk**: template creation requires sequential writes and cleanup if the
  archive step fails.
- **Suggested direction**: verify whether Memos `/api/v1/memos` create accepts
  an archived state. If it does, create archived templates in one request and
  update request-count docs and tests.

### 3. Repeated Memo PATCH Boilerplate

The API client has several memo update methods with the same PATCH structure.

- **Risk**: future field updates can drift in URL, JSON body, error handling, or
  callback shape.
- **Suggested direction**: share a private PATCH helper while preserving the
  existing public API methods and request payloads.

### 4. Relation Detail Fetch Fan-out

Expanding relation rows lazy-loads missing related memos one request per cache
miss.

- **Risk**: expanding a memo with many uncached relations can produce many
  concurrent requests.
- **Suggested direction**: keep the current lazy default, but consider a small
  concurrency queue or batch endpoint only after confirming server support and
  documenting request counts.
