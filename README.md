# memos.nvim

English | [简体中文](./README.md#memosnvim-简体中文)

A Neovim plugin to interact with [Memos](https://github.com/usememos/memos) right inside the editor. List, create, edit, and delete your memos without leaving Neovim.

## ✨ Features

- **List Memos**: View, search, and paginate through your memos (shows pinned/archived indicators).
- **Create & Edit**: Create new memos or edit existing ones in a dedicated buffer with `markdown` filetype support.
- **Edit Metadata**: Update memo metadata (visibility, pinned, display time, create time, state, relations) from the list.
  - Relation edits prompt for append/delete/replace and accept multiple memo IDs (comma-separated, defaulting to clipboard).
  - Metadata prompts include a clipped memo title for context.
- **Relations Tree**: Toggle related memos under each item in the list (`gr`) and press `<CR>` on a relation to open it.
  - Memos with relations show `.. <→X><←Y>` counts (outgoing/incoming); `+` indicates more results.
  - Relations use `→`/`←` prefixes and show titles only; empty directions are omitted.
  - Time fields expect ISO 8601 / RFC3339. If you omit a timezone (e.g. `2025-02-07T12:34:56`), the plugin appends `Z` (UTC).
- **Delete Memos**: Delete memos directly from the list.
- **Customizable**: Configure API endpoints, keymaps, and more.
- **First-time Setup**: On first launch, you will be prompted to enter your Memos host and token. You can choose to save these permanently.
- **Floating Window**: Optional LazyVim-style floating window for the memo list.

## 📦 Installation

Requires [plenary.nvim](https://github.com/nvim-lua/plenary.nvim).

Install with [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "Elflare/memos.nvim", dependencies = { "nvim-lua/plenary.nvim" } },
```

## 🚀 Usage

### Commands

- `:Memos`: Toggles the list window (float or non-float); cached content is kept until a manual refresh.
- `:MemosCreate`: Opens a new buffer to create a new memo.
- `:MemosSave`: (Available in the memo buffer) Saves the memo you are currently creating or editing.
- `:MemosSwitch`: Select and switch to another saved account.
- `:MemosUserAdd`: Add a new account (`username`, `host`, `token`) interactively.
- `:MemosUserDelete`: Delete a saved account interactively.
- `:MemosModifyMeta`: (In memo buffer) Modify memo metadata; new memo will be created first.
- `:w`: (In the memo buffer) Same as `:MemosSave`.
- Untouched memo buffers are not marked as modified, so quitting Neovim will not prompt to save unless you actually edit.
- If `MEMOS_HOST` or `MEMOS_TOKEN` is set, account switching is disabled for that session.
- When floating window is enabled, memo edits open in the same float and are restored when toggling `:Memos`.
- Search supports plain text, `#tag` shorthand, or raw CEL. Examples: `meeting`, `#work #todo`, `content.contains("foo") && "work" in tags`.

### Default Keymaps

#### Global

| Key          | Action              |
| ------------ | ------------------- |
| `<leader>mm` | Open the Memos list |

#### In the Memo List Window

| Key         | Action                             |
| ----------- | ---------------------------------- |
| `a`         | Add a new memo                     |
| `y`         | Copy memo ID(s) to clipboard       |
| `p`         | Paste memo ID from clipboard       |
| `d` or `dd` | Delete the selected memo / relation |
| `D`         | Delete referenced memo (relation line) |
| `<CR>`      | Edit the selected memo             |
| `<S-m>`     | Edit metadata for selected memos   |
| `<Tab>`     | Toggle selection and move down     |
| `<S-Tab>`   | Toggle selection and move up       |
| `c`         | Clear selection                    |
| `gr`        | Toggle relations tree              |
| `<C-s>`     | Edit the selected memo in a split  |
| `<C-v>`     | Edit the selected memo in a vsplit |
| `m`         | Edit metadata for the selected memo |
| `s` or `f`  | Search your memos                  |
| `<S-f>`     | Fuzzy tag search (CEL only)        |
| `r`         | Refresh the memo list              |
| `.`         | Load the next page of memos        |
| `<S-s>`     | Select list sort order             |
| `<S-a>`     | Toggle memo state (NORMAL/ARCHIVED) |
| `q`         | Quit the list window               |

Note: `f` overrides Neovim's built-in find-char motion in the Memos list buffer only.

#### In the Edit/Create Buffer

| Key          | Action                |
| ------------ | --------------------- |
| `<leader>ms` | Save the current memo |
| `<leader>me` | Edit memo metadata    |

## ⚙️ Configuration

You can override the default settings by passing a table to the `setup()` function.

> **Note:** On first use, you will be prompted to enter your Memos host and token. You can choose to save these permanently.
> The config file will be stored at:
>
> - **macOS / Linux**: `~/.local/share/nvim/memos.nvim/config.json`
> - **Windows**: `~/AppData/Local/nvim-data/memos.nvim/config.json`

```lua
-- lua/plugins/memos.lua
require("memos").setup({
  -- Active account key in users[] (username@host)
  active_user = "default@http://127.0.0.1:5230",
  users = {
    { username = "default", host = "http://127.0.0.1:5230", token = "token_1" },
    { username = "work", host = "http://10.0.0.8:5230", token = "token_2" },
  },

  -- Number of memos to fetch per page
  page_size = 50,
  -- API compatibility mode: "auto", "v0.26", "v0.25", "v0.21"
  -- "auto" tries v0.26 first, then falls back to v0.25 and v0.21.
  -- "modern"/"legacy" are deprecated aliases for v0.26/v0.25.
  api_version = "auto",
  -- Default list sort order (v0.26 only)
  list_sort_default = "pinned desc, display_time desc",
  -- Presets used by <S-s> to select sort in list
  list_sort_presets = {
    "pinned desc, display_time desc",
    "display_time desc",
    "create_time desc",
  },
  -- Default state to request in list (v0.26/v0.21 only)
  list_state_default = "NORMAL",

  -- Auto-save the memo when leaving insert mode or holding the cursor.
  auto_save = false,
  -- Max length for memo title shown in metadata prompt
  metadata_title_max_len = 50,
  -- Max number of related memos shown per memo in list
  list_relations_limit = 20,
  -- Which relation directions to show: "out" | "in" | "both" | "none"
  list_relations_mode = "both",
  -- Show relations tree by default in list
  list_relations_auto_expand = true,
  -- Confirm before copying memo IDs to clipboard
  confirm_copy = false,
 -- Window configuration
  window = {
        enable_float = false, -- Set to true to open the list in a floating window
        width = 0.85,         -- Width ratio (0.0 to 1.0)
        height = 0.85,        -- Height ratio (0.0 to 1.0)
        border = "rounded",   -- Border style: "single", "double", "rounded", "solid", "shadow"
      },

  -- Set to false or nil to disable a keymap
  keymaps = {
    -- Keymap to open the memos list. Default: <leader>mm
    start_memos = "<leader>mm",

    -- Keymaps for the memo list window
    list = {
      add_memo = "a",
      copy_memo_id = "y",
      delete_memo = "d",
      delete_memo_visual = "dd",
      delete_relation_source = "D",
      -- Assign both <CR> and 'i' to edit a memo
      edit_memo = { "<CR>", "i" },
      vsplit_edit_memo = "<C-v>",
      split_edit_memo = "<C-s>",
      toggle_select_next = "<Tab>",
      toggle_select_prev = "<S-Tab>",
      multi_edit_metadata = "<S-m>",
      clear_selection = "c",
      toggle_relations = "gr",
      edit_metadata = "m",
      paste_memo = "p",
      search_memos = { "s", "f" },
      search_fuzzy = "<S-f>",
      refresh_list = "r",
      next_page = ".",
      toggle_sort = "<S-s>",
      toggle_state = "<S-a>",
      quit = "q",
    },
    -- Keymaps for the editing/creating buffer
    buffer = {
      save = "<leader>ms",
      edit_metadata = "<leader>me",
      -- Back to list from a memo
      back_to_list = '<Esc>'
    },
  },
})
```

API 版本说明：
- v0.21 使用 offset 分页，列表不支持排序。
- v0.21 搜索只支持纯文本 + `#tag`（不支持 CEL 过滤）。
- v0.21 不支持 displayTime 字段，relations 使用专用接口。

Notes on API versions:
- v0.21 uses offset pagination; list sort is not available.
- v0.21 search accepts plain text plus `#tag` (no CEL filters).
- v0.21 metadata does not support display time; relations use relation endpoints.

---

# memos.nvim (简体中文)

[English](./README.md#memosnvim) | 简体中文

一个 Neovim 插件，让你在编辑器内部直接与 [Memos](https://github.com/usememos/memos) 进行交互。无需离开 Neovim 即可列表、创建、编辑和删除你的 memos。

## ✨ 功能

- **列表 Memos**: 查看、搜索和翻页你的 memos（显示置顶/归档标识）。
- **创建与编辑**: 在专用的、支持 `markdown` 文件类型的缓冲区中创建新 memo 或编辑现有 memo。
- **编辑元数据**: 在列表中更新 memo 的可见性、置顶、展示时间、创建时间、状态、关系。
  - 关系编辑会提示 append/delete/replace，并支持多个 memo ID（逗号分隔，默认使用剪贴板）。
  - 元数据提示会显示裁剪后的 memo 标题，便于确认上下文。
- **关联树**: 在列表中切换显示关联 memo（`gr`），在关联行按 `<CR>` 打开对应 memo。
  - 有关联的 memo 会显示 `.. <→X><←Y>` 数量（出/入），`+` 表示还有更多。
  - 树中使用 `→`（引用）和 `←`（被引用）前缀，关联行仅显示标题；空方向会被省略。
  - 时间字段需 ISO 8601 / RFC3339 格式；若未包含时区（如 `2025-02-07T12:34:56`），插件会自动追加 `Z`（UTC）。
- **删除 Memos**: 直接从列表中删除 memo。
- **可定制**: 可配置 API 地址、快捷键等。
- **首次启动引导**: 首次启动时会提示输入 Memos 的 host 和 token，并询问是否永久保存。
- **浮动窗口**: 可选的 LazyVim 风格浮动窗口来展示 memo 列表。

## 📦 安装

需要 [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) 插件。

使用 [lazy.nvim](https://github.com/folke/lazy.nvim) 安装:

```lua
{ "Elflare/memos.nvim", dependencies = { "nvim-lua/plenary.nvim" } },
```

## 🚀 使用方法

### 命令

- `:Memos`: 切换列表窗口（浮动或非浮动）；列表内容会缓存直到手动刷新。
- `:MemosCreate`: 打开一个新的缓冲区来创建 memo。
- `:MemosSave`: (在 memo 编辑缓冲区中可用) 保存你正在创建或编辑的 memo。
- `:MemosSwitch`: 选择并切换已保存账号。
- `:MemosUserAdd`: 交互式添加新账号（`username`、`host`、`token`）。
- `:MemosUserDelete`: 交互式删除已保存账号。
- `:MemosModifyMeta`: （在 memo 编辑缓冲区中可用）修改 memo 元数据；新 memo 会先创建。
- `:w`: (在 memo 编辑缓冲区中可用) 等同于 `:MemosSave`。
- 未修改的 memo 缓冲区不会被标记为已更改；只有真正编辑后退出时才会提示保存。
- 如果设置了 `MEMOS_HOST` 或 `MEMOS_TOKEN`，该会话中将禁用账号切换。
- 如果启用了浮动窗口，memo 编辑会在同一个浮动窗口中打开，并在切换 `:Memos` 时保留。
- 搜索支持纯文本、`#tag` 简写或原生 CEL。示例：`meeting`、`#work #todo`、`content.contains("foo") && "work" in tags`。

### 默认快捷键

#### 全局快捷键

| 按键         | 功能            |
| ------------ | --------------- |
| `<leader>mm` | 打开 Memos 列表 |

#### 在 Memo 列表窗口中

| 按键        | 功能                        |
| ----------- | --------------------------- |
| `a`         | 新增一个 memo               |
| `y`         | 复制选中 memo 的 ID 到剪贴板（多选逗号分隔） |
| `p`         | 从剪贴板粘贴 memo ID        |
| `d` 或 `dd` | 删除所选的 memo             |
| `<CR>`      | 编辑所选的 memo             |
| `<S-m>`     | 编辑所选 memo 的元数据      |
| `<Tab>`     | 切换选中并向下移动光标       |
| `<S-Tab>`   | 切换选中并向上移动光标       |
| `c`         | 清除多选状态                |
| `gr`        | 切换关联树显示              |
| `<C-s>`     | 在水平分屏中编辑所选的 memo |
| `<C-v>`     | 在垂直分屏中编辑所选的 memo |
| `m`         | 编辑所选 memo 的元数据     |
| `s`         | 搜索你的 memos              |
| `r`         | 刷新 memo 列表              |
| `.`         | 加载下一页 memos            |
| `<S-s>`     | 选择列表排序                |
| `<S-a>`     | 切换 memo 状态（NORMAL/ARCHIVED） |
| `q`         | 退出列表窗口                |

#### 在编辑/创建缓冲区中

| 按键         | 功能          |
| ------------ | ------------- |
| `<leader>ms` | 保存当前 memo |

## ⚙️ 配置

你可以通过向 `setup()` 函数传递一个 table 来覆盖默认设置。

> **注意：** 首次使用时会提示输入 Memos 的 host 和 token，并询问是否永久保存。
> 配置文件将存储在：
>
> - **macOS / Linux**: `~/.local/share/nvim/memos.nvim/config.json`
> - **Windows**: `~/AppData/Local/nvim-data/memos.nvim/config.json`

```lua
-- lua/plugins/memos.lua
require("memos").setup({
  -- 当前激活账号（对应 users 中的 username@host）
  active_user = "default@http://127.0.0.1:5230",
  users = {
    { username = "default", host = "http://127.0.0.1:5230", token = "token_1" },
    { username = "work", host = "http://10.0.0.8:5230", token = "token_2" },
  },

  -- 每页获取的 memo 数量
  page_size = 50,
  -- API 兼容模式: "auto"、"v0.26"、"v0.25"、"v0.21"
  -- "auto" 会先尝试 v0.26，再回退到 v0.25 和 v0.21。
  -- "modern"/"legacy" 为 v0.26/v0.25 的废弃别名。
  api_version = "auto",
  -- 默认列表排序（仅 v0.26 支持）
  list_sort_default = "pinned desc, display_time desc",
  -- 列表内 <S-s> 选择的排序预设
  list_sort_presets = {
    "pinned desc, display_time desc",
    "display_time desc",
    "create_time desc",
  },
  -- 列表请求的默认状态（仅 v0.26/v0.21 支持）
  list_state_default = "NORMAL",

  -- 当离开插入模式或光标静止时，自动保存 memo。
  auto_save = false,
  -- 元数据提示中显示的 memo 标题长度上限
  metadata_title_max_len = 50,
  -- 列表中每条 memo 显示的关联数量上限
  list_relations_limit = 20,
  list_relations_mode = "both",
  list_relations_auto_expand = true,
  -- 复制 memo ID 前是否确认
  confirm_copy = false,
  -- 窗口配置
  window = {
        enable_float = false, -- 设置为 true 以在浮动窗口中打开列表
        width = 0.85,         -- 宽度比例 (0.0 到 1.0)
        height = 0.85,        -- 高度比例 (0.0 到 1.0)
        border = "rounded",   -- 边框样式: "single", "double", "rounded", "solid", "shadow"
      },

  -- 设置为 false 或 nil 可以禁用某个快捷键
  keymaps = {
    -- 用于打开 Memos 列表的快捷键。默认值: <leader>mm
    start_memos = "<leader>mm",

    -- memo 列表窗口的快捷键
    list = {
      add_memo = "a",
      copy_memo_id = "y",
      delete_memo = "d",
      delete_memo_visual = "dd",
      delete_relation_source = "D",
      -- 将 <CR> 和 i 键都设置为编辑功能
      edit_memo = { "<CR>", "i" },
      vsplit_edit_memo = "<C-v>",
      split_edit_memo = "<C-s>",
      toggle_select_next = "<Tab>",
      toggle_select_prev = "<S-Tab>",
      multi_edit_metadata = "<S-m>",
      clear_selection = "c",
      toggle_relations = "gr",
      edit_metadata = "m",
      paste_memo = "p",
      search_memos = { "s", "f" },
      search_fuzzy = "<S-f>",
      refresh_list = "r",
      next_page = ".",
      toggle_sort = "<S-s>",
      toggle_state = "<S-a>",
      quit = "q",
    },
    -- 编辑/创建窗口的快捷键
    buffer = {
      save = "<leader>ms",
      edit_metadata = "<leader>me",
      -- 从memo中返回列表的快捷键，默认设为 Esc
      back_to_list = '<Esc>' 
    },
  },
})
```
