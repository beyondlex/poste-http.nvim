# Poste HTTP Formatter 设计

## 1. 背景

`.http` / `.rest` 文件包含混合内容：`###` 请求块、`@variable` 定义、HTTP 请求行、headers、JSON 请求体、`< {% %}` pre-script、`> {% %}` assertion。没有现成的 formatter 能理解这种混合格式。

语法规范见 `docs/http-syntax.md`。实施计划见 `docs/http-impl-guide.md`。

当前大量语法元素的实现尚未完成（详见 `docs/http-syntax.md#5`），立即做 formatter 会导致反复重写。必须先完成 `docs/http-impl-guide.md#Phase-0` 的全部前提条件。

## 2. 架构选择：Rust `poste fmt`

**不采用 Lua 实现**（否决 `docs/http-format-design.md` 旧方案）。

### 理由

| 维度 | Rust `poste fmt` | Lua 纯实现 |
|---|---|---|
| 复用现有基础设施 | ✅ `poste-core` token/region 能力 | ❌ 需重写解析 |
| CI / pre-commit | ✅ `poste fmt --check` | ❌ 依赖 Neovim |
| 跨编辑器 | ✅ Helix, VS Code 等都能用 | ❌ 锁死 Neovim |
| conform 集成 | ✅ `format_command` | ✅ 也行 |
| 维护 | 一份解析逻辑 | 两份（Rust parser + Lua formatter）|

用户已有 Rust binary（`poste run` 必须编译），`poste fmt` 只是加一个 subcommand，零额外安装。

### 整体架构

```
poste fmt [--check] [--stdin] [file...]
```

流程：

```
Input (.http text)
    ↓
Tokenizer ──→ Region list (无损, 保留注释/空白/script 原内容)
    ↓
Formatter  ──→ 按 region 类型应用规则
    ↓
Output (.http text)
```

Tokenizer vs Parser：

| | `parser.rs` (现有) | Tokenizer (新) |
|---|---|---|
| 目标 | 提取 `Request` 结构体 | 标注所有 region 边界 |
| 是否保留空白 | ❌ 合并 | ✅ 原样保留 |
| 是否处理 script | ❌ 剥离 | ✅ 标注为 PreScript/PostScript region |
| 文件包含 | ❌ 不处理 | ✅ 标注 FileInclude region |
| 输出 | `Request { name, body }` | `Vec<Region>` |

### Region 类型

```rust
enum Region {
    /// ### Request Name 行
    Separator(String),
    /// # 注释行
    Comment(String),
    /// @var = value 定义（文件级或块级）
    VarDef { name: String, value: String, raw: String },
    /// METHOD URL [HTTP/version]
    RequestLine { method: String, url: String, version: Option<String>, raw: String },
    /// Key: Value 请求头
    Header { key: String, value: String, raw: String },
    /// 空行
    BlankLine,
    /// 请求体（文本/JSON/form-url-encoded）
    Body { content: String, content_type: Option<String> },
    /// < {% code %} 或 < {% ... %}
    PreScript { code: String, style: ScriptStyle },
    /// > {% code %} 或 > {% ... %}
    PostScript { code: String, style: ScriptStyle },
    /// 外部脚本引用
    ExternalScript { path: String, script_type: ScriptType },
    /// </path/to/file> 文件包含
    FileInclude(String),
    /// < /path/to/file 文件上传标记
    FileUpload(String),
    /// # @prompt varname [opts]
    Prompt(String),
    /// # @connection=xxx
    Connection(String),
    /// @env 块级变量
    EnvVar(String),
    /// 其他未知内容（原样保留）
    Raw(String),
}

enum ScriptStyle { Inline(String), Multiline(Vec<String>) }
enum ScriptType { Pre, Post }
```

## 3. 格式化规则（分阶段实现）

### Phase 1 — 结构格式化（纯 text 操作）

不需要理解语义，只做机械转换。

**规则 1：`###` 分隔符**
- `###` 前确保**有且仅有一个空行**
- 文件开头的第一个 `###` 前不需要空行
- `###` 后的标题保留原样

```
### Get users
...
                              ← 空行（确保一个）
### Create user
```

**规则 2：请求头 Key 规范化**
- header key 首字母大写（`content-type` → `Content-Type`）
- `Key:` 冒号后统一一个空格
- 不改变 header 顺序

```
content-type: application/json        ← 改前
Content-Type: application/json        ← 改后
```

**规则 3：空白行清理**
- 文件末尾：确保一个换行符
- 多余连续空行：压缩为最多一个空行

**规则 4：尾部空白**
- 移除所有行尾部空白

**规则 5：`###` 前空行**
- Request Name 后如有空行 → 保留或压缩
- 格式：`###` 行后紧跟变量或请求行

### Phase 2 — JSON Body 美化

**规则 6：JSON 请求体格式化**
- 检测 header 中 `Content-Type` 含 `json`（大小写不敏感）
- 用 `serde_json` 解析 → `serde_json::to_string_pretty`
- 如果解析失败 → 保持原样（可能不是 JSON 或语法错误）

```
{"name":"test","value":123}
                              ↓
{
  "name": "test",
  "value": 123
}
```

### Phase 3 — Script 格式化

**规则 7：`{% %}` 内部格式化**
- 保持 `{%` 和 `%}` 边界行
- 内部代码：2-space 缩进
- 可选：检测 `prettierd` 并 `jobstart` 调用（如果可用）

```
> {% client.test("ok", function() {
client.assert(response.status == 200);
}) %}
                              ↓
> {%
  client.test("ok", function() {
    client.assert(response.status == 200);
  })
%}
```

## 4. Poste CLI 集成

```
USAGE:
    poste fmt [OPTIONS] [FILE]...

ARGS:
    <FILE>...    Files to format (default: stdin)

OPTIONS:
    --check          Check formatting without modifying (exit 1 if unformatted)
    --stdin          Read from stdin (default if no file args)
    -i, --in-place   Modify files in-place (default)
    -h, --help       Print help
```

### conform.nvim 集成

```lua
require("conform").formatters.poste_http = {
  command = "poste",
  args = { "fmt", "--stdin" },
  stdin = true,
}

require("conform").formatters_by_ft["poste_http"] = { "poste_http" }
```

### CI / pre-commit 集成

```yaml
# .pre-commit-config.yaml
- repo: local
  hooks:
    - id: poste-http-fmt
      name: Format .http files
      entry: poste fmt --check
      language: system
      files: \.(http|rest)$
```

## 5. 实施

所有实施步骤以 `docs/http-impl-guide.md` 为准，按 Phase 0 → Phase 1-4 → 后续推进。

与 formatter 设计直接相关的后续事项（不在 `impl-guide.md` 中）：

- [ ] `kulala-fmt` 兼容适配（复用或借鉴其格式化规则）

