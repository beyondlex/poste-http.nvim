# OpenAPI / Swagger / Postman 导入功能开发计划

> TDD 驱动的导入功能实现，将 OpenAPI 3.x、Swagger 2.0、Postman Collection 导出数据转换为 Poste 原生 `.http` 文件树。

## 总体架构

```
用户交互层 (Neovim Lua)
  poste.http.import_openapi    ← 三个新 Lua 模块，复用 finder 组件
  poste.http.import_swagger      选文件/选目录
  poste.http.import_postman
       │
       │ 调用 CLI
       ▼
CLI 层 (crates/poste-cli)
  poste import openapi <file> --out <dir>    ← 新增 import 子命令
  poste import swagger <file> --out <dir>
  poste import postman <file> --out <dir>
       │
       ▼
核心转换层 (crates/poste-core)
  src/import/           ← 新建目录
    ├── mod.rs          ← ImportResult + SpecImporter trait + 公共类型
    ├── openapi.rs      ← OpenAPI 3.x 解析 + 转 .http
    ├── swagger.rs      ← Swagger 2.0 → 内部转 OAS3 → 复用 openapi.rs
    └── postman.rs      ← Postman Collection v2.1 解析
```

### 分层责任

| 层 | 责任 | 测试方式 |
|---|------|----------|
| **Rust 核心层** | 纯转换逻辑，spec → 内存中 .http 文件树 | `cargo test` 单元测试 |
| **Rust CLI 层** | clap 子命令 + 文件 I/O + 写盘 | 集成测试 |
| **Lua UI 层** | finder 选文件/目录 → 调用 CLI → 反馈结果 | 人工验证 |

### 依赖

```toml
# crates/poste-core/Cargo.toml
openapiv3 = "2.0"         # OpenAPI 3.x 结构化类型
serde_yaml = "0.9"        # YAML 解析
```

## 输出文件结构

### 输入: OpenAPI spec

```yaml
openapi: "3.0.0"
info:
  title: Petstore API
servers:
  - url: https://api.petstore.com/v1
paths:
  /pets:
    get:
      tags: [pets]
      operationId: listPets
      parameters:
        - in: query, name: limit, schema: { type: integer }
    post:
      tags: [pets]
      operationId: createPet
      requestBody:
        content:
          application/json:
            example: { "name": "Fluffy" }
  /pets/{petId}:
    get:
      tags: [pets]
      operationId: getPetById
```

### 输出: .http 文件树

```
api/
├── env.json                  # 抽取的变量: base_url, limit, petId, api_key...
│
├── pets.http                 # tag: pets
│   ├── @base_url = {{base_url}}
│   │
│   ├── ### listPets — GET /pets
│   │   GET {{base_url}}/pets?limit={{limit}}
│   │
│   ├── ### createPet — POST /pets
│   │   POST {{base_url}}/pets
│   │   Content-Type: application/json
│   │
│   │   {"name": "Fluffy"}
│   │
│   └── ### getPetById — GET /pets/{petId}
│       GET {{base_url}}/pets/{{petId}}
│
├── store.http                # tag: store (如有)
│
└── _index.http               # 自动生成的导入主文件
    ├── import ./pets.http as pets
    └── import ./store.http as store
```

### OpenAPI 映射规则

| OpenAPI | .http 表示 |
|---------|-----------|
| `info.title` | 目录名（可配置） |
| `servers[0].url` | `@base_url = {{base_url}}` + `env.json` 中 `base_url` |
| `GET /pets/{petId}` | `GET {{base_url}}/pets/{{petId}}` |
| `parameters[].in: query` | 追加 `?key1={{val1}}&key2={{val2}}` 到请求行 |
| `parameters[].in: header` | `Header-Name: {{paramName}}` 在请求行后 |
| `parameters[].in: path` | `{{paramName}}` 在 URL 中 + `@paramName` 文件变量带默认值 |
| `requestBody` 的 example | 内联 JSON body，动态字段转为 `{{var}}` |
| `security[].apiKey` | `Authorization: {{api_key}}` 模板 + `env.json` 占位 |
| `components.schemas` | 忽略（可复用类型在 .http 中无意义），可选项：输出为 `.json` fixture |

