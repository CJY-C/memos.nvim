# memos.nvim

A small Neovim client for Memos focused on speed: list memos, create memos, edit memos, and save changes without opening the browser.

This branch only supports the latest Memos `/api/v1` API shape. Older API compatibility and request-heavy features were removed from the core path.

## Requirements

- Neovim
- `curl`
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- A Memos access token

## Install

With lazy.nvim:

```lua
{
  "Elflare/memos.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    require("memos").setup({
      host = "http://127.0.0.1:5230",
      token = "your-token",
    })
  end,
}
```

With nixvim, keep secrets out of the Nix store and point the plugin at a runtime env file:

```nix
{
  extraPlugins = [
    pkgs.vimPlugins.plenary-nvim
    # Add memos.nvim through your local plugin package or overlay.
  ];

  extraConfigLua = ''
    require("memos").setup({
      env_file = "/run/secrets-rendered/memos.env",
    })
  '';

  keymaps = [
    {
      mode = "n";
      key = "<leader>mm";
      action = "<cmd>Memos<CR>";
      options.desc = "Open Memos list";
    }
  ];
}
```

You can also pass a systemd-style env file from any plugin manager:

```lua
require("memos").setup({
  env_file = "/run/secrets-rendered/memos.env",
})
```

The file should contain:

```sh
MEMOS_HOST=http://127.0.0.1:5230
MEMOS_TOKEN=your-token
```

`MEMOS_HOST` must include `http://` or `https://`.

Global shell exports work for temporary debugging, but are not recommended for
long-lived use because the token is inherited by every child process.
Do not put `MEMOS_TOKEN` directly in Nix/nixvim config; it may enter the Nix store.
The env file must be readable by the user running Neovim.

## Commands

| Command | Description |
| --- | --- |
| `:Memos` | Toggle the main Memos list buffer (opens to the default state, e.g. `NORMAL`). |
| `:MemosCreate` | Open a new buffer to compose a new normal memo. |
| `:MemosTemplate` | Open the Memos template list buffer directly (switches state to `TEMPLATES`). |
| `:MemosSave` | Save the current memo or template buffer. (Can also be executed via `:w` in memo/template buffers). |

## Keymaps

The plugin provides keymaps inside the list buffer and inside the memo composition buffers.

### List Buffer Keymaps

The list buffer behaves as an interactive dashboard that supports three viewing modes (toggled with `A` and `T`):
- **Normal View**: Displays your active memos.
- **Archive View**: Displays your archived memos.
- **Template View**: Displays your archived memo templates (filtered by `#type/template`) fetched from the remote server.

The table below lists all list-view keymaps. Note that some keys adjust behavior depending on the active viewing mode:

| Key | Description | Behavior in Normal / Archive View | Behavior in Template View (`T`) |
| --- | --- | --- | --- |
| `<CR>` | **Edit / Split** | Opens the memo under cursor for editing. | Opens the template under cursor for editing. |
| `e` | **Edit** | Opens the memo under cursor for editing. | Opens the template under cursor for editing. |
| `o` | **Horizontal Split** | Edits the memo in a horizontal split. | Edits the template in a horizontal split. |
| `v` | **Vertical Split** | Edits the memo in a vertical split. | Edits the template in a vertical split. |
| `a` / `i` | **New / Instantiate** | Opens a blank buffer to compose a new normal memo. | Instantiates a new normal memo *from* the template under the cursor (strips `#type/template`). |
| `n` | **New** | Opens a blank buffer to compose a new normal memo. | Opens a blank buffer to compose a new template. |
| `D` | **Delete** | Deletes the selected memo (requires confirmation). | Deletes the selected template from the remote server. |
| `r` | **Refresh** | Refreshes the list from the remote server. | Refreshes the template list from the remote server. |
| `s` | **Search** | Prompts to search memos on the server using CEL query. | Prompts to search templates on the server using CEL query. |
| `T` | **Toggle Templates** | Switches the view to **Template View**. | Switches the view back to **Normal View**. |
| `A` | **Toggle Archive** | Toggles the view between **Normal** and **Archive** views. | Switches the view to **Archive View**. |
| `y` | **Copy ID** | Copies the selected memo name (e.g. `memos/123`) to system clipboard. | Copies the selected template name to system clipboard. |
| `p` | **Pin** | Toggles pinning state of the memo. | *Unsupported* (displays warning). |
| `x` | **Archive** | Toggles archiving state of the memo. | *Unsupported* (displays warning). |
| `V` | **Visibility** | Prompts to edit memo visibility (`PRIVATE`, etc.). | *Unsupported* (displays warning). |
| `t` | **Create Time** | Prompts to edit the creation timestamp. | *Unsupported* (displays warning). |
| `.` | **Next Page** | Loads the next page of memos (pagination). | Loads the next page of templates (pagination). |
| `q` | **Quit** | Closes the list buffer. | Closes the list buffer. |

