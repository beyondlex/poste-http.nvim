# Poste HTTP 文件语法规范

> 本文档定义 `.http` / `.rest` 文件所有支持的语法元素，
> 供 completion、highlight、formatter、Rust CLI 解析器统一参考。

## 1. 文件结构

```
┌─ import / run 引用（文件级，在第一个 ### 之前）
│
├─ @variable 定义（文件级，在第一个 ### 之前）
│
├─ ### 请求块 1
│   │
│   ├─ < {% pre-script %}
│   ├─ @variable 定义（块级）
│   ├─ 请求行（METHOD URL）
│   ├─ 请求头
│   ├─ 空行
│   ├─ 请求体
│   └─ > {% assertion %}
│
├─ ### 请求块 2
│   └─ ...
│
├─ import / run 引用（块间，与 `###` 同层）
│
└─ ### 请求块 N
```

## 2. 语法元素

### 2.1 注释

```
# 井号注释
```

- 文件任何位置均可使用
- `--` 注释风格（SQL 风格）不支持在 HTTP 文件中使用

### 2.2 变量定义

**文件级变量**（在第一个 `###` 之前出现）：

```
@base_url = https://api.example.com
@token = eyJhbGciOiJIUzI1NiI
```

**块级变量**（在 `###` 和请求行之间出现）：

```
### Get users
@page_size = 20
GET {{base_url}}/users?limit={{page_size}}
```

**多行变量**（`=>>> ... <<<`）：

```
@payload =>>>
{
  "name": "test",
  "value": 123
}
<<<
```

**规则**：
- 变量名：`@` 开头，后跟 `\w+`（字母数字下划线）
- 等号前后可有空格
- 值可以是空字符串
- 块级变量覆盖文件级同名变量

### 2.3 请求块分隔

```
### Get all users
```

- 三个 `#` 开头
- 后跟可选的请求名称
- `###` 前应有一个空行（格式化规则）
- 文件末尾不需要尾随 `###`

### 2.4 请求行

```
GET {{base_url}}/users
POST https://api.example.com/data HTTP/1.1
PUT http://localhost:8080/api/items/1
```

**格式**：

```
<METHOD> <URL> [HTTP/<version>]
```

**支持的 METHOD**（来自 `completion.lua`）：

```
GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, TRACE, CONNECT
```

**规则**：
- METHOD 大写
- 支持完整 URL 和相对路径（配合 `@base_url`）
- HTTP 版本可选，默认为 `HTTP/1.1`

### 2.5 请求头

```
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json
X-Custom-Header: value
```

**规则**：
- `Key: Value` 格式
- key 大小写不敏感（推荐首字母大写：`Content-Type`）
- 值可以是纯文本或 `{{}}` 引用
- 多行 header 值不支持（当前限制）

### 2.6 空行分隔

```
POST /api/data
Content-Type: application/json
                                   ← 空行：headers 结束，body 开始
{
  "name": "test"
}
```

- headers 和 body 之间需要一个空行
- 多个空行被视为一个

### 2.7 请求体

```
POST /api/data
Content-Type: application/json

{
  "name": "test",
  "value": 123
}
```

**支持的类型**：
- 纯文本
- JSON（Content-Type 含 `json` 时语法高亮）
- URL-encoded form data（`key=value&key2=value2`）
- `multipart/form-data`（通过 `request_vars.lua`）

**文件内容包含/上传语法**（统一使用 `< path` 格式）：

```
POST /api/upload
Content-Type: multipart/form-data; boundary=----boundary

< /path/to/file.txt
```

```
POST /api/data
Content-Type: application/json

< /path/to/payload.json
```

**规则**：
- `<` 后跟一个空格，然后是文件路径
- 路径支持绝对路径、`./` 相对路径、`~/` home 目录
- **Content-Type 含 `json`**：文件内容直接嵌入请求体（替换 `< path` 行）
- **Content-Type 含 `multipart/form-data`**：作为文件上传处理
- 文件不存在时保留原始行，报 warning
- 此语法**不**是 `</path>`（无空格、有 `>` 结尾）— 那是旧设计，已废弃

### 2.8 变量引用

```
{{base_url}}
{{token}}
{{$uuid}}
{{login.response.body.token}}
```

**规则**：
- `{{` 和 `}}` 包裹
- 变量名允许字母、数字、点号
- 解析顺序：请求块变量 → 文件变量 → env.json → magic var

