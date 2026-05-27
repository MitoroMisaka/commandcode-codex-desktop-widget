# Widget 卡死问题调查方案

> 状态: 调查中 | 日期: 2026-05-27
> 影响范围: commandcode-codex-desktop-widget (同架构 commandcode-desktop-widget 大概率也受影响)
> 现象: widget 运行一段时间后（数分钟到数小时不等），右键菜单点不出来，刷新按钮按了没反应，但外观正常（数据可能已停滞或不更新）。

---

## 一、症状澄清

| 表现 | 可能性 | 说明 |
|------|--------|------|
| 右键菜单不弹出 | 高 | 每次都出现 |
| 刷新按钮点了没反应 | 高 | 每次都出现 |
| 数据还显示但不更新 | 中 | 不一定同步出现 |
| widget 还能拖动 | ? | 待确认。如果还能拖动说明 NSWindow 自身事件循环正常；如果不能拖动说明整个事件管道卡死了 |
| spinning 动画还在转 | ? | 待确认。如果 loading spinner 还在转说明 SwiftUI 渲染循环正常；如果不转说明 SwiftUI 的 animated binding 也停滞了 |
| 重启后恢复正常 | 是 | 确认是运行时累积状态导致，不是 build/配置问题 |

调查第一步就是确认哪些还能互动、哪些不行，缩小范围。

---

## 二、故障分层模型

一个 macOS desktop widget 的事件管道路径：

```
硬件鼠标事件
  → WindowServer (CGEvent)
    → NSApplication.run() event loop
      → _DPSNextEvent (AppKit)
        → NSWindow.sendEvent (分发到窗口)
          → WidgetWindow.sendEvent (我们的子类，尝试 makeKeyAndOrderFront)
          → NSHostingView/WidgetHostingView 接收鼠标事件
            → SwiftUI Button 或 Gesture recognizer 得到事件
```

无论哪个环节断了，表现都是"点了没反应"。但断在不同环节意味着不同的根因。

---

## 三、可能的根因分类

### 3.1 事件管道阻塞（Event Pipeline Blocking）

**现象**: 整个 widget 都不响应交互。

**候选原因**:

1. `sendEvent` 里的 `NSApplication.shared.activate(ignoringOtherApps: true)` 死锁。
   - 旧代码有 `makeKey()`，新代码改成了 `makeKeyAndOrderFront + activate`，在 `.accessory` activation policy + `.desktopIconWindow` level 下，`activate(ignoringOtherApps: true)` 可能在特定窗口状态组合下阻塞等待另一个无法到来的 runloop 事件。
   - **诊断方法**: sample 进程看主线程调用栈。如果卡在 `activate` → `_activateApplication_Common` → mach_msg，这就是死锁。
   - **验证方案**: 临时注释掉 `activate(ignoringOtherApps: true)`，只保留 `makeKeyAndOrderFront(nil)`，观察是否还卡。

2. 上一次 `fetch()` 的 `Task { await fetch() }` 没有正确完成/取消，导致 `guard !loading else { return }` 永远拦住了后续 `refresh()`。
   - `defer { loading = false }` 应该在所有 exit path 释放 loading，但如果 `fetch()` 的 Task 本身被 leak（比如 `self` 被强引用导致 deinit 不触发），那 `loading` 可能永远不会重置。
   - **诊断方法**: 在 `fetch()` 入口和 `defer` 出口各加一行 `print(">>> fetch enter/exit", Date())`，编译后跑一段时间看 console 输出是否出现 enter 多次但 exit 只一次的情况。
   - **验证**: 把 `loading` 加上超时自动重置——如果 `loading == true` 超过 35 秒（最长 fetch 是 25s timeout + 0.6s spinner 延迟），强制重置 `loading = false`。

3. `DataFetcher.fetch()` 抛异常未捕获导致 Task 泄漏。
   - `fetch()` 是 `async`，调用方是 `func refresh() { Task { await fetch() } }`，没有 `try/catch`。如果 `fetch()` 内部抛出未捕获的 error，Task 会静默失败，`defer` 可能不执行（取决于抛出位置）。
   - **诊断方法**: 在 `refresh()` 里包一层 `do/catch`: `Task { do { try await fetch() } catch { print("refresh error:", error) } }`。

### 3.2 SwiftUI View 重建风暴（View Identity / Body Storm）