### Memo / Template Buffer Keymaps

These keymaps are set up inside the buffer when writing a memo or template:

| Key | Description |
| --- | --- |
| `<leader>ms` | Save the current buffer to the remote server and sync local cache. |
| `<Esc>` | Return to the list view (unsaved buffers are kept modified). |

## Configuration

```lua
require("memos").setup({
  host = "http://127.0.0.1:5230",
  token = "your-token",
  env_file = nil,
  page_size = 50,
  list_state = "NORMAL",
  list_order_by = "pinned desc, update_time desc",
  list_style = "default",
  auto_save = false,
  window = {
    enable_float = true,
    width = 0.85,
    height = 0.85,
    border = "rounded",
  },
  keymaps = {
    list = {
      add_memo = "a",
      new_memo = "n",
      edit_memo = "<CR>",
      edit_memo_split = "o",
      edit_memo_vsplit = "v",
      search_memos = "s",
      copy_memo_id = "y",
      toggle_pin = "p",
      delete_memo = "D",
      archive_memo = "x",
      toggle_archive_view = "A",
      toggle_template_view = "T",
      edit_visibility = "V",
      edit_create_time = "T",
      refresh_list = "r",
      next_page = ".",
      quit = "q",
    },
    buffer = {
      save = "<leader>ms",
      back_to_list = "<Esc>",
    },
  },
})
```

Credential priority is explicit `host`/`token`, then `env_file`, then `MEMOS_HOST`/`MEMOS_TOKEN`. The plugin does not persist accounts; configure credentials declaratively through nixvim, `env_file`, or process env.

List search uses the Memos server-side `filter` parameter and still issues one list request per search. Plain text becomes `content.contains("...")`, `#tag` becomes a tag filter, and raw CEL filter expressions are passed through. Empty search input clears the filter. It does not fetch extra pages for local fuzzy search.

Copying a memo ID uses the memo resource name already present in the list response, such as `memos/abc123`. It does not issue any API request.

Toggling pin sends one PATCH request and then refreshes the list once in the background so server-side ordering is restored.

Saving an existing memo sends one PATCH request that updates both `content` and `update_time`, so browser views and `update_time` ordering reflect edits made from Neovim.

Deleting a memo asks for confirmation, sends one DELETE request, removes the memo from the local list immediately on success, and then refreshes the list once in the background. Force delete is intentionally not enabled.

`A` toggles between Normal and Archive views and sends one list request. `x` archives in the Normal view or restores in the Archive view, removes the memo from the current list immediately, and then refreshes the list once in the background.

Editing visibility opens a `vim.ui.select` picker and sends one PATCH request after choosing `PRIVATE`, `PROTECTED`, or `PUBLIC`.

Editing create time opens a `vim.ui.input` prompt with the current `create_time` and sends one PATCH request after confirmation.

Split editing also uses the memo content already present in the list response. It does not issue any extra API request.

`list_style` only changes local rendering and does not issue extra API requests. Use `"default"` for dated rows or `"compact"` for shorter rows.

The list uses an in-memory stale cache for the current Neovim session. When cached rows exist, opening or refreshing the list shows them immediately, marks the list as refreshing, and then replaces them after one background list request. The cache is not written to disk.

You can expose the refresh state in lualine without making lualine a plugin dependency:

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      require("memos").statusline,
    },
  },
})
```

With nixvim, keep it declarative in your lualine configuration:

```nix
plugins.lualine.settings.sections.lualine_x = [
  ''
    function()
      return require("memos").statusline()
    end
  ''
];
```

For custom statuslines, `require("memos").status()` returns `{ state, text, last_refresh_at, last_error }`.

With Nix/sops, keep the token scoped to the program that needs it:

```nix
sops.templates."memos.env" = {
  content = ''
    MEMOS_HOST=${config.services.memos.host}
    MEMOS_TOKEN=${config.sops.placeholder.memosToken}
  '';
};

