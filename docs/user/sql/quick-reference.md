# SQL 快速参考

> `.sql` / `.mysql` / `.sqlite` 文件语法速查表

---

## 文件结构

```sql
-- @connection dev-pg
-- @database myapp_db

SELECT * FROM users WHERE status = 'active';

INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com');

USE other_db;  -- 动态切换数据库

SELECT * FROM other_db.orders;  -- 跨库查询
```

---

## 连接配置

`connections.json`:
```json
{
  "dev-pg": {
    "dialect": "postgres",
    "host": "localhost",
    "port": 5432,
    "database": "myapp",
    "user": "admin",
    "password": "{{db_password}}"
  },
  "local-sqlite": {
    "dialect": "sqlite",
    "path": "./data/app.db"
  },
  "staging-mysql": {
    "dialect": "mysql",
    "host": "{{mysql_host}}",
    "port": 3306,
    "database": "staging_db",
    "user": "root",
    "password": "{{mysql_pass}}"
  }
}
```

---

## 执行上下文

| 模式 | 语法 | 说明 |
|------|------|------|
| 完整上下文 | `-- @connection` + `-- @database` | 直接指定 |
| 动态切换 | `USE dbname;` | 执行后自动更新 context |
| 跨库查询 | `SELECT * FROM db.table` | 无需 context |

---

## 结果面板键位

| 键位 | 功能 |
|------|------|
| `h` / `l` | 左/右切换单元格 |
| `j` / `k` | 上/下切换行 |
| `0` / `$` | 当前行第一列/最后一列 |
| `gg` / `G` | 首行/末行 |
| `H` | 跳到表头行 |
| `Ctrl+f` / `Ctrl+b` | 翻页 |
| `/` | 结果集内搜索 |
| `K` | 长文本/JSON 悬浮预览 |
| `q` | 关闭结果面板 |
| `<Tab>` / `<S-Tab>` | 切换多结果集标签 |

---

## 数据库浏览器键位

| 键位 | 功能 |
|------|------|
| `<CR>` | 展开/折叠节点；叶子节点预览数据 |
| `r` | 刷新当前节点 |
| `/` | 搜索过滤 |
| `s` | 生成 SELECT 查询 |
| `d` | 生成 DESCRIBE 查询 |
| `q` | 关闭浏览器 |

---

## 命令

| 命令 | 功能 |
|------|------|
| `:PosteSQLContext` | 打开上下文选择器 |
| `:PosteConnection` | 打开连接管理器 |
| `:PosteDBBrowser` | 打开数据库浏览器 |
| `<leader>rr` | 执行当前 SQL 语句/块 |
| `]]` / `[[` | 跳到下一个/上一个请求 |

---

## 支持的数据库

| 数据库 | 扩展名 | 方言 |
|--------|--------|------|
| PostgreSQL | `.sql` | postgres |
| MySQL | `.mysql` | mysql |
| SQLite | `.sqlite` | sqlite |

---

## 结果 JSON 格式

### SELECT 查询
```json
{
  "type": "resultset",
  "results": [{
    "columns": [{ "name": "id", "type": "integer", "nullable": false }],
    "rows": [[1], [2]],
    "row_count": 2,
    "execution_time_ms": 12
  }]
}
```

### DML/DDL
```json
{
  "type": "affected",
  "results": [{
    "affected_rows": 5,
    "execution_time_ms": 3
  }]
}
```

### USE 语句
```json
{
  "type": "use",
  "database_name": "myapp_db",
  "is_use_statement": true
}
```

---

## 内省查询（PostgreSQL 示例）

```sql
-- 数据库列表
SELECT datname FROM pg_database WHERE datistemplate = false;

-- Schema 列表
SELECT schema_name FROM information_schema.schemata
WHERE schema_name NOT IN ('pg_catalog', 'information_schema');

-- 表列表
SELECT table_name, table_type FROM information_schema.tables
WHERE table_schema = $1;

-- 列信息
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = $1 AND table_name = $2;
```

---

*SQL 快速参考 — 最后更新：2026-06-24*
