# Deferred Features

The core plugin now prioritizes a fast path: one request for list, one request for create, one request for update. The features below were removed from the core refactor and can be restored incrementally when their request cost and UI behavior are explicit.

## Request-Light Features

None currently.

## Request-Heavy Features

- Attachments in the list. Requires per-memo attachment requests unless the list API response is enough.
- Relations in the list. Requires relation requests and often title resolution requests.
- Incoming relation counts. Requires extra relation listing.
- Fuzzy hierarchical tag search. Can require fetching additional pages locally.
- Template memos. Online templates require list/create/update flows outside the core memo path.
- Metadata editing for create time, relations, and location.
- Delete memo and force delete flows.
- Comments, reactions, shares, and link metadata.

## Future Acceptance Rules

- Any feature added back to the default list view must state its request count.
- Request-heavy features should be opt-in and disabled by default.
- `scripts/latency-test.sh` should be extended when a feature claims to improve or preserve speed.
- README and `doc/memos.nvim.txt` must be updated with any restored command, keymap, or config field.
