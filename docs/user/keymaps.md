# 键位映射参考

> Poste 所有按键均可自定义。在 `setup()` 中传入 `keymaps` 表覆盖即可。

```lua
require("poste").setup({
  keymaps = {
    -- 只写你想改的, 其余保持默认
    http_source = {
      run = "<leader>r",  -- 把 <CR> 改成 <leader>r
    },
    http_response = {
      view_body = false,  -- false = 禁用该按键
    },
  },
})
```

`<leader>` 会被替换为你的 mapleader 实际值，特殊字符自动映射为可读名称（如空格 → `<Space>`）。例如：

---

## 键位分组索引

Poste 的键位按界面元素分组，每个分组有唯一的配置名：

| 配置名 | 所属协议 | 界面 |
|--------|----------|------|
| `http_source` | HTTP | HTTP 请求源文件（`.http` / `.rest`）|
| `http_response` | HTTP | HTTP 响应缓冲区 |
| `http_history` | HTTP | HTTP 请求历史弹窗 |
| `sql_source` | SQL | SQL 源文件（`.sql` / `.mysql` / `.sqlite`）|
| `sql_dataset` | SQL | SQL 数据集结果缓冲区 |
| `sql_table_ops` | SQL | SQL 表操作菜单 |
| `sql_db_browser` | SQL | 数据库浏览器 |
| `sql_introspect` | SQL | Introspect 结构浮窗 |

在 `setup({ keymaps = { <配置名> = { ... } } })` 中覆盖即可自定义。

---

## 一、HTTP 源文件 (`http_source`)

| 按键 | 动作 | 说明 |
|------|------|------|
| `<CR>` | `run` | 执行光标所在请求 |
| `]]` | `jump_next` | 跳到下一个请求块 |
| `[[` | `jump_prev` | 跳到上一个请求块 |
| `gd` | `goto_definition` | 跳转到变量定义 |
| `grr` | `goto_references` | 显示变量引用 |
| `]q` | `quickfix_next` | 下一条 quickfix |
| `[q` | `quickfix_prev` | 上一条 quickfix |
| `<leader>rp` | `paste_curl` | 从剪贴板粘贴为 cURL 请求 |
| `<leader>rc` | `copy_as_curl` | 将请求复制为 cURL 命令 |
| `gs` | `toggle_outline` | 切换大纲侧边栏 |
| `<leader>vv` | `pick_env` | 选择环境 |
| `K` | `show_var_value` | 显示变量值 / 响应链 |
| `<leader>l` | `show_history` | 打开请求历史 |
| `g?` | `help` | 打开帮助窗口 |

## 二、HTTP 响应缓冲区 (`http_response`)

| 按键 | 动作 | 说明 |
|------|------|------|
| `q` | `close` | 关闭响应窗口 |
| `B` | `view_body` | 切换到 Body 标签 |
| `R` | `view_request` | 切换到 Request 标签 |
| `E` | `view_verbose` | 切换到 Verbose 标签 |
| `A` | `view_assertions` | 切换到 Assertions 标签 |
| `S` | `view_script_logs` | 切换到 Script Logs 标签 |
| `<Tab>` | `next_tab` | 下一个标签 |
| `<S-Tab>` | `prev_tab` | 上一个标签 |
| `r` | `rerun` | 重新执行当前请求 |
| `]` | `next_response` | 下一条响应（多响应模式）|
| `[` | `prev_response` | 上一条响应（多响应模式）|
| `<leader>j` | `json_filter` | 交互式 jq 过滤器 |
| `<leader>jc` | `json_restore` | 恢复原始 JSON |
| `<leader>jr` | `json_toggle_raw` | 切换 raw/pretty 模式 |
| `<leader>jo` | `json_outline` | JSON 结构大纲 |

## 三、HTTP 请求历史 (`http_history`)

| 按键 | 动作 | 说明 |
|------|------|------|
| `q` | `close` | 关闭历史窗口 |
| `dd` | `delete_entry` | 删除当前条目 |
| `<CR>` | `focus_detail` | 聚焦详情面板 |

## 四、SQL 源文件 (`sql_source`)

