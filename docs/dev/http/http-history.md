# HTTP 请求历史（PosteHttpHistory）

> 文件驱动的 HTTP 请求历史记录与管理 UI。

## 概述

PosteHttpHistory 提供一个覆盖窗口大小的浮动弹窗，左侧展示请求列表（倒序），右侧展示选中请求的详情。历史记录持久化到磁盘，跨 Neovim 会话保留。

## 数据模型

### 存储

文件：`stdpath('data')/poste/http_history.json`

```json
{
  "version": 1,
  "id_counter": 42,
  "max_entries": 100,
  "entries": [
    {
      "id": 42,
      "name": "Get Profile",
      "time": 1748307120,
      "source_file": "/path/to/api.http",
      "response": { ... },
      "assertion_results": null,
      "script_logs": null
    }
  ]
}
```

每个 entry 的 `response.body` 在序列化时截断至 100KB。

### session 状态（`state.lua`）

```lua
M.http_history = {}               -- entry[] (newest first)
M.http_history_max = 100          -- 最多保留条目数
M.http_history_id_counter = 0     -- 自增 ID
M.http_history_loaded = false     -- 是否已从磁盘加载
```

### entry 结构

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | number | 自增唯一 ID |
| `name` | string | request name (`###`后内容) 或 `"Request #N"` |
| `time` | number | `os.time()` |
| `source_file` | string | 源 `.http` 文件路径 |
| `response` | table | 完整 response JSON（Rust 输出结构） |
| `assertion_results` | table\|nil | `{ passed, failed, total, tests, logs }` |
| `script_logs` | table\|nil | `{ "log line", ... }` |

## UI 布局

```
┌─────────────── " Poste HTTP History " ──────────────────────┐
│ ┌─ 左列表 (30-40 col) ─┐ ┌─ 右详情 (剩余宽度) ────────────┐ │
│ │ Get Profile   23:32  │ │ [Body[H] | Rqst[R] | Verb[L]  │ │
│ │──────────────────────│ │  | Asserts[A]]  (winbar tabs)  │ │
│ │ Request 3     23:30 │ │─────────────────────────────────│ │
│ │ Request 2     22:45 │ │  (rendered via format.lua)      │ │
│ │ Request 1     21:34 │ │                                 │ │
│ │ Login         20:33 │ │                                 │ │
│ └──────────────────────┘ └─────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

### 左列表 buffer

- j/k 导航，实时更新右侧详情
- `<CR>`：光标跳到右侧详情 buffer
- `dd`：删除当前行对应的请求记录（立即保存到磁盘）
- `q`：关闭整个弹窗

### 右详情 buffer

- 与已有 response buffer 一致的 winbar tab 切换：
  - `H` — Body
  - `R` — Rqst (request payload)
  - `L` — Verb (verbose)
  - `A` — Asserts
  - `S` — Script
  - `<Tab>` / `<S-Tab>` — 循环切换 tabs
- jq filter：`<leader>j` / `<leader>jc` / `<leader>jr` / `<leader>jo`
- `q`：关闭整个弹窗

## 实现文件

### 新增

| 文件 | 行数 | 角色 |
|------|------|------|
| `lua/poste/http/history.lua` | ~400 | 主模块：UI、持久化、导航 |
| `docs/dev/http/http-history.md` | — | 本文档 |

### 修改

| 文件 | 改动 |
|------|------|
| `lua/poste/state.lua` | +4 字段 + keymap section |
| `lua/poste/http/run.lua` | +1 调用 `history.add_entry()` |
| `lua/poste/init.lua` | +1 command `:PosteHttpHistory` |
| `docs/dev/file-index.md` | +1 条目 |
| `.opencode/skills/http/SKILL.md` | +1 条目 |

## 关键设计决策

1. **自包含模块** — history.lua 管理自己的浮动窗口 + 两个 buffer。不修改 buffer.lua / view.lua / format.lua。
2. **详情渲染不依赖 `state.last_response`** — 调用 `format.format_body(entry.response)` 等，传入 entry 自身的 response 数据。Tab 状态局部于 history detail buffer。
3. **jq 支持** — 临时交换 `state.last_response` 后调用 `json.apply_filter()`，操作完恢复。
4. **持久化** — JSON 文件，懒加载（首次打开时），每 add/delete 后异步保存。
5. **body 截断** — 序列化时 `response.body` 超过 100KB 则截断以控制文件大小。

## 边界情况

- **空历史**：显示 "(no history)"，`q` 关闭
- **dd 删除最后一条**：列表清除，详情显示 "(no history)"
- **同一个请求重复执行**：保留两个 entry（不同 id / time）
- **批量执行多个请求**：每个响应独立 entry
- **源 buffer 被删除**：entry 仍然有效（存了完整 response）
- **超大响应 body**：内存中完整保留，仅持久化时截断

## 用户配置

```lua
require("poste").setup({
  http_history_max = 100,
  keymaps = {
    http_history = {
      close = "q",
      delete_entry = "dd",
      focus_detail = "<CR>",
    },
  },
})
```