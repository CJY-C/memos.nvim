# Deferred Features

The core plugin prioritizes a fast path: one request for list, one request for create, one request for update. All new features and optimizations should align with this request-light architecture.

All successfully completed features and optimizations have been moved to [history.md](file:///home/masa/Projects/neovim-plugin/memos.nvim/docs/history.md).

---

## 1. Deferred Features (Request-Heavy)

The features below are deferred from the core refactor and can be restored only when their request cost and UI behavior are explicit:
* **Fuzzy hierarchical tag search**: Can require fetching additional pages locally.
* **Comments**: Nested request dependencies.

---

## 2. Future Acceptance Rules

* Any feature added back to the default list view must state its request count.
* Request-heavy features should be opt-in and disabled by default.
* `scripts/latency-test.sh` should be extended when a feature claims to improve or preserve speed.
* README and `doc/memos.nvim.txt` must be updated with any restored command, keymap, or config field.
