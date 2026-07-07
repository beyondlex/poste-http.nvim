要把 JetBrains Database 插件（DataGrip）那种极其强大的 Data Editor 搬到 Neovim，并且做到极致的 **“Vim 核心党 / 纯键盘党 (No-Mouse)”** 人体工学，关键在于**抛弃 GUI 的“点击与弹窗”逻辑，将其完全映射为 Vim 的 Buffer、Window、Mode 和 Motion。**

DataGrip 的核心痛点是：结果集是一个二维 Grid，普通的终端很难优雅地处理单元格编辑、长文本查看、多表关联跳转。

以下是为 Neovim 量身定制的 UI 与交互设计方案：

---

## 1. 核心 UI 布局：双 Window / Buffer 架构

不要尝试用浮动弹窗（Floating Window）来做长期的结果展示，浮动窗会遮挡 SQL 源码。推荐使用 **分屏 Buffer (Split Window)**。

```
+-------------------------------------------------------------+
|  1 SELECT * FROM users WHERE status = 'active';             |
|  2                                                          |
|  [SQL Source Buffer] (Normal / Insert Mode)                 |
+-------------------------------------------------------------+
|  id  | username [↓] | email                | created_at     |
|  1   | alice        | alice@example.com    | 2026-06-01     |
|  2   | bob          | bob@example.com      | 2026-06-02     |
|                                                             |
|  [SQL Result Buffer] (Table Mode / Custom Normal Mode)      |
+-------------------------------------------------------------+
| [Status] 2 rows | Conn: Production | Master * [Log] SUCCESS|
+-------------------------------------------------------------+

```

### 结果集 Buffer 的特性：

* **Filetype:** `dbout` 或 `dbresult`。
* **Modifiable:** 默认 `nomodifiable`（只读），只有进入特定“编辑模式”时才允许修改。
* **Virtual Text & Conceal:** * 使用 `conceal` 隐藏表格的分隔符（如 `|`），换成更美观的表头边框。
* 对于 `NULL` 值，使用 Virtual Text 灰色高亮显示 `NULL`。



---

## 2. 交互设计：把 Grid 变成一个大文本

Vim 党最恨记复杂的全新快捷键。最符合人体工学的做法是：**让结果集完美契合 Vim 原生的 Motion（移动）和 Operator（操作）。**

### 2.1 基础移动 (Motion)

在结果集 Buffer 中，一个“单元格 (Cell)”就是最小的移动单位。

* `h` / `l`：在左右单元格之间跳转（而不是按字符移动）。
* `j` / `k`：在上下行之间跳转。
* `0` / `$`：直接跳转到当前行的第一列 / 最后一列。
* `ctrl-f` / `ctrl-b`：翻页。
* **表头跳转:** `H` 跳转到当前列的表头（可以看字段类型）。

### 2.2 查看长文本/JSON (View Data)

数据库里经常有超长的 JSON 或 Text，在 Grid 里显示不全。

* **交互:** 在目标单元格上按 `K` (Vim 原生用于 Hover/Documentation)。
* **行为:** 弹出一个 Floating Window，里面是一个临时的 Buffer，并且自动根据内容设置 `filetype=json` 或 `filetype=sql`。你可以用 `G`、`gg` 在浮动窗里高亮浏览，按 `q` 或 `<Esc>` 退出。

---

## 3. 核心突破：极简的“数据编辑”流 (Data Modification)

DataGrip 的双击编辑对 Vim 党是灾难。我们需要利用 Vim 的 **Insert Mode** 和 **Undo Tree**。

### 3.1 单元格编辑 (Cell Editing)

* **修改:** 在单元格上按 `i` 或 `a` 或 `cc`。
* **触发:** 瞬间弹出一个单行的浮动输入框（Floating Input），自动继承原值。
* **完成:** 输入完毕后按 `<Esc>` 或 `<CR>`，浮动框关闭，虚拟文本或 Buffer 内容更新，并将该单元格高亮（标记为 Modified）。


* **删除行:** 在目标行按 `dd`。该行不会消失，而是被加上删除线高亮（标记为 Deleted）。
* **新增行:** 按 `o` 或 `O`。在下方/上方插入一条空记录，主键若自增则显示为 Virtual Text `[Auto]`。

### 3.2 暂存与提交 (Commit / Rollback)

就像 DataGrip 有个 Local Changes 缓存区一样，Neovim 插件也应该先缓存修改：

* 所有被修改的单元格变黄，删除的行变红，新增的行变绿。
* `u` (Undo)：直接撤销上一次的单元格修改（利用 Vim 原生 Undo，或者插件自己挂钩子）。
* **提交更改:** 在结果集 Buffer 按 `:W` 或 `<leader>dbw`（Write）。插件自动对比差异，生成 `UPDATE/INSERT/DELETE` 语句并在后台执行。
* **放弃更改:** 按 `R` 或 `:e!`，重新从数据库拉取数据刷新。

---

## 4. 高级进阶：Vim 党的独享丝滑功能

### 4.1 字段过滤与排序 (Filter & Sort)

不要弹窗输入过滤条件，直接在表头操作。

* 将光标移动到某列的**表头**：
* 按 `s`：弹出菜单选择 `Ascending` / `Descending` / `Clear Sort`。
* 按 `f`：在底部命令行拉起一个 `:DbFilter [列名] = `，让你直接输入过滤条件。



### 4.2 快捷列复制 (Yank Matrix)

* **Yank 单元格:** 在单元格上按 `yy`，直接把这个值丢进 Vim 的 `"` 寄存器。
* **Yank 整列:** 很多时候我们需要把一整列的 ID 复制出来拼成 `IN (...)`。
* 交互：在列上按 `<leader>yc` (Yank Column)，自动把该列所有数据用逗号隔开复制到剪贴板。



### 4.3 关系型跳转 (Go to Definition / Reference)

DataGrip 的外键跳转（Go to Related Data）非常好用。

* **交互:** 在带有外键的单元格上按 `gd` (Go to Definition)。
* **行为:** 插件自动解析外键关系，在下方开一个新 Split，自动执行 `SELECT * FROM target_table WHERE id = [当前值]`。

---

## 5. 总结：快捷键映射推荐表 (Cheat Sheet)

为了达成最佳人体工学，建议将结果集 Buffer 强制绑定以下快捷键：

| 快捷键 | Mode | 对应 DataGrip 动作 | Vim 哲学解释 |
| --- | --- | --- | --- |
| `h/j/k/l` | Normal | 切换选中的单元格 | 原生方向移动 |
| `i` / `cc` | Normal | 双击单元格进入编辑 | 进入编辑模式 |
| `K` | Normal | 最大化查看单元格 (Maximize Cell) | 查看 Hover 详情 |
| `dd` | Normal | 删除当前行 (Delete Row) | 剪切/删除行 |
| `o` | Normal | 添加新行 (Add New Row) | 下方开辟新行 |
| `yy` | Normal | 复制单元格内容 | 复制 (Yank) |
| `<leader>w` | Normal | Submit Changes (DB 提交) | 保存 (Write) |
| `R` | Normal | Refresh Data (刷新) | 重新加载 (Reload) |
| `/` | Normal | 结果集内局部搜索 | 原生搜索（高亮匹配格子） |

通过这种设计，一个熟练的 Vim 用户甚至不需要学习新插件，仅凭**直觉**（想改就按 `i`，想删就按 `dd`，想看大图就按 `K`，想保存就按 `:w`）就能像玩转文本一样玩转数据库结果集。