**Magic variables**：

| 名称 | 说明 |
|---|---|
| `{{$timestamp}}` | 当前 Unix 时间戳 + 随机数 |
| `{{$uuid}}` | 随机 UUID v4 |
| `{{$date}}` | 当前日期 YYYY-MM-DD |
| `{{$randomInt}}` | 随机 0-9999999 |

**跨请求引用**：

```
{{request_name.response.body.path.to.value}}
{{login.response.body.token}}
```

- 引用之前执行过的请求的响应内容
- 格式：`{{请求名.response[.body\|.headers\|.status].路径}}`

### 2.9 Pre-request Script

```
< {%
  request.variables.set("key", JSON.stringify(request.body));
  client.log("Pre-processing done");
%}
```

**单行格式**：

```
< {% client.log("pre-flight"); %}
```

**外部脚本引用**：

```
< ./scripts/preprocess.lua
< ../shared/auth.lua
```

**规则**：
- `<` 开头（必须在行首）
- `{% %}` 包裹 JS/Lua 代码
- 多行 `{%` 单独一行，`%}` 单独一行
- 外部脚本路径以 `./` 或 `../` 开头，`.lua` 结尾

**可用 API**：

```
request.variables      — 操作请求变量
request.headers        — 操作请求头
request.body           — 读取/修改请求体
client.log(msg)        — 日志输出
client.global.set(key, value)  — 全局变量（跨请求）
client.global.get(key)
variables.*                — 读取 @variable 定义（文件级 + 块级，块级覆盖文件级，尚未实现）
env.*                      — 读取当前 env.json 配置（尚未实现）
```

### 2.10 Post-request Assertion

```
> {%
  client.test("Status is 200", function() {
    client.assert(response.status == 200, "Expected 200");
  });
%}
```

**单行格式**：

```
> {% client.assert(response.status == 200); %}
```

**外部脚本引用**：

```
> ./scripts/validate.lua
```

**规则**：
- `>` 开头（必须在行首）
- `{% %}` 包裹 JS/Lua 代码
- 多行 `{%` 单独一行，`%}` 单独一行
- 外部脚本路径以 `./` 或 `../` 开头，`.lua` 结尾

**可用 API**：

```
response.status        — HTTP 状态码
response.body          — 响应体字符串
response.headers       — 响应头
response.latency       — 响应时间（ms）
client.test(name, fn)  — 测试用例
client.assert(cond, msg)  — 断言
client.log(msg)        — 日志输出
variables.*            — 读取 @variable 定义（文件级 + 块级，块级覆盖文件级，尚未实现）
env.*                  — 读取当前 env.json 配置（尚未实现）
```

### 2.11 环境切换

```
### request name
@env = production
GET https://prod.example.com/api
```

**规则**：
- `@env` 作为块级变量，放在 `###` 和请求行之间
- 覆盖当前选中的环境
- 未指定时使用 `state.current_env`
- 当前尚未实现

### 2.12 变量提示

```
# @prompt username
# @prompt role [admin, user, guest]
# @prompt item [{{listItems.response.body.items}}]
```

**规则**：
- `# @prompt` 后跟变量名，在请求执行时弹出输入框让用户输入值
- 支持方括号 `[]` 提供选项列表，用户通过选择器选取
- 选项列表可引用其他请求的响应：`[{{ReqName.response.body.field}}]`
- 提示变量解析为 `@varname = value` 注入到请求块中

**实现状态**：Completion (Lua) ❌，Highlight ❌

### 2.13 文件引用（import / run）

