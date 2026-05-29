import SwiftUI
import AppKit

class WidgetState: ObservableObject {
    @Published var dragging = false
    @Published var focused = false
}

func shortName(_ m: String) -> String {
    let l = m.lowercased()
    if l.contains("deepseek-v4-pro")  { return "DeepSeek-V4-Pro" }
    if l.contains("deepseek-v4-flash") { return "DeepSeek-V4-Flash" }
    if l.contains("kimi-k2.5")         { return "Kimi-K2.5" }
    if l.contains("kimi-k2.6")         { return "Kimi-K2.6" }
    if l.contains("minimax")           { return "MiniMax" }
    return m
}

// MARK: - Bar Chart

struct BarChartView: View {
    let buckets: [HourBucket]
    @State private var hovered: HourBucket?
    private let mh: CGFloat = 130; private let bw: CGFloat = 26; private let sp: CGFloat = 14
    
    private var sampled: [HourBucket] {
        let ct = buckets.count; guard ct > 0 else { return [] }
        let start = max(0, ct - 10)
        return Array(buckets[start..<ct])
    }
    private var maxT: Int { sampled.map(\.tokens).max() ?? 1 }
    
    var allModels: [(String,String,Int)] {
        var seen: [String:(String,Int,Int)] = [:]
        for b in buckets { for p in b.portions {
            if seen[p.model] == nil { seen[p.model] = (shortName(p.model),p.tokens,p.colorIdx) }
            else { seen[p.model] = (seen[p.model]!.0, seen[p.model]!.1+p.tokens, p.colorIdx) }
        }}
        return seen.map { ($0.key, $0.value.0, $0.value.2) }.sorted { seen[$0.0]!.1 > seen[$1.0]!.1 }
    }
    
    var body: some View {
        if buckets.isEmpty { emptyState }
        else { chartBody }
    }
    
    private var chartBody: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                HStack(alignment: .bottom, spacing: sp) {
                    ForEach(sampled) { b in bar(b) }
                }.frame(height: mh + 4)
                
                HStack(spacing: sp) {
                    ForEach(sampled) { b in
                        Text("\(Int(b.hour.split(separator:":").first ?? "0") ?? 0)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.5)).frame(width: bw)
                    }
                }.padding(.top, 4)
                
                HStack(spacing: 12) {
                    ForEach(allModels, id: \.0) { m in
                        HStack(spacing: 4) {
                            Circle().fill(c(m.2)).frame(width: 6, height: 6)
                            Text(m.1).font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.65))
                        }
                    }
                }.padding(.top, 8)
            }
            
            if let b = hovered {
                tooltip(b).offset(y: -10)
            }
        }
    }
    
    private func bar(_ b: HourBucket) -> some View {
        let t = b.tokens; let h = t > 0 ? max(CGFloat(t)/CGFloat(maxT) * mh, 2) : 0
        let ps = b.portions.sorted { p1, p2 in
            let o1 = p1.colorIdx == 0 ? 4 : p1.colorIdx == 1 ? 0 : p1.colorIdx
            let o2 = p2.colorIdx == 0 ? 4 : p2.colorIdx == 1 ? 0 : p2.colorIdx
            return o1 < o2
        }
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(ps) { p in
                    let r = t > 0 ? CGFloat(p.tokens)/CGFloat(t) : 0
                    Rectangle().fill(c(p.colorIdx).opacity(0.85))
                        .frame(width: bw, height: max(r * h, 0.5))
                }
            }.frame(height: h).clipShape(RoundedRectangle(cornerRadius: 4))
        }.frame(height: mh, alignment: .bottom)
        .onHover { v in withAnimation(.easeInOut(duration: 0.1)) { hovered = v ? b : nil } }
    }
    
    private func tooltip(_ b: HourBucket) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(b.hour).font(.system(size: 14, weight: .semibold, design: .monospaced))
            Text("\(b.requests) req · $\(String(format: "%.3f", b.cost))")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Divider().opacity(0.3)
            ForEach(b.portions) { p in
                HStack(spacing: 6) {
                    Circle().fill(c(p.colorIdx)).frame(width: 6, height: 6)
                    Text(shortName(p.model)).font(.system(size: 10)).foregroundColor(.secondary)
                    Spacer()
                    Text(fmt(p.tokens)).font(.system(size: 11, weight: .medium, design: .monospaced))
                }
            }
        }.padding(.horizontal, 14).padding(.vertical, 11).frame(width: 220)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
    }
    
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 20, weight: .light)).foregroundColor(.secondary.opacity(0.3))
            Text("No data").font(.system(size: 12)).foregroundColor(.secondary)
        }.frame(height: mh)
    }
    private func c(_ i: Int) -> Color { let (r,g,b)=colorFor(i); return Color(red:r/255,green:g/255,blue:b/255) }
    private func fmt(_ n: Int) -> String {
        n>=1_000_000 ? String(format:"%.1fM",Double(n)/1_000_000) : n>=1_000 ? String(format:"%.1fK",Double(n)/1_000) : "\(n)"
    }
}

