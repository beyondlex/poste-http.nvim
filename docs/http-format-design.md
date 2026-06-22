# HTTP 文件格式化设计

## 问题

Poste 的 `.http`/`.rest` 文件包含混合内容：`###` 请求块、`@variable` 定义、HTTP 请求行、headers、JSON 请求体、`< {% %}` pre-script、`> {% %}` assertion 块。没有现成的全文件 formatter 能理解这种混合格式。

```
@base_url = https://api.example.com
@token = abc123

### Get users
GET {{base_url}}/users
Authorization: Bearer {{token}}
Content-Type: application/json

{"name":"test","value":123}

> {% client.test("ok", function() {
  client.assert(response.status === 200);
}) %}
```

## 设计目标

1. 零安装 — 纯 Lua 实现，随 poste 发布
2. 安全 — 只格式化确定性高的部分，不破坏手写排版
3. 可扩展 — 后续可拆分为独立 `poste-fmt` binary
4. conform 集成 — 注册 `formatters_by_ft["poste_http"]`

## 架构

```
lua/poste/http/source_format.lua       ← 入口，全文件格式化
lua/poste/http/format_json.lua         ← JSON body 美化
lua/poste/http/format_script.lua       ← {% %} JS 格式化
```

## 格式化规则

### 1. `###` 分隔符
- 确保 `###` 前有且仅有一个空行
- `###` 后的标题保留原样

```
### Get users
...
                                         ← 空行
### Create user
```

### 2. `@variable` 对齐
- 等号前后统一空格
- 不对齐列（避免 diff 噪音）

```
@base_url = https://api.example.com
@token = abc123
```

### 3. HTTP 请求行
- 不修改 METHOD（GET/POST/PUT...）
- URL 中的 `{{}}` 保留原样
- HTTP 版本不修改

```
GET {{base_url}}/users
POST https://api.example.com/data
```

### 4. Headers
- header 名首字母大写（`Content-Type` 而非 `content-type`）
- 冒号后统一加一个空格
- 不改变 header 顺序

```
content-type: application/json          ← 改前
Content-Type: application/json          ← 改后

AUTHORIZATION: Bearer x                 ← 改前
Authorization: Bearer x                 ← 改后
```

### 5. JSON 请求体
- 空行后、headers 后的内容
- 如果 Content-Type 包含 json → 用 `vim.json.encode/decode` 美化
- 如果解析失败 → 保持原样（可能不是 JSON 或语法错误）

```
{"name":"test","value":123}
                                      ↓
{
  "name": "test",
  "value": 123
}
```

### 6. `< {% %} ` Pre-script / `> {% %} ` Assertion
- 提取 `{% %}` 之间的 JS 内容
- 如果安装了 `prettier`（detect 后 jobstart 调用）→ prettier 格式化
- 否则做基本缩进对齐（2-space indent）
- `{% %}` 包裹符保持原样

```
> {% client.test("ok", function() {
client.assert(response.status === 200);
}) %}
                                      ↓
> {%
  client.test("ok", function() {
    client.assert(response.status === 200);
  });
%}
```

### 7. 空白行清理
- 文件末尾：确保一个换行符
- 多余连续空行：压缩为最多一个空行

## M.format() API

```lua
--- 格式化整个 HTTP buffer。
--- @param opts? { bufnr?: number }
M.format = function(opts)
  -- 1. 解析 buffer 为请求块列表
  -- 2. 对每个块依次应用规则
  -- 3. 替换 buffer 内容
  -- 4. 恢复光标位置
end
```

## 集成

### conform

```lua
conform.formatters_by_ft["poste_http"] = { "poste-http" }
```

### LazyVim

```lua
LazyVim.format.register({
  name = "PosteHTTP",
  primary = true,
  priority = 150,
  format = function(buf) M.format({ bufnr = buf }) end,
  sources = function(buf)
    if vim.bo[buf].filetype == "poste_http" then return { "PosteHTTP" } end
    return {}
  end,
})
```

## 降级策略

| 条件 | 行为 |
|---|---|
| 无 `prettier` | JS 只做缩进对齐 |
| JSON 解析失败 | 保持原样 |
| 未知 block 类型 | 保持原样 |
| 整个文件不可解析 | 不修改 |

## 未来方向

1. 如果格式化规则变复杂 → 拆为独立 `poste-fmt` Rust/TS binary
2. 添加 `kulala-fmt` 作为优先选项（如果已安装）
3. 支持配置化（缩进大小、header 大小写策略）
