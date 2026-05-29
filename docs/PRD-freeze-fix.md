# PRD: Widget 长时间运行卡死彻底修复

> 日期: 2026-05-27
> 基于: `INVESTIGATION-freeze.md` 调查文档 + 历次修复经验
> 状态: 草案

## 目标

- 彻底解决 Command Code + Codex Desktop Widget 运行数小时后事件响应失灵（右键菜单、刷新按钮）的问题
- 同一修复方案同步应用到 CC-only 版本 (`commandcode-desktop-widget`)
- 修复后 widget 可连续运行 24 小时不重启不卡死

## 用户故事

- 作为桌面 widget 用户，我希望 widget 开机后常驻不重启，随时可以刷新和右键操作

## 功能范围

### In Scope

- 事件管道稳定性修复（sendEvent / mouseDown / rightMouseDown）
- SwiftUI 与 AppKit 事件路由的可靠性保证
- 子进程生命周期管理（CodexFetcher Process 回收）
- 数据获取任务状态管理（loading 死锁防御、Task 取消）
- 运行时诊断日志（用于后续排查）

### Out of Scope

- 功能新增
- UI 样式变更
- 窗口层级或大小调整

## 技术约束

- macOS 26.5，swiftc 命令行编译，不需要 Xcode
- kCGDesktopIconWindowLevel（壁纸层上方、普通窗口下方）
- .accessory activation policy（无 Dock 图标）
- 不能引入新的框架依赖
- 所有修复必须同步到两个仓库

## 质量标准

- 连续运行 24 小时，右键菜单和刷新按钮均可正常响应
- Codex 子进程无泄漏（`pgrep -P <widget_pid>` 始终为空）
- 无 "Publishing changes from background threads" 警告
- 编译 0 warning

## 已验证的根因（调查阶段确认）

| # | 根因 | 状态 | 来源 |
|---|------|------|------|
| 1 | `NSHostingView` 不接受 inactive window 的 first mouse | 已修复 | 调查文档 3.2 |
| 2 | `NSEvent.addLocalMonitorForEvents` 在 accessory app 不可靠 | 已修复 | 调查文档 3.1 |
| 3 | `NSApplication.shared.activate(ignoringOtherApps:)` 可能阻塞事件循环 | 已修复 | 调查文档 3.1 |
| 4 | `.stationary` collectionBehavior 影响事件路由 | 已修复 | 调查文档 3.6 |
| 5 | `loading` 标记因 Task 异常未被 defer 重置 | 已修复 | 调查文档 3.1 |
| 6 | CodexFetcher `process.terminate()` 后未 `waitUntilExit()` 回收 zombie | 已修复 | 调查文档 3.4 |
| 7 | CodexFetcher `readabilityHandler` 闭包捕获过期状态导致僵尸进程 | 未验证 | 调查文档 3.4 |
| 8 | 旧进程未重启，所有修复从未生效 | **当前问题** | 本次诊断 |
