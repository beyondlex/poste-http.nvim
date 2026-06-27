# Sign Column Indicators Postmortem

2026-06-27 — 将 HTTP/SQL 请求状态指示器 (✓/✘/spinner) 从 virt_text 迁移到 sign column 过程中遇到的问题和解决方案。

## 背景

原本 ✓/✘ 和延迟信息都显示在行末 (virt_text/eol)。目标是将 ✓/✘ 移到 sign column，只在行末保留延迟/断言信息。

核心实现在 `lua/poste/indicators.lua`，通过 `set_indicator(buf, line_0, status)` 统一管理三种状态：`"running"` (spinner)、`"success"` (✓)、`"error"` (✘)。

## 问题一：Sign 放置后 50ms 内消失

### 现象

- `sign_getplaced` 确认 sign 在 t+0 时存在，t+50ms 时已被删除
- 用 `vim.cmd("sign place ...")` 或 `vim.fn.sign_place` 都一样
- 仅影响 success/error sign，spinner sign 不受影响
- 在不同 Neovim 版本/配置上表现不一致

### 根因

Sign group 名称 `"poste_indicator"` 与其他插件或 Neovim 机制冲突。有插件会定期清理名字匹配 `*indicator*` 的 sign group。

### 修复

将 group 名称改为唯一值 `"poste_sg_4a7f"`。

### 调试过程（耗时最长的部分）

尝试过的方案：
1. 用 `sign_place(0, group, name, buf, {lnum, priority})` 添加新 sign + `sign_unplace` 删除旧 spinner — 无效
2. 用 `vim.cmd("sign place <id> line=... name=... group=... buffer=...")` 原地替换 — 无效
3. 调用 `vim.cmd("redraw!")` 强制刷新 — sign 短暂出现后消失
4. 添加新 sign 与 spinner 共存 (不替换) — 高优先级 success sign 仍然消失
5. 临时禁用 `TextChanged` autocmd — 无效
6. `defer_fn` 检查 t+0/t+50/t+500ms — 确认 sign 在 0-50ms 窗口内被删除
7. 检查 `sign_define` 返回值、`nvim_get_hl`、字符编码 — 全部正常
8. 改用完全不同 group 名 `"PsOK_grp"` — **成功**，sign 不再消失

### 教训

- 对 Neovim sign API，group 名像 `"xxx_indicator"` 可能与其他插件冲突
- 应优先怀疑 group 名冲突，而不是 sign API 行为
- 用 `sign_getplaced(buf, {group=..., lnum=...})` 确认 sign 是否存在，比目视检查更快定位
- 在用户不同配置环境中测试很重要 — 用户 A 正常、用户 B 消失，说明是插件冲突

## 问题二：Request 完成后 spinner 偶尔不变成 ✓/✘

### 现象

- 偶发，不是每次必现
- 请求完成但 sign column 仍然显示 spinner

### 根因

`stop_timer()` 没有递增 `spinner_gen`。执行流程：

1. libuv timer 触发 → `vim.schedule_wrap(update_spinner)` 推入 Neovim 事件队列
2. `on_stdout` → `vim.schedule` 推入 `set_indicator("success")` 
3. 事件队列处理顺序不确定。如果 `update_spinner` 在 `set_indicator("success")` 之后运行，且 `spinner_gen` 未变化，它会继续更新 spinner 定义
4. `update_spinner` 通过 `vim.fn.sign_define("PosteSpinnerSign", ...)` 更新 spinner 外观。如果此时 success sign 已被替换为 `PosteSuccessSign`，理论上不受影响；但在某些 Neovim 版本/条件下，sign name 的替换可能有竞态

### 修复

在 `stop_timer()` 中增加 `spinner_gen = spinner_gen + 1`：

```lua
local function stop_timer()
  spinner_gen = spinner_gen + 1  -- 确保已入队的 callback 因 generation 不匹配跳过
  if spinner_timer then
    spinner_timer:stop()
    spinner_timer:close()
    spinner_timer = nil
  end
end
```

`update_spinner` 检查 `my_gen ~= spinner_gen`，只要有任一 generation 不匹配就跳过，不再更新 spinner 定义。

### 教训

- `vim.schedule_wrap` 的回调可能在 timer 被 stop/close 后仍在事件队列中等待执行
- 使用 generation counter 时，**所有**可能 invalidate 回调的地方都要递增计数器
- `set_indicator` 的入口已经递增了 `spinner_gen`，但防御性编程要求 `stop_timer()` 也做同样的事

## 问题三：执行新请求时保留旧请求的 sign

### 现象

在 request1 上执行完后看到 ✓，再执行 request2，request1 的 ✓ 仍然显示。

### 根因

`clear_all` 只在找不到 request line 时调用；正常执行路径只调用 `set_indicator("running")` 放置 spinner，不清除其他行的 sign。

### 修复

新增 `clear_other_requests(buf, line_0)`：

```lua
function M.clear_other_requests(buf, line_0)
  -- 清除所有其他行的 sign + eol virt_text，保留当前行
end
```

在 `run.lua` 的 `set_indicator("running")` 之前调用。

### 教训

- 状态清理逻辑应该和状态设置逻辑放在一起看
- 新增状态类型 (sign column) 时要检查所有可能残留的场景

## 总结

| # | 问题 | 根因 | 修复 | 耗时 |
|---|------|------|------|------|
| 1 | Sign 50ms 后消失 | group 名与其他插件冲突 | 改为唯一 group 名 | 最长 |
| 2 | Spinner 不消失 | `stop_timer` 没递增 generation | `stop_timer` 加 `spinner_gen++` | 中等 |
| 3 | 旧 sign 残留 | 执行前不清除其他行 | 新增 `clear_other_requests` | 最短 |

问题 1 占用了大部分调试时间，因为 symptom 指向 sign API 行为异常，实际是外部因素。