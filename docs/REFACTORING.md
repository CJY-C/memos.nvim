# Refactoring Plan & Design Defect Analysis

This document identifies design defects in `memos.nvim` and proposes structural improvements for future refactoring efforts.

---

## 1. Global State Pollution in `lua/memos/ui.lua`

### Defect
Currently, UI states (e.g. `memos_cache`, `list_buf`, `caches`, `current_list_state`, `last_refresh_at`) are stored as file-level local variables in `ui.lua`. This makes the module heavily stateful.
- **Risks**: Prone to memory leaks, difficult to test unit-wise, and hard to manage if multiple list buffers/windows are active.
- **Refactoring Suggestion**:
  Encapsulate the state into a session object (e.g. a `ListSession` class) instantiated when opening the list dashboard.
  ```lua
  local ListSession = {}
  ListSession.__index = ListSession

  function ListSession.new(opts)
      return setmetatable({
          buf = nil,
          win = nil,
          caches = { NORMAL = {}, ARCHIVED = {}, TEMPLATES = {} },
          current_state = opts.state or "NORMAL",
          filter = "",
      }, ListSession)
  end
  ```

---

## 2. Direct Coupling of API Module to Configuration

### Defect
`lua/memos/api.lua` directly imports `require("memos").config` to retrieve `host` and `token` credentials.
- **Risks**: Prevents mocking the configuration for isolated unit tests, and couples the network client directly to global plugin state.
- **Refactoring Suggestion**:
  Refactor `api.lua` into a constructor-based client, or pass the configuration table explicitly as an argument to API calls.
  ```lua
  local Client = {}
  Client.__index = Client

  function Client.new(config)
      return setmetatable({
          host = config.host,
          token = config.token,
      }, Client)
  end
  ```

---

## 3. Legacy Vimscript Window Commands

### Defect
The plugin relies on executing legacy Vimscript commands (e.g., `vim.cmd("split")`, `vim.cmd("enew")`, and `vim.cmd("vsplit")`) inside `ui.open_edit_buffer` to control layouts.
- **Risks**: Imperfect window dimension controls, difficult floating window management, and hard-to-maintain focus restoration logic.
- **Refactoring Suggestion**:
  Transition to pure Lua Neovim window APIs (`vim.api.nvim_open_win()`, `vim.api.nvim_win_set_buf()`). This gives precise control over split layouts, borders, and margins, and simplifies handling focus between floats and normal splits.

---

## 4. Static Buffer-Local Keymap Binding

### Defect
Keymaps in the list buffer are bound only once on buffer creation:
```lua
if not vim.b[buf].memos_list_keymaps then
    -- bind keymaps
    vim.b[buf].memos_list_keymaps = true
end
```
- **Risks**: If the user overrides keymaps at runtime, the changes do not take effect in an already-created list buffer unless it is completely wiped and re-created.
- **Refactoring Suggestion**:
  Bind keymaps dynamically in an autocommand on buffer entry (`BufEnter`), or register them as global/buffer-local User Commands, allowing changes to apply instantly.

---

## 5. Lack of Automated Unit Testing

### Defect
The repository currently lacks an automated unit testing suite, relying entirely on manual checks and headless syntax load checks.
- **Risks**: Difficult to verify changes to CEL search query generation, date parsing, and template tag stripping, leading to regressions.
- **Refactoring Suggestion**:
  Set up `plenary.test_harness` or `busted` under the `tests/` directory and integrate it into `scripts/smoke-test.sh` so that unit tests can run automatically in headless mode.
