# Performance & Network Request Analysis

This document details the network request counts, endpoints, caching strategies, and user-perceived latencies for all network-related features in the `memos.nvim` plugin.

---

## 1. Summary Matrix

| Action / Feature | User-Perceived Latency | Network Request Count | Request Method & Endpoint | Cache / Optimization Strategy |
| :--- | :--- | :--- | :--- | :--- |
| **Open List View (`:Memos`)** | Sub-second (< 10ms) | **1** (async background) | `GET /api/v1/memos` | **In-memory Stale Cache**: Instantly draws previous session's list. Fetches fresh data asynchronously. |
| **Pagination (`.` / `,`)** | ~100ms - 200ms | **1** | `GET /api/v1/memos?pageToken=...` | **Page Token Stack**: Caches previous page tokens in memory for instant backwards paging. |
| **Create Memo** | Instant (~2ms write) + Async (~100ms) | **1** | `POST /api/v1/memos` | Asynchronous Plenary `Job` execution. User can close/edit splits immediately. |
| **Create Template** | Instant (~2ms write) + Async (~100ms) | **2** | `POST /api/v1/memos`<br>`PATCH /api/v1/memos/{id}` | Creates the memo with `#type/template`, then archives it because the create API does not accept archive state in the create payload. |
| **Save/Update Memo** | Instant (~2ms write) + Async (~100ms) | **1** | `PATCH /api/v1/memos/{id}` | Updates local editor state instantly. Background API execution. |
| **Pin / Unpin Memo (`p`)** | Instant (< 5ms) | **1** (async background) | `PATCH /api/v1/memos/{id}` | Updates local line display and toggle pin state instantly. Background update. |
| **Archive / Delete (`x` / `D`)** | Instant (< 5ms) | **1** (async background) | `PATCH /api/v1/memos/{id}` (Archive)<br>`DELETE /api/v1/memos/{id}` (Delete) | Instantly deletes line from buffer and local cache. Asynchronous remote update. |
| **Link Relations (`c`)** | Instant (~5ms) + Async (~100ms) | **2** | 1x `PATCH /api/v1/memos/{id}/relations`<br>1x `GET /api/v1/memos` (async list refresh) | **Batched PATCH**: Sends all newly selected relations in one request. Refreshes list silently. |
| **Unlink Relation (`D` on rel)** | Instant (~5ms) + Async (~100ms) | **2** | 1x `PATCH /api/v1/memos/{id}/relations`<br>1x `GET /api/v1/memos` (async list refresh) | Filters out relation local cache instantly. Updates server and refreshes in background. |
| **Expand Relations (`<Tab>`)** | Instant (cached) or ~100ms (uncached) | **0 to N** (only for uncached related nodes) | `GET /api/v1/memos/{relatedMemoId}` | **Lazy On-Demand Fetching**: Queries memo details only on cache miss. Caches results immediately. |

---

## 2. In-Depth Architectural Guidelines

### A. List Buffer & Stale Cache Model
- **Architectural Goal**: Sub-second startup time.
- **Mechanism**:
  - The plugin maintains a global in-memory session cache (`self.memos_cache`) per list state.
  - When `:Memos` is invoked, if cached rows exist, they are rendered *immediately* into the buffer.
  - Concurrently, a background GET request is dispatched to fetch fresh data. The UI displays the `Refreshing...` status in the statusline/header.
  - Once the fetch completes, the cache is replaced, the buffer is redrawn silently, and the status transitions back to `idle`. This guarantees zero blockages on Neovim startup.

### B. Batched Relation Operations
- **Architectural Goal**: Minimize network request loops ($O(1)$ HTTP complexity).
- **Mechanism**:
  - The Memos API sets relations by accepting the full array of relationships for a given memo.
  - Rather than making individual HTTP requests sequentially for each added link, the plugin aggregates all target selections (including those selected via Telescope multi-select) into a single PATCH payload.
  - Similarly, unlinking filters the existing relation table locally and PATCHes the updated collection in a single request.

### C. On-Demand Lazy Loading (Relation Nodes)
- **Architectural Goal**: Avoid fetching detail payloads for all related nodes upfront.
- **Mechanism**:
  - The main list response returns relation metadata containing owner/target names but not the full content or titles of the related memos.
  - The list session builds an in-memory relation index from the current cache so link counts and expansion rows can be rendered without rescanning every memo for every row.
  - When a user presses `<Tab>` to expand links, the plugin lazy-loads the target memo's details *only if* it is not already present in the local cache. Once fetched, the information is persisted so subsequent expansions are instant and require zero requests.
