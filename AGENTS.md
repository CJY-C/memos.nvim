# Repository Guidelines

## Project Structure

- `plugin/memos.lua`: Neovim entrypoint for user commands such as `:Memos`, `:MemosCreate`, `:MemosTemplate`, and startup command wiring.
- `lua/memos/`: core Lua modules:
  - `init.lua`: setup, configuration loading, credential loading, and public API entrypoints.
  - `api.lua`: Memos `/api/v1` HTTP client using `plenary.job` and `curl`.
  - `ui.lua`: list buffers, edit/create buffers, stale cache rendering, buffer-local keymaps, pagination, and UI flows.
  - `template.lua`: template creation/editing helpers and `#type/template` handling.
  - `latency.lua`: helpers used by latency scripts.
- `docs/`: Vim help and project documentation, including `docs/memos.nvim.txt`, `docs/DEVELOPER.md`, `docs/FEATURES.md`, and performance notes.
- `tests/`: Plenary test specs.
- `scripts/`: smoke, latency, and cold-order test scripts.
- `README.md`: user-facing install, configuration, commands, keymaps, and usage examples.

## Architecture Rules

- This branch supports the latest Memos `/api/v1` API shape. Do not reintroduce older API compatibility unless the behavior, schema, request cost, tests, and docs are explicit.
- Keep the common paths request-light:
  - list view: one list request for the first page,
  - create memo: one create request,
  - update memo: one patch request,
  - pin/archive/delete/visibility/create-time changes: one write request plus only the documented background refresh when needed.
- Preserve the in-memory stale cache model. When cached rows exist, render them immediately and fetch fresh data in the background. Do not hardcode `force_refresh = true` on return paths such as returning from edit/create buffers.
- Keep list state caches separate for `NORMAL`, `ARCHIVED`, and `TEMPLATES`, including rows, page tokens, filters, and last refresh timestamps.
- Network callbacks can complete after the user changes buffers or list states. Capture request state, schedule UI work, and avoid redrawing the active view from stale callbacks.
- Relation fields from Memos may be plain strings or nested tables. Extract relation names defensively rather than comparing raw relation fields.
- For display alignment, use `vim.fn.strdisplaywidth(str)` so CJK and multibyte text align correctly. For Neovim highlight columns, keep using byte offsets such as `#str`.

## Development Style

- Language: Lua using Neovim API conventions.
- Prefer snake_case for Lua identifiers and config keys, for example `page_size` and `auto_save`.
- Match the existing style: concise functions, direct API calls, minimal abstraction, and helpers only where they reduce real duplication or risk.
- Keep public command names in PascalCase, for example `:MemosCreate`, and module paths lowercase, for example `memos.ui`.
- `plenary.job` callbacks run outside normal Neovim UI context. Always wrap Neovim API calls, `vim.fn.*`, `vim.cmd`, UI updates, and callback-driven buffer work in `vim.schedule()`.
- Inside scheduled callbacks, check buffer validity with `vim.api.nvim_buf_is_valid(buf)` before reading or writing buffer state.
- Avoid comparing raw stringified IDs when values can be nil. Do not rely on `tostring(memo.id)` because nil becomes `"nil"`. Use project helpers such as `match_memo_id_or_name(memo, val)` and `is_same_memo(memo1, memo2)`.
- Every `vim.ui.select(items, opts, on_choice)` call must include a descriptive `kind`, such as `memos_relation`, `memos_visibility`, `memos_delete`, or `memos_unlink`, so users can target prompt layouts.
- If adding custom Telescope pickers for non-file entries, set `previewer = false` to avoid file previewer lag or freezes on menu labels.

## Testing Guidelines

- Run the standard smoke and unit test flow with:
  - `./scripts/smoke-test.sh`
- The smoke script performs a headless load check and runs the Plenary specs under `tests/`.
- For focused tests, use the Plenary test harness against `tests/` from headless Neovim.
- When testing nested asynchronous UI functions or multi-level `vim.schedule()` paths, use `vim.wait(timeout, condition_fn)` inside Plenary specs so the event loop can drain before assertions.
- For user-facing behavior, manually verify list rendering, create, edit, save, delete, archive/restore, templates, relations, and pagination against a live Memos instance with `:Memos`, `:MemosCreate`, `:MemosTemplate`, and `:MemosSave`.
- Test config precedence when relevant: explicit `setup()` values, `env_file`, and `MEMOS_HOST`/`MEMOS_TOKEN`.
- For performance-sensitive changes, run the relevant latency scripts and document request-count changes:
  - `./scripts/latency-test.sh`
  - `./scripts/cold-order-by-test.sh`

## Documentation Maintenance

- After any code, command, keymap, config, schema, request-count, or UI behavior change, update all relevant docs.
- Keep `README.md` and files under `docs/` consistent with implementation behavior.
- Update `docs/memos.nvim.txt` when commands, keymaps, config fields, or user-visible workflows change.
- Update developer or performance docs when architecture, caching, async behavior, request counts, or testing practices change.

## Commit & Pull Request Guidelines

- After completing a specific task or checklist item, stage and commit the related changes before proceeding to the next task.
- Continue the repository's current commit style. Inspect recent history with `git log --oneline` before committing and match the dominant pattern.
- Prefer short, imperative Conventional Commit-style subjects used in this repo, such as `fix: disable previewer in custom telescope picker to avoid lag`, `feat: support multi-select memo relation linking via Telescope`, `docs: document keymap disabling options`, and `test: add unit test for pagination history backward paging`.
- Use an unprefixed short imperative subject only when recent adjacent commits for the same type of work use that style. Call out breaking changes explicitly.
- Pull requests should include purpose, user-facing impact, manual test steps, automated test results, and documentation updates when behavior changes.