**现象**: widget 仍有响应但极慢，或者 SwiftUI button 的 action 闭包被替换导致旧闭包指向了已释放的 `fetcher`。

**候选原因**:

4. `fetcher.loading` 切换导致 Button 被禁用/重建，SwiftUI diff 改变了 button 的内部 identity。
   - `Button(action: { fetcher.refresh() })` 中 `fetcher` 是 `@EnvironmentObject`。如果 `ContentView` 被重建且 `fetcher` 引用被替换……
   - 但实际上 `fetcher` 是 `let` 常量，不会变。可能性低。
   - **诊断方法**: 在 `refresh()` 和 button action 里加 `print`，看点击时是否真的跑到了 `refresh()`。

5. `@Published` 属性写入后台线程导致 SwiftUI 内部状态不一致。
   - memory 里已记录过这个问题（"Publishing changes from background threads is not allowed"）。`DataFetcher` 标记了 `@MainActor`，但 `CodexFetcher.fetch()` 的回调里 `self.codexStatus = ...` 通过 `Task.detached { [weak self] ... await MainActor.run { self.codexStatus = ... } }` —— 这里有 `MainActor.run` 应该是安全的。
   - `TokenExtractor.extract()` 在 `Task.detached(priority: .utility)` 中运行，但 `extract()` 返回 `String?`，调用方 `fetch()` 是 `@MainActor` 的 `async` 方法，await 后会自动回到 MainActor。
   - **诊断方法**: 加 MainActor.assertIsolated() 断言在 `fetch()` 的关键赋值点。

### 3.3 僵尸窗口 / Window Server 状态丢失（Zombie Window）

**现象**: widget 外观正常（渲染在 layer 上），但 NSWindow 对象内部状态异常，不接收事件。

6. `kCGDesktopIconWindowLevel` + `collectionBehavior = [.canJoinAllSpaces, .stationary]` 在 macOS 26 上的行为变化。
   - `canJoinAllSpaces` 让窗口在 Spaces 切换时始终可见，但可能在某些场景下窗口 level 被 WindowServer 下调、或事件 mask 被修改。
   - `stationary` 让窗口在 Mission Control 不缩略，可能影响事件路由。
   - **诊断方法**: 卡住时运行 `GetWindowBounds` / Accessibility Inspector 看窗口的 `CGWindowID` 是否仍可被事件命中。
   - **验证方案**: 去掉 `.stationary`，只保留 `.canJoinAllSpaces` 试试。或者完全去掉 collectionBehavior 看是否还会卡。

7. NSWindow 被系统隐式回收/替换。
   - 如果 NSApplication 的 key window 被其他窗口抢占，desktop-icon level 窗口可能会被降级。
   - **诊断方法**: 卡住时用 `osascript -e 'tell app "System Events" to get windows of process "CommandCodeCodexWidget"'` 看窗口列表。

### 3.4 内存 / 引用循环（Memory / Reference Cycles）

8. `ww` 从 `weak var` 改为 `var`（strong）是否导致 deinit 不触发。
   - `WidgetAppDelegate` 是单例（`static var _d`），强持有 `ww`（NSWindow），NSWindow 强持有 `contentView`（NSHostingView），NSHostingView 持有 SwiftUI 视图树。
   - 这不是泄漏——这是正常的持有链。Widget 本来就是设计为永久存在的。改成 strong 只是防止 `ww` 被提前释放。
   - 但 `fetcher` 作为 `@EnvironmentObject` 被 SwiftUI 视图树持有，`fetcher` 的 `Timer` 持有 `self`（weak），`NotificationCenter` observer 持有 `self`（weak）。这些看起来都是 weak，应该安全。
   - **诊断方法**: Instruments Leaks / Allocations，看是否有意外堆积的 Task 对象。

9. `CodexFetcher` 残留的 `Process` 对象。
   - `finish()` 里调了 `process.terminate()`，但如果 `terminationHandler` 里有异常、或者 process 是 zombie 状态，可能留下僵尸子进程。
   - 之前 `ps` 输出显示 PID 16868 的 Codex app-server 运行了 8 个多小时。这意味着之前的某次 fetch 没有正确 terminate 它的 process。
   - **诊断方法**: 卡住时 `pgrep -P <widget_pid>` 看有多少僵尸子进程。如果每次 fetch 都泄露一个 Codex 进程，两分钟一次、几小时内就会堆几十个 zombie。
   - **验证方案**: 在 `finish()` 里加 `process.waitUntilExit()`。

