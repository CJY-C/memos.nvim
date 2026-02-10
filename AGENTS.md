# Repository Guidelines

## Project Structure & Module Organization

- `plugin/memos.lua`: Neovim entrypoint that defines `:Memos` and `:MemosCreate` commands and startup keymap wiring.
- `lua/memos/`: core Lua modules:
  - `init.lua` for setup/config loading and public API.
  - `api.lua` for HTTP calls to the Memos server.
  - `ui.lua` for list/create/edit buffer behavior and key handling.
- `doc/memos.nvim.txt`: Vim help documentation.
- `README.md`: user-facing install, config, and usage examples.

## Build, Test, and Development Commands

- No build step is required; this is a pure Lua Neovim plugin.
- Quick smoke test:
  - `./scripts/smoke-test.sh`
  - Runs a headless load check and prints the manual commands to verify behavior.
- Manual functional test (recommended):
  1. Add this repo to your Neovim runtime/plugins.
  2. Run `:Memos`, `:MemosCreate`, and `:MemosSave`.
  3. Confirm list, create, edit, delete, and pagination behavior against a live Memos instance.

## Coding Style & Naming Conventions

- Language: Lua (Neovim API style).
- Prefer snake_case for config keys and Lua identifiers (for example, `page_size`, `auto_save`).
- Match existing file style: concise functions, direct API calls, minimal abstraction.
- Keep user-visible command names in PascalCase (`:MemosCreate`) and module paths lowercase (`memos.ui`).
- Keep help/docs updates in sync when changing commands, keymaps, or config fields.
- New feature: multiple Memos API versions are supported. Any changes to API calls, data models, or UI flows must account for each supported version and document any version-specific behavior.

## Testing Guidelines

- There is no committed automated test suite yet; rely on headless load checks plus manual Neovim smoke testing.
- When fixing regressions, include clear reproduction steps in the PR and verify both list and edit/create flows.
- Test config precedence paths when relevant: defaults, saved config file, environment variables, and `setup()` overrides.

## Commit & Pull Request Guidelines

- Follow the repository’s existing commit style: short, imperative subjects (for example, `fix bugs`, `update readme`).
- Prefer scoped prefixes when useful (`feat:`, `fix:`), and call out breaking changes explicitly.
- PRs should include: purpose, user-facing impact, manual test steps, and doc updates (`README.md`/`doc/memos.nvim.txt`) when behavior changes.
