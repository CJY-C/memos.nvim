# memos.nvim

English | [简体中文](./README.md#memosnvim-简体中文)

A Neovim plugin to interact with [Memos](https://github.com/usememos/memos) right inside the editor. List, create, edit, and delete your memos without leaving Neovim.

## ✨ Features

- **List Memos**: View, search, and paginate through your memos.
- **Create & Edit**: Create new memos or edit existing ones in a dedicated buffer with `markdown` filetype support.
- **Edit Metadata**: Update memo metadata (visibility, pinned, display time, create time, state) from the list.
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

- `:Memos`: Opens a floating window to list and search your memos.
- `:MemosCreate`: Opens a new buffer to create a new memo.
- `:MemosSave`: (Available in the memo buffer) Saves the memo you are currently creating or editing.
- `:MemosSwitch`: Select and switch to another saved account.
- `:MemosAddUser`: Add a new account (`username`, `host`, `token`) interactively.
- `:MemosModifyMeta`: (In memo buffer) Modify memo metadata; new memo will be created first.
- `:w`: (In the memo buffer) Same as `:MemosSave`.
- Untouched memo buffers are not marked as modified, so quitting Neovim will not prompt to save unless you actually edit.
- If `MEMOS_HOST` or `MEMOS_TOKEN` is set, account switching is disabled for that session.

### Default Keymaps

#### Global

| Key          | Action              |
| ------------ | ------------------- |
| `<leader>mm` | Open the Memos list |

#### In the Memo List Window

| Key         | Action                             |
| ----------- | ---------------------------------- |
| `a`         | Add a new memo                     |
| `y`         | Copy selected memo ID to clipboard |
| `p`         | Paste memo ID from clipboard       |
| `d` or `dd` | Delete the selected memo           |
| `<CR>`      | Edit the selected memo             |
| `<Tab>`     | Edit the selected memo in a vsplit |
| `s`         | Search your memos                  |
| `r`         | Refresh the memo list              |
| `.`         | Load the next page of memos        |
| `q`         | Quit the list window               |

#### In the Edit/Create Buffer

| Key          | Action                |
| ------------ | --------------------- |
| `<leader>ms` | Save the current memo |

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
  -- Active account username in users[]
  active_user = "default",
  users = {
    { username = "default", host = "http://127.0.0.1:5230", token = "token_1" },
    { username = "work", host = "http://10.0.0.8:5230", token = "token_2" },
  },

  -- Number of memos to fetch per page
  page_size = 50,
  -- API compatibility mode: "auto", "modern", "legacy"
  -- "auto" tries modern first, then falls back to legacy.
  api_version = "auto",

  -- Auto-save the memo when leaving insert mode or holding the cursor.
  auto_save = false,
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
      -- Assign both <CR> and 'i' to edit a memo
      edit_memo = { "<CR>", "i" },
      vsplit_edit_memo = "<Tab>",
      edit_metadata = "m",
      paste_memo = "p",
      search_memos = "s",
      refresh_list = "r",
      next_page = ".",
      quit = "q",
    },
    -- Keymaps for the editing/creating buffer
    buffer = {
      save = "<leader>ms",
      -- Back to list from a memo
      back_to_list = '<Esc>'
    },
  },
})
```

---

# memos.nvim (简体中文)

[English](./README.md#memosnvim) | 简体中文

一个 Neovim 插件，让你在编辑器内部直接与 [Memos](https://github.com/usememos/memos) 进行交互。无需离开 Neovim 即可列表、创建、编辑和删除你的 memos。

## ✨ 功能

- **列表 Memos**: 查看、搜索和翻页你的 memos。
- **创建与编辑**: 在专用的、支持 `markdown` 文件类型的缓冲区中创建新 memo 或编辑现有 memo。
- **编辑元数据**: 在列表中更新 memo 的可见性、置顶、展示时间、创建时间、状态。
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

- `:Memos`: 打开一个浮动窗口，列出并搜索你的 memos。
- `:MemosCreate`: 打开一个新的缓冲区来创建 memo。
- `:MemosSave`: (在 memo 编辑缓冲区中可用) 保存你正在创建或编辑的 memo。
- `:MemosSwitch`: 选择并切换已保存账号。
- `:MemosAddUser`: 交互式添加新账号（`username`、`host`、`token`）。
- `:MemosModifyMeta`: （在 memo 编辑缓冲区中可用）修改 memo 元数据；新 memo 会先创建。
- `:w`: (在 memo 编辑缓冲区中可用) 等同于 `:MemosSave`。
- 未修改的 memo 缓冲区不会被标记为已更改；只有真正编辑后退出时才会提示保存。
- 如果设置了 `MEMOS_HOST` 或 `MEMOS_TOKEN`，该会话中将禁用账号切换。

### 默认快捷键

#### 全局快捷键

| 按键         | 功能            |
| ------------ | --------------- |
| `<leader>mm` | 打开 Memos 列表 |

#### 在 Memo 列表窗口中

| 按键        | 功能                        |
| ----------- | --------------------------- |
| `a`         | 新增一个 memo               |
| `y`         | 复制选中 memo 的 ID 到剪贴板 |
| `p`         | 从剪贴板粘贴 memo ID        |
| `d` 或 `dd` | 删除所选的 memo             |
| `<CR>`      | 编辑所选的 memo             |
| `<Tab>`     | 在垂直分屏中编辑所选的 memo |
| `s`         | 搜索你的 memos              |
| `r`         | 刷新 memo 列表              |
| `.`         | 加载下一页 memos            |
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
  -- 当前激活账号（对应 users 中的 username）
  active_user = "default",
  users = {
    { username = "default", host = "http://127.0.0.1:5230", token = "token_1" },
    { username = "work", host = "http://10.0.0.8:5230", token = "token_2" },
  },

  -- 每页获取的 memo 数量
  page_size = 50,
  -- API 兼容模式: "auto"、"modern"、"legacy"
  -- "auto" 会先尝试 modern，再回退到 legacy。
  api_version = "auto",

  -- 当离开插入模式或光标静止时，自动保存 memo。
  auto_save = false,
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
      -- 将 <CR> 和 i 键都设置为编辑功能
      edit_memo = { "<CR>", "i" },
      vsplit_edit_memo = "<Tab>",
      edit_metadata = "m",
      paste_memo = "p",
      search_memos = "s",
      refresh_list = "r",
      next_page = ".",
      quit = "q",
    },
    -- 编辑/创建窗口的快捷键
    buffer = {
      save = "<leader>ms",
      -- 从memo中返回列表的快捷键，默认设为 Esc
      back_to_list = '<Esc>' 
    },
  },
})
```
