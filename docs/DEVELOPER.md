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

---

## 6. Defensive Programming in Async Contexts & Unit Tests

### Defensive Buffer Operations
When writing to or modifying buffers inside `vim.schedule()` callbacks, **always verify buffer validity** using `vim.api.nvim_buf_is_valid(buf)`. Because these callbacks run asynchronously, the user or testing framework may close the buffer before the callback executes, which can lead to `Invalid buffer id` crashes.
```lua
function ListSession:set_list_lines(lines)
	local buf = self.buf
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
	end
end
```

### Dealing with Multi-level `vim.schedule` in Unit Tests
If the production code schedules an async callback that in turn schedules another UI update (multi-level `vim.schedule` nesting), testing assertions executed immediately after the trigger might run before the entire queue of scheduled functions completes.
In Plenary Busted unit tests, use `vim.wait(timeout, condition_fn)` to allow the Neovim event loop to process scheduled tasks before making assertions:
```lua
ui.show_memos_list()

local s = ui.get_session(vim.api.nvim_get_current_buf())
-- Wait up to 1 second for scheduled render callbacks to run and cache to populate
vim.wait(1000, function()
	return #s.memos_cache > 0
end)

assert.are.same(1, #s.memos_cache)
```

---

## 7. Memos API Relations Schema Handling

When parsing relations between memos (e.g. for outgoing and incoming link calculations):
- **Nested Schema Types**: Depending on the Memos server version, relation fields (`rel.memo` and `rel.relatedMemo`) in the JSON response may be represented either as plain resource strings (e.g. `"memos/123"`) or as nested tables/objects (e.g. `{ name = "memos/123", snippet = "" }`).
- **Defensive Extraction**: Avoid direct string comparisons on these fields. Instead, use a helper function like `get_name_from_relation_field(field)` to extract the string value safely:
  ```lua
  local function get_name_from_relation_field(field)
  	if type(field) == "string" then
  		return field
  	elseif type(field) == "table" then
  		return field.name or field.memo_name or ""
  	end
  	return ""
  end
  ```
- **Display Width vs. Byte Length**:
  - When calculating alignment gaps for rendering right-aligned link indicators, always use `vim.fn.strdisplaywidth(str)` instead of `#str` (byte length). This ensures correct alignment columns when memo titles contain CJK or multi-byte characters.
  - When passing columns to Neovim highlighting APIs (e.g. `vim.api.nvim_buf_add_highlight`), continue using byte length `#str` since Neovim expects byte-indexed offsets.

---

## 8. UI Consistency & Loading Indicators

To maintain visual feedback for network activity and ensure a consistent user experience:
- **Active Refresh State**: When any background request is initiated—whether it is the main memo list fetch (`list_memos`) or fetching missing relation details for expanded nodes—the session's refresh state must transition to `"refreshing"` (via `self:set_refresh_state("refreshing")`). This ensures that the header line displays the `Refreshing...` status.
- **Coordination of Active Fetches**: The status indicator must remain `"refreshing"` as long as there is any in-flight fetch request. We track this using:
  - `self.main_list_fetching`: A boolean flag representing the main list API fetch.
  - `self.in_flight_relations`: A table mapping memo resource names currently being fetched in the background.
- **Helper Coordination**: Use `has_active_fetches(self)` to dynamically check if either of these is active. The transition back to `"idle"` must only occur when both operations are fully complete.

---

## 9. Safe ID Comparisons & UI Select Customization

### Safe ID and Name Comparisons (Avoiding `tostring(nil)` Bugs)
- **Problem**: In Memos API v1, memo objects do not return an `id` field (only a resource `name`, e.g. `memos/123`). When compiling lists or filtering relations, using simple string conversions like `tostring(m.id)` results in `"nil"`. Comparing two `nil` values with `tostring` (e.g. `tostring(m.id) == tostring(memo.id)`) evaluates to `"nil" == "nil"`, which is `true`. This causes logic bugs like filtering out all cached memos.
- **Guideline**: Avoid comparing raw stringified IDs directly if they can be nil. Always check if both IDs exist before comparing them, or use the project helper functions:
  - `match_memo_id_or_name(memo, val)`: Safely checks if a memo matches a target name or ID string, ignoring nil IDs.
  - `is_same_memo(memo1, memo2)`: Checks if two memo objects represent the same memo by comparing their `name` fields first, and only falling back to `id` comparison if both IDs exist.

### Customizing UI Select Dialogs (`vim.ui.select`)
- **Problem**: Default configurations of Neovim select plugins (e.g. `telescope-ui-select`, `dressing.nvim`) may open full-screen or oversized float windows for short prompt choices (e.g. visibility editing, deletion confirmation).
- **Guideline**: Always supply a descriptive `kind` string inside the `opts` table when calling `vim.ui.select(items, opts, on_choice)`. This allows users to target specific prompts and define compact themes (e.g. `get_dropdown` or `get_cursor` layouts) in their config setup:
  - `kind = "memos_relation"` for relation list picking.
  - `kind = "memos_visibility"` for visibility settings.
  - `kind = "memos_delete"` for deletion confirmation prompts.
  - `kind = "memos_unlink"` for unlinking confirmation prompts.

---

## 10. Telescope Custom Picker Troubleshooting (Previewer Freeze)

- **Problem**: When implementing a custom Telescope picker with custom string entries (such as `[Use Clipboard: memos/3]` or `memos/1 - nixos setup`), Telescope will by default attempt to run its file/buffer previewers on the highlighted entry. Because these entries are menu labels rather than real file paths on the disk, Telescope gets stuck searching for files or running file operations in the background, causing Neovim to freeze or stutter during item navigation/selection.
- **Guideline**: When writing custom Telescope pickers for non-file text selections, always explicitly disable the previewer by setting `previewer = false` in the picker options:
  ```lua
  pickers.new(opts, {
      prompt_title = "Title",
      finder = finders.new_table { ... },
      sorter = conf.generic_sorter(opts),
      previewer = false, -- Disables previewer to prevent lag/freezes
      attach_mappings = function(prompt_bufnr, map)
          ...
      end
  }):find()
  ```