// MARK: - Window (forces key-ready even at desktop-icon level)

class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
    /// Any mouse click makes this borderless desktop-level window active/key again.
    /// NOTE: no activate(ignoringOtherApps:) — it can block the event loop on .accessory apps.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            let wasKey = isKeyWindow
            if !wasKey { makeKeyAndOrderFront(nil) }
            dbg("[DBG] WidgetWindow.sendEvent type=\(event.type.rawValue) wasKey=\(wasKey)")
        }
        super.sendEvent(event)
    }
}

/// NSHostingView normally does not accept the first click after the app/window is inactive.
/// For a desktop widget, that makes the refresh button and context menu feel "stuck".
final class WidgetHostingView<Content: View>: NSHostingView<Content> {
    var widgetMenu: NSMenu?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dbg("[DBG] WidgetHostingView.mouseDown")
        window?.makeKeyAndOrderFront(nil)
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        dbg("[DBG] WidgetHostingView.rightMouseDown hasMenu=\(widgetMenu != nil)")
        window?.makeKeyAndOrderFront(nil)
        super.rightMouseDown(with: event)  // let AppKit handle menu via host.menu
    }
}

// MARK: - Content

struct ContentView: View {
    @EnvironmentObject var fetcher: DataFetcher
    @EnvironmentObject var state: WidgetState
    
