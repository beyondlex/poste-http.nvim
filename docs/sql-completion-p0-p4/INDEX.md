# Poste SQL Completion — Agent Entry Point

> **Status**: P0 complete ✅ | Ready for P1-P4 implementation

如果你是第一次接触这个项目的 AI agent，按以下顺序阅读和执行。

---

## 1. 必读文件（按顺序）

| 顺序 | 文件 | 读完应理解 |
|------|------|-----------|
| ① | `p0/poste-sql-file-syntax.md` | 文件结构、指令规则、语句边界、JSON 契约、上下文类型语义（共 8 节） |
| ② | `plan.md` | 各阶段步骤清单、验收命令、提交清单 |

读完后可参考：

| 参考 | 文件 | 何时看 |
|------|------|--------|
| 设计决策 D1-D10 的权衡分析 | `p0/design-decisions.md` | 遇到边界情况或质疑当前选择时 |
| 会议辩论记录 + 后续决策 | `p0/meeting-minutes.md` | 想理解某个决策为什么会这样定 |

**不需要读**：`README.md`（原始计划，已被 `plan.md` 替代）、`p0/meeting-agenda.md`（历史会议议程）。

---

## 2. 实施规范

### 2.1 TDD 优先

```
1. 先写测试（或 golden fixture）
2. 确认测试失败（红）
3. 实现代码直到测试通过（绿）
4. 重构
```

- Rust 新功能：先在 `tests/sql_context_golden.rs` 或 `sql_context/tests.rs` 加 fixture/测试
- Lua 新功能：先在 `tests/sql_completion_*_spec.lua` 加测试
- 已标记 `BUG`/`BEFORE FIX` 的旧测试：实现修复后**更新测试断言**以匹配正确行为，不要为兼容旧错误保留错误测试

### 2.2 每步验收命令

```bash
# Rust 测试
cargo test -p poste-core sql_context

# Rust golden fixture 测试（P2+）
cargo test -p poste-core --test sql_context_golden

# Lua 测试
tests/run.sh

# Clippy
cargo clippy -p poste-core -p poste-cli -p poste-exec -- -D warnings
```

### 2.3 变更边界

| 不允许修改 | 原因 |
|-----------|------|
| `lua/poste/http/*` | HTTP completion 隔离 |
| `lua/poste/completion.lua` | HTTP completion 入口（不是 SQL） |
| `lua/poste/sql/buffer.lua` | SQL 结果渲染 |
| SQL executor 行为 | 除非阶段明确需要 metadata/cache 支持 |

### 2.4 进度跟踪

每次实施后更新 `plan.md` 顶部的进度条和勾选项：

```markdown
> **进度**: P0 ✅ | P1 ⬜/⬜/⬜/⬜ | P2 ⬜ | P3 ⬜ | P4 ⬜
```

用 `[x]` 标记已完成的复选框，`⬜` 表示尚未开始，半进度可用 `⬜/⬜/⬜/⬜` 表示子步骤完成数。

### 2.5 契约兼容规则

- **不删除 JSON 字段**。只增不删。`version` 字段始终存在。
- Lua 侧接到未知字段直接略过（`deep_clean()` 已处理）。
- `###` 不再出现在文件格式中。碰到旧代码中的 `###` 处理逻辑应移除。

---

## 3. 快速参考

| 需要 | 路径 |
|------|------|
| 当前实施步骤 | `plan.md` — 找到第一个未勾选的 `[ ]` |
| 上下文类型完整表（14 种 + 42 种边缘情况） | `poste-sql-file-syntax.md` §5 |
| JSON 契约字段定义 | `poste-sql-file-syntax.md` §4 |
| 语句边界规则 | `poste-sql-file-syntax.md` §3 |
| 每阶段改动文件清单 | `plan.md` 底部表格 |
| 提交顺序 | `plan.md` §提交序列 |
