# SQL Integration Test Environment

Poste SQL 集成测试环境，使用 Docker Compose 启动 PostgreSQL 和 MySQL 实例。

## 快速启动

```bash
cd tests/sql
docker compose up -d
```

等待数据库初始化完成（约 5-10 秒），验证服务状态：

```bash
docker compose ps
```

## 数据库

### PostgreSQL (port 15432)

| Database    | Tables                                    | Description         |
|-------------|-------------------------------------------|---------------------|
| `ecommerce` | users, products, orders, order_items      | 电商订单系统        |
| `analytics` | events, sessions, page_views              | 用户行为分析        |

- User: `poste` / Password: `poste_test`

### MySQL (port 13306)

| Database    | Tables                                                        | Description       |
|-------------|---------------------------------------------------------------|-------------------|
| `blog`      | authors, categories, posts, tags, post_tags, comments         | 博客平台          |
| `inventory` | warehouses, suppliers, items, stock, shipments, shipment_items | 仓库库存管理      |

- User: `root` / Password: `poste_test`

## 使用 Poste 测试

`connections.json` 预配置了 4 个连接：

- `pg-ecommerce` → PostgreSQL ecommerce 库
- `pg-analytics` → PostgreSQL analytics 库
- `my-blog`      → MySQL blog 库
- `my-inventory` → MySQL inventory 库

在 Neovim 中打开 `queries/postgres.sql` 或 `queries/mysql.sql`，使用 poste 执行查询。

## 端口映射

使用非标准端口避免与本地数据库冲突：

- PostgreSQL: **15432** (host) → 5432 (container)
- MySQL:      **13306** (host) → 3306 (container)

## 清理

```bash
docker compose down -v
```
