# Repository Guidelines

## 1. Incremental Task Commits
- **Rule**: After completing a specific task/checklist item in the active plan, stage and commit the related changes *immediately* before proceeding to the next task.
- **Rationale**: Keeps git history incremental, clean, and easy to roll back if necessary.

## 2. Development Style & Architecture
- **Rule**: Implement core designs conforming to the plugin's architecture:
  - **In-memory Stale Cache**: Instantly render cached memos and fetch updates in the background. Avoid hardcoding `force_refresh = true` to preserve immediate rendering.
  - **Async Event Loops & Thread Safety**: Always wrap Neovim API calls and UI changes inside `vim.schedule()` when calling from callbacks or external job threads to avoid E5560 crashes.
  - **Defensive Buffer Operations**: Always check buffer validity with `vim.api.nvim_buf_is_valid(buf)` inside scheduled callbacks before reading or writing buffer lines.
  - **Safe ID Comparisons**: Never compare raw ID stringifications (like `tostring(memo.id)`) directly if they can be nil (which converts to `"nil"`). Use the helper functions `match_memo_id_or_name(memo, val)` and `is_same_memo(memo1, memo2)` to avoid false matches.
  - **UI Select Dialogs**: Always specify a descriptive `kind` option (e.g., `memos_relation`, `memos_visibility`, `memos_delete`, `memos_unlink`) in the options parameter of `vim.ui.select(items, opts, on_choice)` to allow size customization and dropdown targeting.

## 3. Testing Process & Guidelines
- **Rule**: Follow the established testing practices:
  - Run automated unit tests using the Plenary test runner via `./scripts/smoke-test.sh` or run the test directory harness directly.
  - When testing nested asynchronous UI functions (multi-level `vim.schedule`), use `vim.wait(timeout, condition_fn)` inside Plenary test blocks to wait for the event loop queue to finish.
  - Perform manual verification: Verify list rendering, create, edit, delete, and pagination flows against a live Memos instance using `:Memos`, `:MemosCreate`, and key mappings.

## 4. Documentation Maintenance
- **Rule**: After every change (code, structure, or interface configuration), evaluate and ensure that *all* relevant documentation (including `README.md` and any files under the `doc/` or `docs/` folders) is updated accordingly. Keep descriptions and actual configurations fully consistent to prevent any discrepancies.
