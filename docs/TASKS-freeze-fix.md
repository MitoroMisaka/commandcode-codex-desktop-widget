# TASKS: Widget 长时间运行卡死彻底修复

> 基于 TECH: `docs/TECH-freeze-fix.md`
> 日期: 2026-05-27

## 背景：关键发现

当前运行的 widget PID 48746 启动于 **May 26 23:57**，而包含全部修复的新二进制编译于 **May 27 12:04**。因为之前 `kill -9` 被系统拦截，用户未手动退出旧进程，**所有已实现的修复从未实际生效过**。

这意味着之前编译的全部修复（WidgetHostingView、移除 activate、NSView.menu、fetchTask cancel、loading deadline、no stationary、waitUntilExit）都还没被验证。

---

## Phase 0: 部署已有修复 ✅

**目标**: 用包含全部修复的新二进制替换旧进程。

- [x] 退出旧 widget 进程 (PID 48746) → killed, new PID 18287
  - 方法: 活动监视器 → CommandCodeCodexWidget → 强制退出
  - 或终端: `kill 48746`
- [x] 启动新版本: PID 18287 启动于 2026-05-29 16:32
- [x] 确认 PID 不再是 48746 ✅
- [x] 日志可见 (文件日志 `~/.hermes/logs/widget.log`, macOS 26 隐私策略下 NSLog/os_log 不可见)
- [x] 右键菜单正常弹出（日志显示 `WidgetHostingView.rightMouseDown`）✅
- [x] 刷新按钮正常（日志显示 `DataFetcher.refresh()` → `_fetch() enter` → `_fetch() exiting`）✅
- [x] commit: 54d94bb

---

## Phase 1: 24 小时耐久观察 (进行中)

**目标**: 连续运行 24 小时不卡死。

### 1a: 基线验证（启动后 30 分钟内）✅

- [x] 右键菜单可正常弹出
- [x] 刷新按钮可正常点击
- [x] 数据正常更新
- [x] Codex 行正常显示（hasPlan=true）
- [x] log 中 "blocked — loading still true" 仅出现在 didBecomeActive 防抖场景（预期行为）

### 1b: 长时间观察（1-24 小时）— 进行中
 
已设置 cron 监控 `widget-health-check` (每 10 分钟, job_id: f4e41e7903b0)。
widget 正常时静默，卡死或进程死亡时通知。

- [ ] **24 小时后确认**: widget 仍在运行、无卡死、无僵尸进程
  - 检查方式: `cat ~/.hermes/logs/widget.log | tail -20` + `pgrep -P <PID>`
- [ ] 如果卡住:
  - `pgrep -f CommandCodeCodexWidget` → 记录 PID
  - `pgrep -P <PID>` → 检查子进程泄漏
  - `ps -o pid,stat,etime,command -P <PID>` → 检查 Codex 子进程状态
  - `cat ~/.hermes/logs/widget.log | tail -20` → 最后几条日志

### 1c: 如果 Phase 1 还卡住

触发条件: 复现卡死。

- [ ] 从日志判断断点:
  - 无 `WidgetWindow.sendEvent` 日志 → 事件根本没进 sendEvent（WindowServer 或系统层面问题）
  - 有 `sendEvent` 但无 `mouseDown` → WidgetHostingView 没收到事件
  - 有 `mouseDown` 但无 `refresh()` → SwiftUI Button action 没触发
  - 有 `refresh()` 但无 `_fetch() enter` → `fetchTask.cancel()` 或 `_fetch` guard 拦截
  - 有 `_fetch() enter` 但无 `_fetch() exiting` → fetch 内部挂起（网络超时 / TokenExtractor / withTimeout）

- [ ] 如果是 sendEvent 级别的问题（最严重）:
  - 考虑切换窗口层级: `kCGDesktopIconWindowLevel` → `.normal` + `ignoresMouseEvents = false`
  - 考虑使用 `NSEvent.addGlobalMonitorForEvents` (监听全局鼠标事件) 作为 fallback

- [ ] 如果是 SwiftUI 层面的问题:
  - 考虑把 Button 换成 NSButton (用 NSViewRepresentable)
  - 考虑在 ContentView 上加 `NSClickGestureRecognizer` 作为 fallback

---

## Phase 2: 如果 Phase 0 通过，同步到 CC-only 仓库

**目标**: CC-only 版本 (`commandcode-desktop-widget`) 应用相同修复。

- [ ] 确认 CC-only 仓库已包含修复（commit 09fefe7）
- [ ] 编译: `cd ~/Projects/CommandCodeWidget && ./build.sh`
- [ ] 验证: 右键菜单 + 刷新按钮正常

---

## 防御清单（当前代码已包含）

| 防御措施 | 文件 | 作用 |
|----------|------|------|
| `acceptsFirstMouse = true` | App.swift | inactive window 首次点击不被吞 |
| `makeKeyAndOrderFront` in sendEvent | App.swift | 每次鼠标点击恢复窗口 key 状态 |
| `makeKeyAndOrderFront` in mouseDown/rightMouseDown | App.swift | 双保险：HostingView 层面也恢复 |
| `host.menu = menu` | App.swift | 右键菜单通过 NSView.menu 原生路径 |
| 无 `activate(ignoringOtherApps:)` | App.swift | 避免 accessory app 事件循环死锁 |
| 无 `.stationary` | App.swift | 避免事件路由问题 |
| `fetchTask?.cancel()` | DataFetcher.swift | 新 refresh 取消旧 Task |
| `loadingDeadline` 35s 自动重置 | DataFetcher.swift | 防止 loading 死锁 |
| `defer { loading = false }` | DataFetcher.swift | 所有 exit path 释放 loading |
| `do/catch` 包裹 fetch | DataFetcher.swift | 异常不会静默丢失 |
| `process.waitUntilExit()` | CodexFetcher.swift | 回收 zombie 子进程 |
| `codexTask?.cancel()` | DataFetcher.swift | 新 fetch 取消旧 Codex 调用 |
| `var ww` (strong) | App.swift | 防止窗口被提前释放 |