兼容 [kulala](https://kulala.app/usage/import-and-run) 的 `import` 和 `run` 机制，
用于跨文件复用请求。

**语法格式**：

```
import ./auth.http
import ./orders.http as orders

### Get users
GET https://api.example.com/users

run #Login                       ← 无别名：从所有无别名 import 中查找

run #orders.ListOrders           ← 有别名：只从 orders 别名中查找

run #orders.ListOrders (@status=pending)

run ./batch.http (@env=staging)

run ./batch.http
```

**规则**：

**import 基础**
- `import <path>` — 将目标文件中的所有命名请求导入当前文件
- 多个 import 可引用同路径，各自独立解析
- 支持嵌套：被 import 的文件自身也可以 import 其他文件

**import as 别名（扩展语法）**
- `import <path> as <alias>` — 带别名的导入，命名空间隔离
- 别名必须唯一：同一文件中 `import ./a as ns` 后再 `import ./b as ns` → 报错
- 别名命名规则：`\w[\w_]*`（同 `@variable`）

**别名访问语法**
- `#alias.RequestName` — 访问别名命名空间下的请求
- 分隔符使用 `.`，与跨请求引用 `{{Name.res.body.x}}` 一致

**别名与裸名混用规则**
- 混用时，裸名 `#Login` 只查找无别名 import 的请求
- 有别名 import 的请求只能通过 `#alias.RequestName` 访问
- 无别名 import 之间有同名请求 → 后面覆盖前面，报 warning

**run 执行**
- `run <path>` — 运行目标文件中的所有请求
- `run #Name` — 运行已导入的指定命名请求
- `run #alias.Name` — 运行别名命名空间下的指定请求
- `run #Name (@var=value, ...)` — 运行时覆盖变量
- `run` 支持后置脚本/断言 (`> {% ... %}`)，与普通请求块规则一致
- 变量覆盖只作用于本次执行，不修改原始请求

**变量 / 指令传播**
- 导入的文件级 `@var` 合并到当前文件的共享作用域（同 kulala）
- 变量覆盖优先级：`run` 行内 `@var` > 块级 `@var` > 文件级 `@var`
- 文件级 compat 指令（`# @kulala-*`）传播到被 import 的块

**实现状态**：全部未实现

## 3. 优先级 / 解析顺序

```
变量解析优先级（高 → 低）：
  1. 块级 @variable
  2. 文件级 @variable
  3. env.json（根据当前环境）
  4. Magic variables（$timestamp, $uuid...）
  5. 跨请求响应引用

请求块定位（运行时）：
  1. 从光标行向前查找最近的 ###
  2. 以此 ### 到下一个 ### 之间为当前请求块
```

## 4. 与标准 HTTP 的差异

| 标准 HTTP | Poste HTTP |
|---|---|
| 只有请求报文 | 使用 `###` 支持多个请求在同一个文件中 |
| 无变量 | `{{}}` 引用 + `@variable` 定义 |
| 无脚本 | `< {% %}` pre-script + `> {% %}` assertion |
| 无注释 | 支持 `#` 注释 |
| 无跨请求 | `{{req.response.body.x}}` |
| `Content-Type` 决定 body 格式 | 通过 Content-Type 推断 + magic 变量 |
| 单文件 | `import` / `run` 跨文件引用（兼容 kulala） |

## 5. 实现状态检查清单

| 语法 | Parser (Rust) | Completion (Lua) | Highlight (Lua) | Format (todo) |
|---|---|---|---|---|---|
| `#` 注释 | ✅ 跳过 | — | ❌ | — |
| `@variable` 定义 | ✅ | ✅ | ❌ | ✅ todo |
| `@xxx =>>> ... <<<` | ✅ | ❌ | ❌ | ❌ |
| `###` 分隔 | ✅ | ✅ | ❌ | ✅ todo |
| `@env` 块级变量 | ❌ | ❌ | ❌ | ✅ todo |
| `METHOD URL` | ✅ | ✅ | ❌ | — |
| `Key: Value` 头 | ✅ | ✅ | ❌ | ✅ todo |
| 空行分隔 | ✅ | ✅ | — | ✅ todo |
| 请求体 | ✅ | — | ❌ | ✅ todo |
| `< path` 文件包含/上传 | ✅ Lua | — | ✅ `PosteFileUpload` | ✅ todo |
| `{{var}}` 引用 | ✅ | ✅ | ❌ | — |
| `{{$magic}}` | ❌ Rust 端 | ✅ | ❌ | — |
| `< {% %} ` | ✅ 跳过 | ✅ | ❌ | ✅ todo |
| `< ./path.lua` | ✅ 跳过 | ❌ | ❌ | — |
| `> {% %} ` | ✅ 跳过 | ✅ | ❌ | ✅ todo |
| `> ./path.lua` | ❌ 跳过 | ❌ | ❌ | — |
| `# @prompt` 变量提示 | — | ❌ | ❌ | — |
| `import` / `run` 文件引用 | ❌ | ❌ | ❌ | ❌ |
