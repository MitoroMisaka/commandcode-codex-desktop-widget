# TECH: Widget 长时间运行卡死彻底修复

> 基于 PRD: `docs/PRD-freeze-fix.md`
> 日期: 2026-05-27

## 架构概览

```
Widget App (LSUIElement, .accessory)
├── App.swift
│   ├── WidgetWindow (canBecomeKey=true, sendEvent override)
│   ├── WidgetHostingView<Content> (acceptsFirstMouse, mouseDown/rightMouseDown)
│   ├── ContentView (SwiftUI body, @EnvironmentObject fetcher/state)
│   └── WidgetAppDelegate (applicationDidFinishLaunching, menu setup)
├── DataFetcher.swift
│   ├── Timer.scheduledTimer (auto-refresh)
│   ├── fetchTask (cancel-on-new-refresh pattern)
│   ├── loadingDeadline (35s auto-reset defense)
│   └── CodexFetcher.fetch() in Task.detached (parallel, decoupled)
├── CodexFetcher.swift
│   ├── Process spawn → readabilityHandler → 10s timeout → finish
│   └── State class (NSLock, hasResumed, initialized flags)
├── TokenExtractor.swift
│   └── cp + sqlite3 (Task.detached, priority: .utility)
└── Models.swift
    └── aggregateHourly, CodexStatus, color mappings
```

## 事件管道路径

```
硬件鼠标点击
  → WindowServer (CGEvent)
    → NSApplication.run() event loop
      → WidgetWindow.sendEvent(_:)     ← 入口，makeKeyAndOrderFront
        → WidgetHostingView.mouseDown   ← acceptsFirstMouse=true
          → SwiftUI Button action       ← fetcher.refresh()
```

## 关键决策记录（ADR）

### ADR-001: 移除 activate(ignoringOtherApps:)

**背景**: `.accessory` app 在 `kCGDesktopIconWindowLevel` 调用 `activate(ignoringOtherApps: true)` 可能触发 AppKit 内部死锁（窗口激活流程阻塞事件循环）。这是 macOS 26 行为变化。

**决定**: 移除所有 `activate` 调用，仅保留 `makeKeyAndOrderFront(nil)`。widget 本身是 accessory app，不需要"激活"到前台。

### ADR-002: WidgetHostingView 替代 NSHostingView

**背景**: `NSHostingView` 默认 `acceptsFirstMouse` 返回 `false`，在 accessory app + desktop-icon level 组合下，app 长时间不活跃后第一个点击被吞掉。

**决定**: 子类化 `NSHostingView`，override `acceptsFirstMouse` 返回 `true`，在 `mouseDown/rightMouseDown` 中主动 `makeKeyAndOrderFront`。

### ADR-003: host.menu 替代 NSEvent.localMonitorForEvents

**背景**: `NSEvent.addLocalMonitorForEvents` 只在 app 已经 active 时接收事件。accessory app 在 desktop-icon level 下可能永远不进入 active 状态。

**决定**: 设置 `host.menu = menu`，让 AppKit 通过 `NSView.menu` 属性自然处理右键菜单。移除 `popUpContextMenu` 调用（在 macOS 26 上不可靠）。

### ADR-004: fetchTask.cancel + loadingDeadline

**背景**: `guard !loading else { return }` 在 `fetch()` 被意外中断时永远拦住后续 `refresh()`。

**决定**: `refresh()` 先 `fetchTask?.cancel()`，再创建新 Task。`_fetch()` 内检查 `loadingDeadline`：如果 loading 已超过 35 秒，强制重置。

### ADR-005: CodexFetcher process.waitUntilExit

**背景**: `process.terminate()` 不保证进程立即退出。不调用 `waitUntilExit()` 导致子进程变 zombie，长时间运行后积累几十个僵尸进程。

**决定**: `terminate()` 后必须 `waitUntilExit()`。放在 `finish()` 闭包内，被 timeout DispatchWorkItem 或 readabilityHandler EOF 触发。

### ADR-006: 移除 .stationary

**背景**: `.stationary` 让窗口在 Mission Control 时不缩略。macOS 26 下可能影响事件路由。

**决定**: 仅保留 `.canJoinAllSpaces`。

## 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| Sources/App.swift | 修改 | WidgetWindow.sendEvent: makeKeyAndOrderFront + 无 activate |
| Sources/App.swift | 新增 | WidgetHostingView 泛型类 (acceptsFirstMouse + mouseDown/rightMouseDown) |
| Sources/App.swift | 修改 | NSHostingView → WidgetHostingView |
| Sources/App.swift | 修改 | remove NSEvent.localMonitor, set host.menu = menu |
| Sources/App.swift | 修改 | .stationary 移除 |
| Sources/App.swift | 修改 | weak var ww → var ww |
| Sources/DataFetcher.swift | 修改 | refresh(): fetchTask?.cancel + do/catch |
| Sources/DataFetcher.swift | 修改 | _fetch(): loadingDeadline 35s 超时防御 |
| Sources/DataFetcher.swift | 修改 | loadingDeadline 字段 |
| Sources/CodexFetcher.swift | 修改 | finish(): terminate + waitUntilExit + NSLog |
| Sources/CodexFetcher.swift | 修改 | terminationHandler: process.waitUntilExit |
| build.sh | 不变 | 已包含 CodexFetcher.swift |