| 按键 | 动作 | 说明 |
|------|------|------|
| `<CR>` | `run` | 执行 SQL 语句 |
| `K` | `show_ddl` | 显示 DDL / 列信息 |
| `<leader>ff` | `format` | 格式化 SQL |
| `<leader>cr` | `clear_filter` | 清除过滤 / 搜索 |
| `<leader>db` | `toggle_db_browser` | 切换数据库浏览器 |
| `<C-Space>` | `trigger_completion` | 触发补全 |
| `g?` | `help` | 打开帮助窗口 |

## 五、SQL 数据集缓冲区 (`sql_dataset`)

### 单元格导航

| 按键 | 动作 | 说明 |
|------|------|------|
| `q` | `close` | 关闭数据集窗口 |
| `h` | `move_left` | 左移一格 |
| `j` | `move_down` | 下移一格 |
| `k` | `move_up` | 上移一格 |
| `l` | `move_right` | 右移一格 |
| `H` | `prev_page` | 上一页 |
| `L` | `next_page` | 下一页 |
| `0` | `first_col` | 第一列 |
| `$` | `last_col` | 最后一列 |
| `gg` | `first_row` | 第一行 |
| `G` | `last_row` | 最后一行 |

### 数据操作

| 按键 | 动作 | 说明 |
|------|------|------|
| `K` | `preview_cell` | 预览单元格内容（浮窗）|
| `yy` | `yank_cell` | 复制当前单元格 |
| `yc` | `yank_column` | 复制当前列 |
| `s` | `sort_column` | 按当前列排序 |
| `i` | `edit_cell` | 编辑单元格 |
| `cc` | `edit_cell_replace` | 替换单元格内容 |
| `dd` | `delete_row` | 删除行 |
| `o` | `insert_row` | 插入行 |
| `<leader>w` | `commit_edits` | 提交编辑（生成 DML）|
| `E` | `export` | 导出数据集 |

### 显示选项

| 按键 | 动作 | 说明 |
|------|------|------|
| `zh` | `toggle_cell_highlight` | 切换单元格高亮 |
| `zH` | `toggle_header_float` | 切换悬浮表头 |
| `zN` | `toggle_row_numbers` | 切换行号显示 |
| `<leader>gp` | `toggle_raw_mode` | 切换紧凑模式 |
| `<leader>hh` | `goto_first_page` | 第一页 |
| `<leader>ll` | `goto_last_page` | 最后一页 |
| `<leader>pa` | `toggle_pagination` | 切换分页 |
| `<leader>fc` | `find_column` | 查找列 |
| `<leader>ce` | `filter_by_cell` | 按当前单元格值过滤 |
| `<leader>/` | `show_search` | 在结果中搜索 |
| `<leader>cr` | `clear_filter_search` | 清除过滤 / 搜索 |

### 搜索

| 按键 | 动作 | 说明 |
|------|------|------|
| `n` | `next_search` | 下一个匹配 |
| `N` | `prev_search` | 上一个匹配 |

### 标签页

| 按键 | 动作 | 说明 |
|------|------|------|
| `<Tab>` | `next_tab` | 下一个结果标签 |
| `<S-Tab>` | `prev_tab` | 上一个结果标签 |
| `R` | `rerun` | 重新执行查询 |

## 六、SQL 表操作 (`sql_table_ops`)

| 按键 | 动作 | 说明 |
|------|------|------|
| `ma` | `select_all` | SELECT * |
| `mr` | `refresh_all` | 刷新表列表 |
| `md` | `describe_all` | DESCRIBE 表 |
| `mt` | `toggle_menu` | 切换操作菜单 |

## 七、数据库浏览器 (`sql_db_browser`)

| 按键 | 动作 | 说明 |
|------|------|------|
| `<CR>` | `toggle_node` | 展开/折叠节点 |
| `h` | `move_left` | 折叠/到父节点 |
| `l` | `move_right` | 展开/到第一个子节点 |
| `x` | `context_menu` | 打开右键菜单 |
| `r` | `refresh_node` | 刷新子节点 |
| `/` | `search_filter` | 模糊搜索树 |
| `s` | `select_query` | 生成 SELECT 查询 |
| `d` | `describe_query` | 生成 DESCRIBE 查询 |
| `q` | `close` | 关闭浏览器 |
| `n` | `search_next` | 下一个搜索匹配 |
| `N` | `search_prev` | 上一个搜索匹配 |

## 八、Introspect 浮窗 (`sql_introspect`)