## 执行计划 (TDD，18 Steps)

### 第 0 阶段: 基础设施 (Steps 0–2)

**Step 0** — 新增 Rust 依赖 (`openapiv3`, `serde_yaml`)

测试: 空 spec 返回空文件列表

**Step 1** — 定义 `ImportResult`、`HttpFile`、`SpecImporter` trait

测试: ImportResult JSON 序列化

**Step 2** — 添加 `poste import` CLI 子命令框架（三个子命令 + 写盘逻辑）

测试: clap 参数解析正确

### 第 1 阶段: OpenAPI 3.x (Steps 3–7)

**Step 3** — 核心转换器: 路径分组 + 基础请求生成

测试:
- 单 GET 端点 → 1 个 .http 文件，含 `### listPets` + `GET {{base_url}}/pets`
- 多 tag → 多文件输出
- 路径参数 `{petId}` → `{{petId}}`

**Step 4** — 参数处理: query → URL 查询字符串，header → 请求头，path → 占位符

测试:
- query 参数拼接到 URL 行
- header 参数输出为请求头行
- 连字符参数名转下划线 (env.json 兼容)

**Step 5** — RequestBody + Example 处理

测试:
- JSON body example 原样输出
- multipart/form-data Content-Type + boundary 模板

**Step 6** — Security/Auth 处理

测试:
- apiKey → `X-API-Key: {{api_key}}` 注入每个请求
- bearer → `Authorization: Bearer {{auth_token}}`

**Step 7** — env.json 生成

测试:
- `base_url` + 所有参数默认值抽取到 env.json
- 枚举值作为注释 `# enum: available, pending, sold`

### 第 2 阶段: Swagger 2.0 (Steps 8–9)

**Step 8** — Swagger → OpenAPI 3 内存转换器

策略: 不写两套转换逻辑。Swagger 2.0 转成 OAS3 内存表示后直接用 OpenAPI 转换器。

测试:
- `swagger.host + basePath` → `openapi.servers[0].url`
- `parameters[].in: body` → `requestBody`
- `parameters[].in: formData` → multipart
- `securityDefinitions` → `components.securitySchemes`

**Step 9** — Swagger CLI 集成

测试: `poste import swagger ./swagger.json --out ./api` 端到端

### 第 3 阶段: Postman Collection (Steps 10–12)

**Step 10** — Postman Collection v2.1 解析器（独立于 OpenAPI）

测试:
- 基本 GET 请求转换
- 嵌套 item(folder) → 目录层级
- collection.auth → header 模板
- collection.variable → env.json

**Step 11** — Postman body 转换

测试:
- raw JSON → Content-Type + body
- formdata → multipart 模板
- urlencoded → key=value body

**Step 12** — Postman script 转换

测试:
- Pre-request Script → `< {% %}`
- Test Script → `> {% %}`

### 第 4 阶段: Neovim Lua UI (Steps 13–15)

**Step 13** — 注册三个 `:PosteImport*` 用户命令

**Step 14** — 复用 SQL import/export 的 finder 组件选文件 + 选目录

```lua
-- 文件选择 (复用 SQL import 的 finder 模式)
finder.open({
  mode = "file",
  extensions = { "json", "yaml", "yml" },  -- 与 SQL 的 {"csv","tsv","json"} 一致
  on_confirm = function(path) ... end,
})

-- 目录选择 (复用 SQL export 的 mode = "dir")
finder.open({
  mode = "dir",
  on_confirm = function(path) ... end,
})
```

参考文件:
- `lua/poste/sql/import.lua` — finder 文件选择 (lines 233–254)
- `lua/poste/sql/export.lua` — finder 目录选择 (lines 316–336)

**Step 15** — CLI 调用 + 结果反馈

测试: 导入完成后在浮动窗口展示文件列表、变量数、警告

### 第 5 阶段: 集成测试 (Steps 16–18)

**Step 16** — 真实世界 Spec 端到端测试

