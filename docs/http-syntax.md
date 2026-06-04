## 当前已实现的 HTTP 文件语法总结

### 1. 请求结构

| 语法                    | 说明                           | 示例                                     |
| ----------------------- | ------------------------------ | ---------------------------------------- |
| `###`                   | 请求分隔符，分隔多个请求块     | `###`                                    |
| `### Name`              | 带名称的请求，可用于跨请求引用 | `### Login`                              |
| `METHOD URL [HTTP/ver]` | 标准 HTTP 请求行               | `POST https://httpbin.org/post HTTP/1.1` |
| `Key: Value`            | 请求头（请求行后、空行前）     | `Content-Type: application/json`         |
| (空行后内容)            | 请求体                         | `{"key": "value"}`                       |

### 2. 注释

| 语法     | 说明         |
| -------- | ------------ |
| `# ...`  | Hash 注释    |
| `-- ...` | SQL 风格注释 |

### 3. 变量系统

| 语法            | 说明                                                 |
| --------------- | ---------------------------------------------------- |
| `@name = value` | 文件级变量（`###` 之前定义，全局可用）               |
| `@name = value` | 请求级变量（`###` 块内定义，仅块内可用，优先级更高） |
| `@name=value`   | 紧凑写法（无空格）                                   |
| `@name value`   | 空格分隔写法（`=` 可省略）                           |
| `{{var_name}}`  | 变量替换                                             |

**变量优先级**：请求级 > 文件级 > env.json 环境变量

### 4. 交互式 Prompt（Lua 侧）

| 语法                                   | 说明                                                   |
| -------------------------------------- | ------------------------------------------------------ |
| `# @prompt varname`                    | 文本输入弹窗                                           |
| `# @prompt varname [opt1, opt2, opt3]` | 选择列表（≤10 项用 `inputlist`，>10 项用浮动搜索窗口） |
| 多个 `# @prompt` 行                    | 按顺序依次弹出                                         |

### 5. 跨请求引用

| 语法                                   | 说明                                                   |
| -------------------------------------- | ------------------------------------------------------ |
| `{{ReqName.response.body.field.path}}` | 引用其他请求的响应体字段（点号路径，自动执行依赖请求） |
| `{{ReqName.response.body.arr[0]}}`     | 数组索引访问                                           |
| `{{ReqName.response.body}}`            | 引用整个响应体                                         |
| `{{ReqName.response.headers.Name}}`    | 引用响应头（大小写不敏感）                             |
| `{{ReqName.request.body.field}}`       | 引用请求体字段                                         |
| `{{ReqName.request.headers.Name}}`     | 引用请求头                                             |

支持链式引用：C → B → A 自动解析并缓存。

### 6. 连接指令（非 HTTP 协议）

| 语法                                | 说明                                      |
| ----------------------------------- | ----------------------------------------- |
| `# @connection redis://host:port`   | Hash 注释风格                             |
| `-- @connection postgres://host/db` | SQL 注释风格                              |
| `# @connection {{host}}:{{port}}`   | 支持变量替换                              |
| 文件级 → 块级回退                   | 块内无 `@connection` 时自动使用文件级定义 |

### 7. 特殊变量 & 文件包含

| 语法                      | 说明                             |
| ------------------------- | -------------------------------- |
| `{{$timestamp}}`          | 魔术变量，替换为唯一时间戳       |
| `< /path/to/file`         | 文件包含（读取文件内容替换该行） |
| `< ~/Pictures/avatar.png` | 支持 tilde 展开                  |

### 8. 协议检测

基于文件扩展名自动识别：

| 扩展名            | 协议       |
| ----------------- | ---------- |
| `.http` / `.rest` | HTTP       |
| `.redis`          | Redis      |
| `.sql`            | PostgreSQL |
| `.mysql`          | MySQL      |
| `.mongo`          | MongoDB    |
| `.amqp`           | AMQP       |

### 9. 其他

- **Cookie 自动管理**：通过 curl cookie jar (`~/.cache/poste/cookies.txt`) 自动处理，无需语法
- **env.json 环境变量**：支持多环境（`dev`/`prod` 等），从文件目录向上查找 `env.json`

### 尚未实现（ROADMAP）

- `@protocol` 指令
- 测试断言 (`> {% assert ... %}`)
- Pre/post 请求脚本
- `{{$guid}}` 等其他魔术变量
- PostgreSQL / MySQL / MongoDB / AMQP 实际执行（目前仅为 stub）


---- 


所有 5 个任务已完成。以下是变更摘要：

### 新增文件

| 文件                      | 说明                                            |
| ------------------------- | ----------------------------------------------- |
| `syntax/poste_http.vim`   | 核心语法文件，定义 19 个高亮组的 Vim regex 模式 |
| `ftplugin/poste_http.vim` | filetype 配置（commentstring、comments）        |

### 修改文件

| 文件                       | 变更                                                                                    |
| -------------------------- | --------------------------------------------------------------------------------------- |
| `ftdetect/poste.vim`       | `.http`/`.rest` → `poste_http`，`.redis` → `poste_redis`                                |
| `lua/poste/highlights.lua` | `M.setup()` 中新增 14 个语法高亮组的 link 定义，仅在用户未自定义时生效                  |
| `lua/poste/init.lua`       | autocmd 和 already-open buffers 中 filetype 按扩展名分别设置 `poste_http`/`poste_redis` |

### 覆盖的语法元素（14 种）

| 语法元素                           | 高亮组                               | 示例                         |
| ---------------------------------- | ------------------------------------ | ---------------------------- |
| `###` 分隔线 + 请求名              | `Delimiter` / `Title`                | `### Get Users`              |
| `@name = value` 变量定义           | `Identifier` / `Operator` / `String` | `@host = https://...`        |
| `{{variable}}` 变量引用            | `Identifier`                         | `{{user_id}}`                |
| `{{$uuid}}` 魔法变量               | `Special`                            | `{{$timestamp}}`             |
| `GET`/`POST` 等 HTTP 方法          | `Keyword`                            | `GET`                        |
| URL 路径                           | `Underlined`                         | `https://...`                |
| `HTTP/1.1` 版本                    | `Constant`                           | `HTTP/1.1`                   |
| `Key:` Header 键                   | `Type`                               | `Content-Type`               |
| `# @prompt` / `# @connection` 指令 | `PreProc`                            | `# @connection redis://...`  |
| `< {% ... %}` 前置脚本             | `PreProc`                            | `< {% client.log(...) %}`    |
| `> {% ... %}` 后置脚本/断言        | `PreProc`                            | `> {% client.assert(...) %}` |
| `{%` / `%}` 脚本标记               | `Special`                            | `{%` 和 `%}`                 |
| `< ./script.lua` 外部脚本引用      | `Include`                            | `< ./scripts/gen.lua`        |
| `< /path/to/file` 文件包含         | `Include`                            | `< /path/to/file`            |

### 已知局限

- **Header vs Body 歧义**：JSON body 中的 `"key":` 可能被误匹配为 Header（因 JSON key 带引号 `"key":`，而 Header 无引号，实际影响很小）
- **脚本块内不高亮 Lua 语法**：`< {% ... %}` 内部整体着 PreProc 色，不做 Lua 语法嵌入

可以在 Neovim 中打开 `examples/api.http` 验证效果。
