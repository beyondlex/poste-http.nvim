# HTTP 快速参考

> `.http` 文件语法速查表

---

## 文件结构

```
import ./auth.http                         ← 文件级引用（可多条）
import ./orders.http as orders

@base_url = https://api.example.com        ← 文件级变量
@token = eyJhbGci...

### Get users                              ← 请求块分隔
@page_size = 20                            ← 块级变量
GET {{base_url}}/users?limit={{page_size}}
Authorization: Bearer {{token}}

{                                          ← 请求体
  "name": "test"
}

> {%                                      ← 断言脚本
  client.assert(response.status == 200);
%}
```

---

## 变量类型

| 类型 | 示例 | 说明 |
|------|------|------|
| 文件级 | `@base_url = https://api.com` | 整个文件有效 |
| 块级 | `###` 后定义 | 仅当前请求块有效，覆盖文件级同名变量 |
| 多行 | `@payload =>>> ... <<<` | 多行值 |
| Magic | `{{$timestamp}}` `{{$uuid}}` `{{$date}}` `{{$randomInt}}` | 运行时生成 |
| 跨请求 | `{{login.response.body.token}}` | 引用之前执行结果 |
| 环境 | `{{api_base}}`（来自 env.json） | 环境配置变量 |

---

## 请求块语法

```
### Request Name
< {% pre-script %}                         ← Pre-request 脚本（可选）
@block_var = value                         ← 块级变量（可选）
METHOD URL [HTTP/version]                  ← 请求行
Header-Key: Header-Value                   ← 请求头（可多条）
                                           ← 空行（必需，分隔 headers 和 body）
{ "key": "value" }                         ← 请求体（可选）
> {% assertion %}                          ← Post-request 断言（可选）
```

---

## 请求方法

`GET` `POST` `PUT` `DELETE` `PATCH` `HEAD` `OPTIONS` `TRACE` `CONNECT`

---

## 文件包含/上传

```
# JSON 嵌入（Content-Type 含 json 时）
POST /api/data
Content-Type: application/json

< /path/to/payload.json

# 文件上传（multipart/form-data）
POST /api/upload
Content-Type: multipart/form-data

< /path/to/file.txt
```

---

## 脚本 API

### Pre-request (`< {% %}`)

```javascript
request.variables.set("key", "value");     // 设置请求变量
request.headers.set("X-Custom", "val");    // 修改请求头
request.body = JSON.stringify({});         // 修改请求体
client.log("message");                     // 日志
client.global.set("key", "value");         // 全局变量（跨请求）
variables.base_url                         // 读取 @variable
env.api_base                               // 读取 env.json
```

### Post-request (`> {% %}`)

```javascript
response.status                            // HTTP 状态码
response.body                              // 响应体字符串
response.headers                           // 响应头
response.latency                           // 响应时间 (ms)
client.test("name", fn);                   // 测试用例
client.assert(condition, "message");       // 断言
client.log("message");                     // 日志
```

---

## 跨文件引用

```
# 导入
import ./auth.http
import ./orders.http as orders

# 执行
run #Login                                 # 无别名：查找全局
run #orders.ListOrders                     # 有别名：查找命名空间
run #Login (@token=xyz)                    # 运行时变量覆盖
run ./batch.http                           # 运行整个文件

# run 也支持 post-script（> {% %}）
run #auth.op_login

> {%
  client.global.set('token', response.body.token)
%}
```

---

## 环境变量

`env.json`:
```json
{
  "dev": {
    "api_base": "https://dev-api.example.com",
    "db_password": "dev_secret"
  },
  "prod": {
    "api_base": "https://api.example.com"
  }
}
```

使用：`{{api_base}}` → 根据当前环境自动替换

---

## 命令与键位

| 命令/键位 | 功能 |
|-----------|------|
| `<leader>rr` | 执行当前请求 |
| `]]` | 跳到下一个请求 |
| `[[` | 跳到上一个请求 |
| `:PosteEnv` | 显示当前环境 |
| `:PosteEnv <name>` | 切换环境 |
| `q`（响应缓冲区） | 关闭响应窗口 |
| `K`（图片响应） | Body 自动内联预览图片；未安装 `image.nvim` 时外部打开 |
| `:PosteHttpHistory` | 打开请求历史弹窗 |
| `<C-h>`（历史列表） | 跳到右侧详情缓冲区 |
| `<C-l>`（历史详情） | 跳到左侧列表缓冲区 |
| `j` / `k`（历史列表） | 上/下导航历史条目 |
| `<CR>`（历史列表） | 焦点移至右侧详情 |
| `dd`（历史列表） | 删除当前条目 |
| `q`（历史弹窗） | 关闭历史弹窗 |

---

## 格式化规则（`poste fmt`）

- `###` 前确保一个空行
- `@var = value` 等号前后各一个空格
- Header key 首字母大写，冒号后一个空格
- JSON body 自动美化
- 移除尾部空白，压缩多余空行

---

## 请求历史（PosteHttpHistory）

`PosteHttpHistory` 提供接近窗口大小的浮动弹窗，展示当前会话的所有 HTTP 请求记录，并持久化到磁盘（跨 Neovim 会话保留）。

### 弹窗布局

```
┌───────── " Poste HTTP History " ────────────────┐
│ 左列表 (36列)       │ 右详情 (剩余宽度)          │
│                     │                            │
│ Get Profile  23:32  │ [Body[H] | Rqst[R]        │
│ Request 3    23:30  │  | Verb[L] | Asserts[A]]  │
│ Request 2    22:45  │ ══════════════════════════ │
│ Request 1    21:34  │  (响应内容)               │
│ Login        20:33  │                            │
└─────────────────────┴────────────────────────────┘
```

### 操作

| 操作 | 位置 | 效果 |
|------|------|------|
| `j` / `k` | 左列表 | 上/下导航，自动更新右侧详情 |
| `<CR>` | 左列表 | 光标跳至右侧详情缓冲区 |
| `dd` | 左列表 | 删除当前请求记录 |
| `H` / `R` / `L` / `A` / `S` | 右详情 | 切换 Body / Rqst / Verb / Asserts / Script 标签页 |
| `<Tab>` / `<S-Tab>` | 右详情 | 循环切换标签页 |
| `<leader>j` / `<leader>jc` | 右详情（JSON 视图） | jq 过滤 / 恢复 |
| `<C-h>` | 右详情 | 跳回左列表 |
| `<C-l>` | 左列表 | 跳至右详情 |
| `q` | 全局 | 关闭历史弹窗 |

### 存储

历史记录仅存于当前 Neovim 会话内存中，关闭 Neovim 后自动清空。最多保留 100 条，响应 body 超过 100KB 时自动截断。

---

*HTTP 快速参考 — 最后更新：2026-06-25*