### 3.5 Timer / RunLoop 相关

10. Timer 被调度在 non-default runloop mode。
    - `Timer.scheduledTimer(withTimeInterval:repeats:block:)` 默认加到 `.default` runloop mode。当窗口 tracking（拖动滚动条、resize）或 modal dialog 时，runloop 切换到其他 mode，timer 不触发。
    - 对于 desktop widget，这不太可能是主因——没有 scroll view、没有 modal dialog。
    - **诊断方法**: 确认 Timer 是否真在触发。在 timer block 里加 `print`。

### 3.6 macOS 26 特定的 API 变化

11. `NSMenu.popUpContextMenu` 的行为变化。
    - macOS 26 可能改了 context menu 的 API。`popUpContextMenu` 需要 view 在 window 的 view hierarchy 中、且 window 能接收事件。
    - **诊断方法**: 换回 `.menu` 属性方式，在 `rightMouseDown` 里只做 `super.rightMouseDown(with: event)`，让 AppKit 自己处理右键菜单（不调用 `popUpContextMenu`）。

12. `NSApplication.shared.activate(ignoringOtherApps: true)` 在 `.accessory` 策略下可能不生效或需要额外条件。
    - **验证方案**: 改用 `NSApp.activate()` 或 `NSApp.unhide(nil)`。

---

## 四、诊断工具包

### 4.1 快速诊断（不需要重新编译）

卡住时运行这些命令：

```bash
# 1. 看进程状态
PID=$(pgrep -f CommandCodeCodexWidget | head -1)
ps -o pid,stat,etime,pcpu,pmem,command -p "$PID"

# 2. 看主线程是否卡在某个调用
sample "$PID" 3 -file /tmp/ccwx.sample 2>&1
# 检查主线程 (Thread_0 / DispatchQueue main-thread) 的调用栈

# 3. 看子进程泄露
pgrep -P "$PID" -fl .  # 看有多少 Codex 僵尸进程

# 4. 看窗口是否还"存在"
osascript -e "tell app \"System Events\" to get windows of process \"CommandCodeCodexWidget\""

# 5. 看 AppKit 事件计数（如果卡在事件循环里，这里会显示很多 pending events）
sudo dtrace -n 'objc$target:AppKit:-[NSWindow sendEvent:]:entry { @c[probefunc] = count(); }' -p "$PID"
```

### 4.2 调试日志版本

在关键点加 `NSLog` 或 `print`，编译部署后收集日志：

```swift
// DataFetcher.swift - fetch() 入口/出口
NSLog("[Widget] fetch() enter loading=\(loading)")
defer { NSLog("[Widget] fetch() exit loading=false") }

// DataFetcher.swift - refresh() 入口
NSLog("[Widget] refresh() called loading=\(loading)")

// App.swift - sendEvent
NSLog("[Widget] sendEvent type=\(event.type.rawValue) keyWindow=\(isKeyWindow)")

// App.swift - WidgetHostingView mouseDown/rightMouseDown
NSLog("[Widget] mouseDown/rightMouseDown")

// CodexFetcher.swift - finish()
NSLog("[Widget] Codex finish status=\(status) running=\(process.isRunning)")
NSLog("[Widget] Codex finish pid=\(process.processIdentifier)")
```

部署后:

```bash
# 实时查看日志
log stream --predicate 'process == "CommandCodeCodexWidget"' --level debug
# 或者
tail -f /var/log/system.log | grep Widget
```

### 4.3 Instruments / Xcode Performance Tools

即使不用 Xcode 构建，也可以 attach Xcode Instruments 到运行中的进程:

```bash
# 用 Activity Monitor → 选中进程 → View → Sample Process (⌥⌘S)
# 或命令行
sample <pid> 5
```

`spindump` 也可以:

```bash
sudo spindump <pid> -o /tmp/spindump.txt
# 在 /tmp/spindump.txt 里搜索 "HANG" 查看卡顿报告
```

---

## 五、排查执行顺序（从最可能到最不确定）

按优先级排列:

### Step 1: 通用诊断 — 确认卡住的具体状态

不用改代码。直接 `sample` + `pgrep -P`。

