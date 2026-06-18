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
| `:Memos` | Toggle the memo list |
| `:MemosCreate` | Open a new memo buffer |
| `:MemosSave` | Save the current memo buffer |

## Keymaps

List buffer:

| Key | Description |
| --- | --- |
| `<CR>` | Edit selected memo |
| `a` | Create memo |
| `r` | Refresh list |
| `.` | Load next page |
| `q` | Quit list |

Memo buffer:

| Key | Description |
| --- | --- |
| `<leader>ms` | Save memo |
| `<Esc>` | Return to list |

## Configuration

```lua
require("memos").setup({
  host = "http://127.0.0.1:5230",
  token = "your-token",
  env_file = nil,
  page_size = 50,
  list_state = "NORMAL",
  list_order_by = "pinned desc, update_time desc",
  auto_save = false,
  window = {
    enable_float = true,
    width = 0.85,
    height = 0.85,
    border = "rounded",
  },
})
```

Credential priority is explicit `host`/`token`, then `env_file`, then `MEMOS_HOST`/`MEMOS_TOKEN`. The plugin does not persist accounts; configure credentials declaratively through nixvim, `env_file`, or process env.

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
./scripts/cold-order-by-test.sh --env-file /run/secrets-rendered/memos.env
```

The script records list/create/update latency, request count, and curl timing breakdowns such as connect time and time to first byte. It intentionally does not enforce a fixed threshold yet; use the output as a baseline while optimizing the plugin.

The script can also use credentials injected by a systemd service. The write portion creates and updates a test memo. Use a test Memos instance if you do not want benchmark entries in your main account.

Useful flags:

- `--runs N`: run multiple benchmark rounds and print min/avg/max.
- `--page-size N`: compare list latency for different page sizes.
- `--order-by VALUE`: compare list latency for different server-side sorting.
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