使用官方 Petstore 3.0 / Swagger Petstore 2.0 / Postman Echo 三个 fixture

**Step 17** — 边界情况

测试: 非法输入、超大 spec、特殊字符路径名、空 collection

**Step 18** — 增量开发辅助

- 自动生成 `_index.http` 主文件（含 import 所有 tag 文件）
- 输出目录已存在的警告处理

## 文件清单

### 新增 Rust

| 文件 | Step | 说明 |
|------|------|------|
| `crates/poste-core/src/import/mod.rs` | 1 | ImportResult、HttpFile、SpecImporter trait |
| `crates/poste-core/src/import/openapi.rs` | 3–7 | OpenAPI 3.x 转换器 |
| `crates/poste-core/src/import/swagger.rs` | 8 | Swagger 2.0 → OAS3 转换器 |
| `crates/poste-core/src/import/postman.rs` | 10–12 | Postman Collection 转换器 |
| `crates/poste-core/src/import/tests/mod.rs` | 0–18 | 所有单元测试 |

### 新增 Lua

| 文件 | Step | 说明 |
|------|------|------|
| `lua/poste/http/import_openapi.lua` | 13–15 | Neovim UI: OpenAPI |
| `lua/poste/http/import_swagger.lua` | 13–15 | Neovim UI: Swagger |
| `lua/poste/http/import_postman.lua` | 13–15 | Neovim UI: Postman |

### 新增测试 Fixture

| 文件 | Step | 来源 |
|------|------|------|
| `tests/fixtures/petstore.yaml` | 16 | Petstore 3.0 (官方示例) |
| `tests/fixtures/swagger-petstore.json` | 16 | Swagger Petstore 2.0 |
| `tests/fixtures/postman-echo.json` | 16 | Postman Echo Collection |

### 修改文件

| 文件 | Step | 修改内容 |
|------|------|----------|
| `crates/poste-core/Cargo.toml` | 0 | 添加 openapiv3, serde_yaml |
| `crates/poste-core/src/lib.rs` | 1 | `pub mod import` |
| `crates/poste-cli/src/main.rs` | 2 | 添加 Import 子命令枚举 + 分发 |
| `lua/poste/init.lua` | 13 | 注册 3 个用户命令 |
| `docs/dev/README.md` | 0 | 添加此文档的索引条目 |

## 实现顺序

```
Step 0  →  基础设施 + 依赖
Step 1  →  ImportResult + SpecImporter trait
Step 2  →  CLI 子命令框架 + 输出写盘
──────────  以上为骨架，可并行 ═══
Step 3  →  OpenAPI: 路径/方法/请求行
Step 4  →  OpenAPI: 参数 (query/header/path)
Step 5  →  OpenAPI: RequestBody + Example
Step 6  →  OpenAPI: Security/Auth
Step 7  →  OpenAPI: env.json 生成
──────────  OpenAPI 完成 ═══
Step 8  →  Swagger: 2.0 → OAS3 转换器
Step 9  →  Swagger: CLI 集成
──────────  Swagger 完成 ═══
Step 10 →  Postman: 基础解析
Step 11 →  Postman: body 转换
Step 12 →  Postman: script 转换
──────────  Postman 完成 ═══
Step 13 →  Lua 命令注册
Step 14 →  Lua: finder 文件/目录选择
Step 15 →  Lua: CLI 调用 + 结果反馈
──────────  Neovim UI 完成 ═══
Step 16 →  真实 spec 端到端测试
Step 17 →  边界情况处理
Step 18 →  增量开发辅助
──────────  验收 ═══
```

## 参考

- SQL 导入: `lua/poste/sql/import.lua` — finder 文件选择模式
- SQL 导出: `lua/poste/sql/export.lua` — finder 目录选择模式
- Curl 导入: `lua/poste/http/curl.lua` — 现有单请求导入模式
- HTTP formatter: `crates/poste-core/src/formatter.rs` — .http 文件 Region 定义
- CLI 结构: `crates/poste-cli/src/main.rs` — clap 子命令模式
- SQL TDD 参考: `docs/dev/sql/design.md` — 6 阶段实施参考