**目标**: 回答三个关键问题:
1. 主线程卡在哪里（mach_msg 等待事件？还是在某个 GCD queue 上阻塞？）
2. 有没有泄漏的 Codex 子进程？
3. 窗口本身是否还响应 CGEvent？

### Step 2: 确认是"整个事件管道断了"还是"只是 SwiftUI 按钮不触发"

在 `refresh()` 第一行加 `NSLog("[Widget] refresh called")`，编译部署。
如果卡住时点刷新按钮能看到日志 → 事件管道通的，问题在 `fetch()` 内部。
如果看不到日志 → 事件根本没有到达 SwiftUI，问题在 AppKit 层面。

### Step 3: 减少 `activate` 的调用

把 `WidgetHostingView.mouseDown/rightMouseDown` 和 `WidgetWindow.sendEvent` 里的 `NSApplication.shared.activate(ignoringOtherApps: true)` 注释掉，只保留 `makeKeyAndOrderFront(nil)`。

观察是否还卡。

原因: `activate` 在 `.accessory` app 里可能触发复杂的窗口激活流程，在特定条件下阻塞。

### Step 4: 修复 Codex 进程泄漏

在 `CodexFetcher.finish()` 里 `process.terminate()` 之后加 `process.waitUntilExit()`，确保子进程被回收。

观察卡住时的子进程数量。

### Step 5: 回到 `NSView.menu` 方式

去掉 `popUpContextMenu`，恢复为 `host.menu = menu` 属性赋值（旧方式）。
在 `sendEvent` 里做 `makeKeyAndOrderFront` 确保窗口收到焦点后再让 AppKit 处理 menu。

### Step 6: Timer 和 loading 死锁防御

在 `fetch()` 入口加超时防御:

```swift
private func fetch() async {
    guard !loading else {
        // Defensive: if loading is stuck for >35s, reset it
        return
    }
    // ... existing code ...
}
```

### Step 7: 窗口层级试验

改 `collectionBehavior`:
- 去 `.stationary`
- 试 `.managed` 或空数组
- 试 `NSWindow.Level.floating` 替代 `kCGDesktopIconWindowLevel`

---

## 六、可立即实施的防御性修复

无需等待复现，这些改动可以在问题定位前先合入，减少卡死概率:

### 6.1 添加 `fetch()` 超时重置 loading

```swift
// DataFetcher.swift
private var fetchTask: Task<Void, Never>?

func refresh() {
    fetchTask?.cancel()
    fetchTask = Task { await fetch() }
}
```

如果之前的 Task 因为某种原因没完成，新的 refresh 会取消并替换它。

### 6.2 Codex 子进程回收

```swift
// CodexFetcher.swift finish() 里
if process.isRunning {
    process.terminate()
    process.waitUntilExit()  // ← 加这行，回收 zombie
}
```

### 6.3 移除 collectionBehavior 中的 `.stationary`

`.stationary` 是非常特殊的行为，在 macOS 26 可能有副作用。先去掉验证。

---

## 七、等待用户提供的信息

为了进一步缩小范围，需要用户帮忙确认:

1. 卡住时，**widget 还能拖动吗**？（用鼠标拖动 widget 窗口）
   - 能拖动 → 事件管道至少在 AppKit 层面还在工作
   - 不能拖动 → 整条事件管道停滞了

2. 卡住时，**上面的 loading spinner 还在转吗**？（如果是刚刷新完卡住的可能不转）
   - 在转 → SwiftUI 渲染循环正常，只是按钮不触发
   - 不转 → SwiftUI body 不再重新计算

3. **大约多久会卡住**？（每次都是固定时间？有时几分钟有时几小时？）
   - 固定时间 → 可能跟每次 fetch 周期有关（2分钟一次）
   - 不定 → 可能跟特定事件有关（网络断开、Codex 进程异常等）

4. **widget 卡住的时候，Codex 信息（cpu 那行）还显示吗**？
   - 还显示 → Codex fetch 至少成功过一次
   - 显示 "Unavailable" → 最后一次 Codex fetch 失败了
   - 根本不显示 → codexStatus 是 nil

---

## 八、变更记录

| 日期 | 操作 | 说明 |
|------|------|------|
| 2026-05-27 | 初始文档 | 针对反复出现的事件响应失灵问题，列出 12 种可能根因和分步调查方案 |