    var body: some View {
        ZStack {
            Rectangle().fill(state.focused ? .regularMaterial : .ultraThinMaterial)
            
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                chartContent
                Spacer(minLength: 0)
                footer
                codexRow
            }.padding(16)
            
            if state.dragging {
                RoundedRectangle(cornerRadius:22).strokeBorder(.white.opacity(0.4), lineWidth: 2.5).padding(1).allowsHitTesting(false)
            }
        }
        .frame(width: 432, height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(state.focused ? .white.opacity(0.12) : .white.opacity(0.04), lineWidth: 0.5))
    }
    
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "command").font(.system(size: 13, weight: .bold)).foregroundColor(.secondary.opacity(0.7))
                .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.06)))
            Text("Command Code").font(.system(size: 13, weight: .semibold)).tracking(-0.2)
            Spacer()
            if let c = fetcher.credits {
                HStack(spacing: 4) {
                    Circle().fill(c.monthlyCredits > 1 ? .green : .orange).frame(width: 5, height: 5)
                    Text(String(format: "$%.2f", c.monthlyCredits)).font(.system(size: 13, weight: .medium, design: .monospaced))
                    Text("Credits").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            Button(action: { fetcher.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.4))
                    .rotationEffect(.degrees(fetcher.loading ? 360 : 0))
                    .animation(fetcher.loading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: fetcher.loading)
            }.buttonStyle(.plain).disabled(fetcher.loading)
        }
    }
    
    private var chartContent: some View {
        Group {
            if let err = fetcher.error {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 20)).foregroundColor(.orange.opacity(0.6))
                    Text(err).font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button("Retry"){ fetcher.refresh() }.font(.system(size: 12)).buttonStyle(.plain).foregroundColor(.accentColor)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if fetcher.loading && fetcher.hourly.isEmpty {
                VStack(spacing: 6){ ProgressView().scaleEffect(0.8); Text("Loading...").font(.system(size: 12)).foregroundColor(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BarChartView(buckets: fetcher.hourly)
            }
        }
    }
    
    private var footer: some View {
        if let s = fetcher.summary {
            return AnyView(HStack(spacing: 0) {
                Spacer(); stat(String(format: "$%.2f", s.totalCost), "Cost")
                Spacer(); Rectangle().fill(.white.opacity(0.05)).frame(width: 1, height: 22)
                Spacer(); stat(fmt(Int(s.totalTokens) ?? 0), "Tokens")
                Spacer(); Rectangle().fill(.white.opacity(0.05)).frame(width: 1, height: 22)
                Spacer(); stat("\(s.totalCount)", "Runs"); Spacer()
            }.padding(.top, 4))
        }
        return AnyView(EmptyView())
    }
    private func stat(_ v: String, _ l: String, c: Color = .primary) -> some View {
        VStack(spacing: 1) {
            Text(v).font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundColor(c)
            Text(l).font(.system(size: 9, weight: .medium)).foregroundColor(.secondary.opacity(0.6)).textCase(.uppercase).tracking(0.4)
        }
    }

    private var codexRow: some View {
        Group {
            if let cs = fetcher.codexStatus {
                if let plan = cs.planName {
                    HStack(spacing: 0) {
                        Spacer()
                        Image(systemName: "cpu")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text(" Codex \(plan) ")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.7))
                        Rectangle().fill(.white.opacity(0.06)).frame(width: 1, height: 18)
                        if let pp = cs.primaryPercent {
                            HStack(spacing: 0) {
                                Text("5h: ").foregroundColor(.secondary.opacity(0.7))
                                Text("\(String(format: "%.0f", pp))%")
                                    .foregroundColor(.primary)
                            }
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            if let pr = cs.primaryReset {
                                Text(" (\(pr))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.primary.opacity(0.6))
                            }
                        }
                        Rectangle().fill(.white.opacity(0.06)).frame(width: 1, height: 18)
                        if let sp = cs.secondaryPercent {
                            HStack(spacing: 0) {
                                Text("7d: ").foregroundColor(.secondary.opacity(0.7))
                                Text("\(String(format: "%.0f", sp))%")
                                    .foregroundColor(.primary)
                            }
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            if let sr = cs.secondaryReset {
                                Text(" (\(sr))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.primary.opacity(0.6))
                            }
                        }
                        Spacer()
                    }
                    .padding(.top, 6)
                } else {
                    HStack(spacing: 4) {
                        Spacer()
                        Image(systemName: "cpu")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.3))
                        Text(cs.error ?? "Unavailable")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.35))
                        Spacer()
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private func fmt(_ n: Int) -> String {
        n>=1_000_000 ? String(format:"%.1fM",Double(n)/1_000_000) : n>=1_000 ? String(format:"%.1fK",Double(n)/1_000) : "\(n)"
    }
}

// MARK: - App

@main
enum AppLauncher { static func main() { WidgetAppDelegate.run() } }

@MainActor
class WidgetAppDelegate: NSObject, NSApplicationDelegate {
    let fetcher = DataFetcher()
    let state = WidgetState()
    var ww: NSWindow?
    
    static func run() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let d = WidgetAppDelegate(); _d = d; app.delegate = d; app.run()
    }
    private static var _d: WidgetAppDelegate?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let sz = CGSize(width: 432, height: 340)
        let win = WidgetWindow(contentRect: NSRect(origin: .zero, size: sz),
                           styleMask: [.borderless, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = false
        win.isMovableByWindowBackground = true; win.isMovable = true
        win.collectionBehavior = [.canJoinAllSpaces]
        win.minSize = sz; win.maxSize = sz; ww = win
        
        let view = ContentView().environmentObject(fetcher).environmentObject(state)
        let host = WidgetHostingView(rootView: view); host.frame.size = sz
        host.autoresizingMask = [.width, .height]; win.contentView = host
        host.wantsLayer = true; host.layer?.cornerRadius = 22; host.layer?.masksToBounds = true

        let menu = NSMenu()
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(menuRefresh), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = []
        quitItem.target = self
        menu.addItem(quitItem)
        host.widgetMenu = menu
        host.menu = menu  // fallback for AppKit's native contextual-menu path

        if let scr = NSScreen.main {
            let sf = scr.visibleFrame
            win.setFrameOrigin(NSPoint(x: round(sf.maxX - sz.width - 24), y: round(sf.maxY - sz.height - 24)))
        }
        
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: win, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.focused = true }
        }
        nc.addObserver(forName: NSWindow.didResignKeyNotification, object: win, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.focused = false }
        }
        nc.addObserver(forName: NSWindow.willMoveNotification, object: win, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.dragging = true }
        }
        nc.addObserver(forName: NSWindow.didMoveNotification, object: win, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.state.dragging = false
                guard let w = self?.ww, let scr = w.screen else { return }
                let sf = scr.visibleFrame; let g: CGFloat = 24
                var o = w.frame.origin
                o.x = round((o.x - sf.minX) / g) * g + sf.minX
                o.y = round((o.y - sf.minY) / g) * g + sf.minY
                o.x = max(sf.minX, min(o.x, sf.maxX - w.frame.width))
                o.y = max(sf.minY, min(o.y, sf.maxY - w.frame.height))
                w.setFrameOrigin(o)
            }
        }
        win.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: false)
        fetcher.start()
    }
    
    @objc func menuRefresh() { fetcher.refresh() }
    @objc func menuQuit() { NSApplication.shared.terminate(nil) }
}
