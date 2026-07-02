# HTTP 文件语法规范

> 单一起源，供 completion、highlight、formatter、Rust CLI、块索引统一参考。

---

## 1. 文档拓扑

```
┌─ 文件级区域（Line 1 .. first `###` - 1）
│  ├─ (# comment)
│  ├─ import <path>
│  ├─ import <path> as <alias>
│  ├─ @var = value                              ← 文件级变量
│  └─ @var = value          （无顺序约束）
│
├─ 请求块 1（Line of `###` .. next `###` - 1）
│  ├─ ### [Request Name]                        ← 块开始标记
│  ├─ ── 块首段（### 与请求行之间，无序）──
│  │  ├─ @var = value                            ← 块级变量
│  │  ├─ @env = envname                          ← 环境覆盖
│  │  ├─ # @prompt varname                       ← 提示变量
│  │  ├─ # @prompt varname [opt1, opt2]
│  │  ├─ # @prompt varname [{{Req.ref}}]
│  │  ├─ < {% code %}                            ← pre-script（单行）
│  │  ├─ < {%
│  │  │     code                                 ← pre-script（多行）
│  │  │  %}
│  │  ├─ < ./path.lua                            ← pre-script（外部）
│  │  └─ # comment
│  │
│  ├─ ── 请求段（有序）──
│  │  ├─ METHOD URL [HTTP/version]               ← 请求行
│  │  ├─ Key: Value                              ← 请求头（0+）
│  │  ├─ （空行）                                  ← headers/body 分隔
│  │  └─ body                                    ← 请求体（text/JSON/form/< path）
│  │
│  ├─ ── 指令段（body 后，post-script 前）──
│  │  └─ run #Name [(@k=v)]
│  │     run #alias.Name [(@k=v)]
│  │     run ./path.http [(@k=v)]
│  │
│  └─ ── 断言段（可选，块尾）──
│     ├─ > {% code %}                            ← post-script（单行）
│     ├─ > {%
│     │     code                                 ← post-script（多行）
│     │  %}
│     ├─ > ./path.lua                            ← post-script（外部）
│     └─ （块尾可有多行空行/注释）
│
├─ 请求块 2（... 同结构）
│  └─ ...
│
└─ 请求块 N
```

---

## 2. 语法元素形式定义

### 2.1 注释 `#`

```
# <任意文本>
```

- 文件任何位置可用，包括文件级、块首段、请求段、断言段
- `# @prompt` 是唯一不影响注释行的特例（见 2.11）
- `--` 注释风格仅 SQL 文件，HTTP 不支持

### 2.2 变量定义 `@var`

```
@<name> = <value>
@<name> <value>
@<name> =>>>
<多行值>
<<<

约束：name = \w[\w_]*
```

**位置规则：**
- `###` 前 → 文件级（文件内所有块可见）
- `###` 后、请求行前 → 块级（当前块可见）
- 一个文件中可有零到多个文件级变量、零到多个块级变量

**优先级规则（高→低）：**

| # | 来源 | 注入时机 |
|---|------|----------|
| 1 | `run (#Name (@k=v))` 行内覆盖 | `import.lua:apply_variable_overrides` |
| 2 | `request.variables.set()` pre-script 注入 | `scripts.lua:inject_pre_script_vars` |
| 3 | 块级 `@var`（用户输入） | 静态写入 |
| 4 | `client.global.set()` 全局变量 | `run.lua:inject_global_vars` |
| 5 | 文件级 `@var` | 静态写入 |
| 6 | `env.json` 当前环境 | 文件读取 |
| 7 | Magic vars: `$timestamp`, `$uuid`, `$date`, `$randomInt` | 运行时生成 |

覆盖机制：Rust 端 HashMap 按注入顺序插入，后写入覆盖先写入。运行时注入的 `@var` 物理上插在 `###` 行之后，因此自动覆盖文件级和 env 变量。

### 2.3 请求块分隔 `###`

```
### [Request Name]
```

- 三个 `#` 开头，后跟可选的请求名称
- 名称：name = trim(first `###` 后文本)，空名称允许
- 文件至少需要一个 `###` 才能执行请求
- 第一个 `###` 之前叫「文件级区域」
- 最后一个 `###` 到文件尾是最后一个请求块

### 2.4 请求行

```
<METHOD> <URL> [HTTP/<version>]
```

- METHOD: `GET | POST | PUT | DELETE | PATCH | HEAD | OPTIONS | TRACE | CONNECT`
- URL: 任意非空字符串，不含空格
- HTTP 版本可选，默认 HTTP/1.1
- 请求行必须在块首段之后、headers 之前
- 请求行不能是 `run` 或 `import` 开头

### 2.5 请求头

```
<Key>: <Value>
```

- `Key: Value` 格式，Key 大小写不敏感
- 推荐首字母大写：`Content-Type`
- Value 可以是纯文本或 `{{}}` 引用
- 多行 header 值不支持
- headers 区域终止于第一个空行

### 2.6 请求体

```
（空行之后的所有行）
```

- headers 和 body 之间必须有一个空行
- 多个空行视为一个分隔
- body 类型由 `Content-Type` header 推断（JSON 高亮、form 处理等）
- body 中支持文件包含语法（2.7）

### 2.7 文件包含 `< path`

```
< /absolute/path/file.txt
< ./relative/path.json
< ~/home/path/data.csv
```

- `<` 后跟空格，再跟文件路径
- 支持绝对路径、`./` 相对路径（相对 .http 文件）、`~/` home 目录
- Content-Type 含 json → 文件内容直接嵌入请求体
- Content-Type 含 multipart/form-data → 作为文件上传
- 文件不存在时保留原始行、报 warning
- **不是** `</path>`（这是旧语法，已废弃）

### 2.8 变量引用 `{{}}`

```
{{name}}
{{$magic}}
{{RequestName.response.body.path}}
```

- `{{` 和 `}}` 包裹
- 变量名：`[\w.]+`（字母数字下划线点号）
- 解析顺序见 2.2 优先级表
- 跨请求引用：`{{名称.response[.body|.headers|.status].路径}}`

**Magic 变量：**

| 名称 | 说明 |
|------|------|
| `$timestamp` | Unix 时间戳 + 随机 6 位数 |
| `$uuid` | 随机 UUID v4 |
| `$date` | 当前日期 YYYY-MM-DD |
| `$randomInt` | 随机 0-9999999 |

### 2.9 Pre-script `< {% %}`

**内联单行：**
```
< {% code %}
```

**内联多行：**
```
< {%
  code
  code
%}
```

**外部：**
```
< ./scripts/preprocess.lua
```

- `<` 必须在行首（可有前导空格）
- `{% %}` 包裹 Lua 代码
- 外部脚本以 `./` 或 `../` 开头、`.lua` 结尾
- 出现在块首段（`###` 与请求行之间），与 `@var` 无序

**可用脚本 API：**

| API | 说明 |
|-----|------|
| `request.variables.set(name, value)` | 设置块级变量 |
| `request.variables.get(name)` | 读取块级变量 |
| `request.headers` | 操作请求头 |
| `request.body` | 读取/修改请求体 |
| `client.log(msg)` | 日志输出 |
| `client.global.set(name, value)` | 持久全局变量（跨请求） |
| `client.global.get(name)` | 读取持久全局变量 |
| `variables.*` | 读取当前所有 @var（文件级+块级） |
| `env.*` | 读取当前 env.json 配置 |

### 2.10 Post-script / Assertion `> {% %}`

**内联单行：**
```
> {% code %}
```

**内联多行：**
```
> {%
  code
%}
```

**外部：**
```
> ./scripts/validate.lua
```

- `>` 必须在行首（可有前导空格）
- 仅出现在块尾（body/run 之后）
- 一个块可有零个或一个 post-script

**可用断言 API：**

| API | 说明 |
|-----|------|
| `response.status` | HTTP 状态码 |
| `response.body` | 响应体（JSON 自动解析） |
| `response.headers` | 响应头（key → value） |
| `response.content_type` | Content-Type 值 |
| `response.latency_ms` | 响应时间 ms |
| `response.url` | 最终 URL（重定向后） |
| `client.test(name, fn)` | 定义测试块 |
| `client.assert(cond, msg)` | 断言（假则抛错） |
| `client.log(msg)` | 日志输出 |
| `client.global.set/get` | 持久全局变量 |
| `variables.*` | 读取 @var |
| `env.*` | 读取 env.json |

### 2.11 Prompt 提示变量 `# @prompt`

```
# @prompt <name>                      → 文本输入
# @prompt <name> [opt1, opt2, ...]    → 静态选择
# @prompt <name> [{{Req.res.body.x}}] → 动态选择（跨请求引用）
```

- `# @prompt` 是唯一在补全层面特化的注释类型
- 仅出现在 `###` 块内、请求行之前
- 执行时提示用户输入/选择，生成 `@name = value` 行注入块中
- `@prompt` 行本身在发送给 Rust 前会被 `strip_prompt_lines` 移除
- 多选项使用 `poste_select.select` 异步弹出选择器
- 动态选项需要先执行依赖请求

**解析流程（`request_vars.lua:handle_prompt_variables`）：**
1. 扫描当前 `###` 块内所有行
2. 匹配 `# @prompt varname` 或 `# @prompt varname [...]`
3. 如果是动态选项，异步执行依赖请求获取选项列表
4. 用户选择/输入后，替换 `# @prompt` 行为 `@varname = value`
5. 最终 `@varname = value` 作为块级 `@var` 参与变量解析

### 2.12 Import / Run 引用

**Import（文件级，仅 `###` 前）：**

```
import ./auth.http
import ./orders.http as orders
```

**Run（块级，`###` 块内 body 区域）：**

```
run #Login
run #orders.ListOrders
run #orders.ListOrders (@status=pending)
run ./batch.http
run ./batch.http (@env=staging)
```

**Import 规则：**
- `import <path>` 将目标文件中所有命名请求导入
- `import <path> as <alias>` 带命名空间隔离
- 别名必须唯一（重复 → 报错）
- 别名命名：`\w[\w_]*`
- 无别名 import 之间同名请求：后面覆盖前面（warning）
- 嵌套支持：被 import 的文件也可 import 其他文件

**Run 规则：**
- `run #Name` — 从无别名 import 中查找
- `run #alias.Name` — 从别名命名空间查找
- `run ./path` — 执行目标文件所有请求
- `(@k=v, ...)` — 运行时变量覆盖，最高优先级
- `run` 指令所在 `###` 块可附带 post-script/assertion
- 变量覆盖只作用于本次执行，不修改原始文件

**Import 定位（`import.lua:resolve_run_at_cursor`）：**
- `run` 行必须在一个 `###` 块内
- 从光标行向上找最近的 `###`
- 在该块内向前扫描第一个 `run` 行
- 如果没有 `###`，从文件头开始扫描

### 2.13 `@env` 环境覆盖

```
@env = production
```

- 块级变量，出现在 `###` 和请求行之间
- 覆盖当前选中的环境（`state.current_env`）
- 未指定时使用 `state.current_env` 或 `state.config.default_env`
- **实现状态：** Parser ❌, Completion ❌, Highlight ❌

---

## 3. 块内节顺序规则

块内元素有固定的**区域**，但块首段内无序：

```
### Name
│
├─ 块首段（### 行本身 + 下方行直到请求行）
│  无序区域，可任意混合：
│    • @var, @env
│    • < {% pre-script %} / < ./script.lua
│    • # @prompt
│    • # comment
│  （终止于第一个非 @ / < / # / 空行的行）
│
├─ 请求行（必须是大写 HTTP 方法 + URL）
├─ 请求头（Key: Value，零行或多行）
├─ 空行
├─ 请求体（任意内容，含 run 指令）
├─ （空行/注释）
└─ 断言段（0 或 1 个 > {% %} / > ./script.lua）
```

**终止条件：**
- 块首段终止于第一个不符合 `@` / `<` / `#` / 空行的行
- 断言段由行首 `>` 识别，且只能出现在 `###` 块的最后

---

## 4. 解析优先级

### 变量解析（高→低）

```
  1. run 行内 (@k=v) 覆盖
  2. request.variables.set() pre-script 注入
  3. 块级 @var（用户写入）
  4. client.global.set() 全局变量
  5. 文件级 @var
  6. env.json（当前环境）
  7. Magic variables（$timestamp, $uuid, ...）
```

### 请求块定位

```
光标行 → 向上查找最近的 ### → 该 ### 到下一个 ### 或 EOF
```

---

## 5. 实现状态

| 语法 | Parser (Rust) | Completion (Lua) | Highlight (Lua) |
|------|:---:|:---:|:---:|
| `#` 注释 | ✅ skip | — | ❌ |
| `@var =` | ✅ | ✅ | ❌ |
| `@var =>>> ... <<<` | ✅ | ❌ | ❌ |
| `###` 分隔 | ✅ | ✅ | ❌ |
| `METHOD URL` | ✅ | ✅ | ❌ |
| `Key: Value` header | ✅ | ✅ | ❌ |
| 空行分隔 | ✅ | ✅ | ❌ |
| 请求体 | ✅ | — | ❌ |
| `< path` 文件包含 | ✅ Lua | — | ✅ extmark |
| `{{var}}` 引用 | ✅ | ✅ | ❌ |
| `{{$magic}}` | ❌ 待实现 | ✅ | ❌ |
| `< {% %} ` pre-script | ✅ skip | ✅ | ❌ |
| `< ./path.lua` ext script | ✅ skip | ❌ | ❌ |
| `> {% %} ` post-script | ✅ skip | ✅ | ❌ |
| `> ./path.lua` ext script | ❌ skip | ❌ | ❌ |
| `# @prompt` | — 仅 Lua 处理 | ❌ 仅 Lua 处理 | ❌ |
| `import` / `run` | ❌ | ❌ 仅 Lua 处理 | ❌ |
| `@env` 环境覆盖 | ❌ | ❌ | ❌ |
| `run (@k=v)` 行内变量 | ❌ | ❌ | ❌ |
