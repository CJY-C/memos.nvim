# Completed Features History

This document logs all features and optimizations that have been successfully implemented and refactored in the `memos.nvim` plugin.

---

## 1. Core Optimizations & Roadmap Features

### UTF-8 Character Slicing Security
- **Description**: Replaced raw Lua byte slicing (`:sub(1, N)`) with Neovim's multi-byte aware `vim.fn.strcharpart(str, start, len)` when truncating memo titles, snippet text, and relation labels.
- **Benefit**: Prevents display corruption, layout alignment bugs, and float window crashes caused by cutting multi-byte characters (e.g., CJK characters) in half.

### Buffer-Safe Auto-Save Logic
- **Description**: Refactored Neovim autocommands to pass the explicit buffer ID (`ev.buf`) to auto-save triggers, propagating it down to the save dispatcher.
- **Benefit**: Eliminates race conditions when a user rapidly switches between multiple editing splits, ensuring the plugin never auto-saves to or reads from the wrong buffer.

### cURL Request Timeout Handling
- **Description**: Added support for configurable/default connection and request timeouts (using `--max-time` flags in Plenary `Job` execution).
- **Benefit**: Prevents the plugin's UI from hanging in a perpetual `Refreshing...` or `Memos refreshing` state when the remote Memos server is offline or the connection drops.

### Pagination History Caching (Prev Page Support)
- **Description**: Implemented an in-memory stack to cache previous page tokens during list navigation, mapped to the `,` key by default.
- **Benefit**: Provides seamless backwards pagination (previous page navigation) which is natively unsupported in the Memos v1 API.

### Configurable Default Keymaps Disabling
- **Description**: Enabled users to selectively disable specific default keymaps by mapping them to `false` in their `setup()` configuration.
- **Benefit**: Allows power users to assign custom global mappings without them being overridden or bound within the Memos buffers.

---

## 2. Memo Relations Family

### Outgoing & Incoming Relations Indicators
- **Description**: Displays bidirectional relation link counts (`[→ X, ← Y]`) directly on each memo line in the list view, right-aligned with proper multi-byte highlight columns.

### Dynamic Relations Expansion
- **Description**: Mapped `<Tab>` to toggle the expansion of outgoing links, and `<S-Tab>` to toggle the expansion of incoming links in-place in the list buffer.
- **Benefit**: Renders sub-nodes dynamically in a tree-like hierarchy without opening separate windows.

### Fuzzy Select Memo Relations
- **Description**: Mapped `c` to prompt for linking target memos:
  - Detects if Telescope is available and opens a custom Telescope picker supporting multi-selection via `<Tab>` and batch-linking.
  - Automatically falls back to standard `vim.ui.select` (single selection) if Telescope is not installed.
  - Bridges clipboard content (first option), loaded cached memos, and manual input prompts in a unified selection list.

### Context-Aware Relation Unlinking
- **Description**: Overloaded the delete keymap `D` in the list buffer:
  - On a standard memo line: Prompts to archive/delete the memo.
  - On an expanded relation sub-line: Prompts to unlink that specific relation, performing a defensive local cache filter and server PATCH.

---

## 3. Historical Features & Cache Integrations

### In-Memory Stale Cache
- **Description**: Preserves loaded memos and update times across different view states in-memory during the Neovim session.
- **Benefit**: Enables sub-second start times by instantly rendering stale cached data upon opening the list, followed by an asynchronous background sync to fetch updates silently.

### Attachment Integration
- **Description**: Renders attachment indicator icons in the list view, signaling the presence of files/images attached to the memo.
