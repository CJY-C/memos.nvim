# Developer Guide

This document provides developer guidelines for maintaining and extending `memos.nvim`.

---

## 1. Module Structure & Architecture

The plugin is structured into distinct modules with minimal abstraction:
- **`plugin/memos.lua`**: Neovim command entrypoint (`:Memos`, `:MemosCreate`, `:MemosTemplate`) and keymap wiring.
- **`lua/memos/init.lua`**: Plugin setup, configuration loading, credential loading (Nix/Sops env files and process env), and public API entrypoints.
- **`lua/memos/api.lua`**: Server-side communication wrapper using `plenary.job` executing `curl`. Returns normalized data schemas.
- **`lua/memos/ui.lua`**: Managing list buffer states, rendering caches, managing buffer-local keymaps, and buffer composition layouts.
- **`lua/memos/template.lua`**: Templates composition helper (e.g. tag stripping, ensuring `#type/template` exists on save, archiving templates).

---

## 2. The Stale Cache System

To deliver a high-performance experience, the plugin uses an **in-memory stale cache** for the Neovim session.

### Core Principle
Whenever a list view is opened or toggled:
1. **Immediate Rendering**: If cached items exist, render them **instantly** (`render_cached_memos()`).
2. **Background Update**: Trigger a silent background HTTP fetch (`fetch_memos({ append = false })`) to retrieve the latest data from the server.
3. **Silent Update**: Once the background request succeeds, the cache is replaced and the list buffer is updated.

### Maintaining Stale Cache Integrity
- **Do not use `force_refresh = true` on return paths**: When returning to the list (e.g. `return_to_list()` or after saving a memo in `save_or_create_dispatcher`), always call `M.show_memos_list()` without arguments. Hardcoding `force_refresh = true` forces a blank screen and shows `"Loading..."`, completely defeating the stale cache.
- **State-Specific Cache Registry**: The cache, page token, search filter, and last refresh time are stored separately in `caches` for each view mode (`NORMAL`, `ARCHIVED`, `TEMPLATES`). When switching views, save the current state using `save_current_state_cache()` and load the target state using `load_state_cache(state)`.

---

## 3. Race Condition Prevention in Async Requests

Because network requests are asynchronous, the user might switch views (e.g. from `NORMAL` to `TEMPLATES`) while a request is in flight.

### Thread-Safe Callbacks
To prevent an out-of-order callback from corrupting the active view:
- Capture the requesting list state on call: `local req_state = current_list_state`.
- Inside the callback, wrap execution in `vim.schedule` and check if the state is still active:
  ```lua
  if current_list_state == req_state then
      -- Success path: update active cache variables and render
      mark_refresh_success()
      M.render_memos(data, is_append)
  else
      -- Background path: update the background cache slot directly,
      -- do NOT modify global active variables or trigger redraws
      local c = caches[req_state]
      if not is_append then
          c.memos = data.memos or {}
          c.last_refresh_at = os.time()
      else
          vim.list_extend(c.memos, data.memos or {})
      end
      c.page_token = data.next_page_token or ""
  end
  ```

---

## 4. Vimscript Fast Event Context & Thread Safety

`plenary.job` executes callbacks on separate OS threads. Any direct calls to Vimscript functions (e.g. `vim.fn.*`, `vim.api.nvim_buf_set_lines`, `vim.cmd`) from those callbacks will cause crashes or errors (`E5560: vim.fn.* must not be called in a fast event loop`).

Always wrap UI changes, file operations, and callback invocations in `vim.schedule()`:
```lua
api.list_memos(opts, function(data, err)
    vim.schedule(function()
        if not data then
            -- handle UI update
            return
        end
        -- handle UI render
    end)
end)
```

---

## 5. Performance Constraints

Always keep the common user paths request-light:
- **List View**: Exactly **1** HTTP request.
- **Create Memo**: Exactly **1** HTTP request.
- **Update Memo**: Exactly **1** HTTP request.
- Avoid cascading or sequential HTTP calls unless absolutely necessary.