systemd.services.<service>.serviceConfig.EnvironmentFile =
  config.sops.templates."memos.env".path;
```

That file is not automatically loaded into interactive shells, so `env | grep -i memos` returning nothing in a terminal is expected.

## Latency Test

Run a real API baseline:

```sh
MEMOS_ENV_FILE=/run/secrets-rendered/memos.env ./scripts/latency-test.sh
./scripts/latency-test.sh --env-file /run/secrets-rendered/memos.env
./scripts/latency-test.sh --env-file /run/secrets-rendered/memos.env --skip-write --runs 5
./scripts/latency-test.sh --env-file /run/secrets-rendered/memos.env --page-size 1 --warmup
./scripts/latency-test.sh --env-file /run/secrets-rendered/memos.env --skip-write --order-by "create_time desc"
./scripts/latency-test.sh --env-file /run/secrets-rendered/memos.env --skip-write --filter 'content.contains("todo")'
./scripts/cold-order-by-test.sh --env-file /run/secrets-rendered/memos.env
```

The script records list/create/update latency, request count, and curl timing breakdowns such as connect time and time to first byte. The update step patches both memo content and `update_time` in one request. It intentionally does not enforce a fixed threshold yet; use the output as a baseline while optimizing the plugin.

The script can also use credentials injected by a systemd service. The write portion creates and updates a test memo. Use a test Memos instance if you do not want benchmark entries in your main account.

Useful flags:

- `--runs N`: run multiple benchmark rounds and print min/avg/max.
- `--page-size N`: compare list latency for different page sizes.
- `--order-by VALUE`: compare list latency for different server-side sorting.
- `--filter VALUE`: compare list latency with a Memos CEL server-side filter.
- `--skip-write`: only measure list requests.
- `--warmup`: run a lightweight auth request before measured requests.

If `connect` is high, inspect network/proxy path. If `ttfb` is high while connect is low, inspect Memos server or database work.

`scripts/cold-order-by-test.sh` runs list-only tests for several `orderBy` values and sleeps 30 minutes between them by default. Override the pause with `--sleep-seconds N` when you need a shorter local check.

### Server-side list keepalive

If latency output shows low `connect` time but high `ttfb`, the slow part is likely the Memos server or database handling the list request. In that case, a server-side keepalive is more appropriate than adding plugin background traffic.

Keep the real list path warm, not just `auth/me`:

```sh
curl -fsS \
  --max-time 300 \
  --write-out "warmup http=%{http_code} total=%{time_total} connect=%{time_connect} ttfb=%{time_starttransfer}\n" \
  -H "Authorization: Bearer $MEMOS_TOKEN" \
  "$MEMOS_HOST/api/v1/memos?pageSize=1&state=NORMAL&orderBy=update_time%20desc" \
  >/dev/null
```

For NixOS/systemd, run the keepalive from a service with the same secret env file:

```nix
systemd.services.memos-list-keepalive = {
  serviceConfig = {
    Type = "oneshot";
    EnvironmentFile = config.sops.templates."memos.env".path;
    ExecStart = "${pkgs.curl}/bin/curl -fsS --max-time 300 --output /dev/null --write-out \"warmup http=%%{http_code} total=%%{time_total} connect=%%{time_connect} ttfb=%%{time_starttransfer}\\n\" -H \"Authorization: Bearer $MEMOS_TOKEN\" \"$MEMOS_HOST/api/v1/memos?pageSize=1&state=NORMAL&orderBy=update_time%20desc\"";
  };
};

systemd.timers.memos-list-keepalive = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnBootSec = "2min";
    OnUnitActiveSec = "1min";
    AccuracySec = "10s";
  };
};
```

`pageSize=1` is enough to exercise the list path. Start with a short interval such as 1 minute and inspect the `ttfb` values in `journalctl`; if the list path stays hot, gradually relax the timer to 2 minutes, 5 minutes, or longer. The plugin does not run this keepalive itself so the default request model stays explicit and minimal.

## Development

Smoke check:

```sh
./scripts/smoke-test.sh
```

The core list path should issue one list request for the first page. Features that require extra requests are tracked in [feature.md](feature.md).
