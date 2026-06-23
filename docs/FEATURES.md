# Deferred & Planned Features

The core plugin prioritizes a fast path: one request for list, one request for create, one request for update. All new features and optimizations should align with this request-light architecture.

---

## 1. Planned Optimizations & Features Roadmap

The following 5 optimizations are planned for future implementation, ordered by priority of impact and execution:

### [Priority 1] UTF-8 Character Slicing Security
* **Description**: Replace raw byte slicing (`:sub(1, N)`) with Neovim's `vim.fn.strcharpart(str, start, len)` when truncating memo content for buffer names, relation lists, and templates.
* **Rationale**: Prevents multi-byte UTF-8 characters (like CJK characters) from being cut in half, avoiding display corruption and potential floating window layout crashes.
* **Cost**: Zero HTTP requests.

### [Priority 2] Buffer-Safe Auto-Save Logic
* **Description**: Pass the explicit buffer ID (`ev.buf`) from Neovim autocommands to `check_and_auto_save(buf)` and propagate it to `save_or_create_dispatcher({ bufnr = buf })`.
* **Rationale**: Avoids race conditions when a user rapidly switches buffers, ensuring that the plugin never reads from or auto-saves to the wrong buffer.
* **Cost**: Zero HTTP requests.

### [Priority 3] cURL Request Timeout Handling
* **Description**: Add default or configurable connection/request timeout flags (e.g. `--max-time 10`) in the Plenary `Job` arguments in `api.lua`.
* **Rationale**: Prevents the plugin's list view from remaining in a perpetual `(Refreshing...)` state when the Memos server is unresponsive or the network drops.
* **Cost**: Zero HTTP requests.

### [Priority 4] Pagination History Caching (Prev Page Support)
* **Description**: Cache a stack of previous page tokens inside the session. Define a keybinding (e.g., `,`) to retrieve the previous page token from the stack and request it.
* **Rationale**: Adds backward pagination navigation support, which is natively missing in the Memos v1 API.
* **Cost**: Request-light (standard 1-request paging).

### [Priority 5] Configurable Default Keymaps Disabling
* **Description**: Allow mapping individual default keys to `false` in `setup()` to completely skip their binding.
* **Rationale**: Provides power users with the flexibility to use custom global keymaps without them being overridden in the Memos buffer.
* **Cost**: Zero HTTP requests.

---

## 2. Deferred Features (Request-Heavy)

The features below are deferred from the core refactor and can be restored only when their request cost and UI behavior are explicit:
* **Fuzzy hierarchical tag search**: Can require fetching additional pages locally.
* **Comments**: Nested request dependencies.

---

## 3. Future Acceptance Rules

* Any feature added back to the default list view must state its request count.
* Request-heavy features should be opt-in and disabled by default.
* `scripts/latency-test.sh` should be extended when a feature claims to improve or preserve speed.
* README and `doc/memos.nvim.txt` must be updated with any restored command, keymap, or config field.