| 按键 | 动作 | 说明 |
|------|------|------|
| `q` | `close` | 关闭浮窗 |
| `<Esc>` | `close_alt` | 关闭浮窗 |

---

## 按键显示规则

UI 标签（winbar）和帮助窗口会根据以下规则显示按键：

| 配置值 | mapleader | 显示 |
|--------|-----------|------|
| `B` | — | `B` |
| `<Tab>` | — | `Tab` |
| `<leader>j` | `\`（默认） | `\j` |
| `<leader>j` | `,` | `,j` |
| `<leader>j` | `<Space>` | `<Space>j` |

---

## 禁用按键

设为 `false` 即可禁用：

```lua
require("poste").setup({
  keymaps = {
    sql_dataset = {
      sort_column = false,   -- 禁用 s 键
      toggle_raw_mode = false,
    },
  },
})
```

禁用后，对应的按键不会注册，UI 标签中也不会显示 `[key]` 提示。

---

## 查看当前按键

在任意源文件中按 `g?` 打开帮助窗口，实时显示所有已配置的按键绑定。

---

## 默认配置完整参考

以下是 `state.lua` 中定义的默认按键配置，可直接作为自定义的起点：

```lua
require("poste").setup({
  keymaps = {
    http_source = {
      run = "<CR>",
      jump_next = "]]",
      jump_prev = "[[",
      goto_definition = "gd",
      goto_references = "grr",
      quickfix_next = "]q",
      quickfix_prev = "[q",
      paste_curl = "<leader>rp",
      copy_as_curl = "<leader>rc",
      toggle_outline = "gs",
      pick_env = "<leader>vv",
      show_var_value = "K",
      show_history = "<leader>l",
      help = "g?",
    },
    http_response = {
      close = "q",
      view_body = "B",
      view_request = "R",
      view_verbose = "E",
      view_assertions = "A",
      view_script_logs = "S",
      next_tab = "<Tab>",
      prev_tab = "<S-Tab>",
      rerun = "r",
      next_response = "]",
      prev_response = "[",
      json_filter = "<leader>j",
      json_restore = "<leader>jc",
      json_toggle_raw = "<leader>jr",
      json_outline = "<leader>jo",
    },
    http_history = {
      close = "q",
      delete_entry = "dd",
      focus_detail = "<CR>",
    },
    sql_source = {
      run = "<CR>",
      show_ddl = "K",
      format = "<leader>ff",
      clear_filter = "<leader>cr",
      toggle_db_browser = "<leader>db",
      trigger_completion = "<C-Space>",
      help = "g?",
    },
    sql_dataset = {
      close = "q",
      move_left = "h",
      move_down = "j",
      move_up = "k",
      move_right = "l",
      prev_page = "H",
      next_page = "L",
      first_col = "0",
      last_col = "$",
      first_row = "gg",
      last_row = "G",
      preview_cell = "K",
      yank_cell = "yy",
      yank_column = "yc",
      sort_column = "s",
      toggle_cell_highlight = "zh",
      toggle_header_float = "zH",
      toggle_row_numbers = "zN",
      toggle_raw_mode = "<leader>gp",
      next_tab = "<Tab>",
      prev_tab = "<S-Tab>",
      rerun = "R",
      goto_first_page = "<leader>hh",
      goto_last_page = "<leader>ll",
      toggle_pagination = "<leader>pa",
      find_column = "<leader>fc",
      filter_by_cell = "<leader>ce",
      show_search = "<leader>/",
      clear_filter_search = "<leader>cr",
      next_search = "n",
      prev_search = "N",
      edit_cell = "i",
      edit_cell_replace = "cc",
      delete_row = "dd",
      insert_row = "o",
      commit_edits = "<leader>w",
      export = "E",
    },
    sql_table_ops = {
      select_all = "ma",
      refresh_all = "mr",
      describe_all = "md",
      toggle_menu = "mt",
    },
    sql_db_browser = {
      toggle_node = "<CR>",
      move_left = "h",
      move_right = "l",
      context_menu = "x",
      refresh_node = "r",
      search_filter = "/",
      select_query = "s",
      describe_query = "d",
      close = "q",
      search_next = "n",
      search_prev = "N",
    },
    sql_introspect = {
      close = "q",
      close_alt = "<Esc>",
    },
    http_history = {
      close = "q",
      delete_entry = "dd",
      focus_detail = "<CR>",
    },
  },
})
```