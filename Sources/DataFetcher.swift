import Foundation
import AppKit

@MainActor
class DataFetcher: ObservableObject {
    @Published var hourly: [HourBucket] = []
    @Published var summary: SummaryResp?
    @Published var credits: CreditsResp.C2?
    @Published var codexStatus: CodexStatus?
    @Published var loading = false
    @Published var error: String?
    private var timer: Timer?
    private var codexTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var loadingDeadline: Date?
    
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: c)
    }()
    
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2*60, repeats: true) { [weak self] _ in
            NSLog("[DBG] Timer fired, calling refresh()")
            Task { @MainActor in self?.refresh() }
        }
        var pending: Task<Void, Never>?
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            pending?.cancel()
            pending = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                NSLog("[DBG] didBecomeActive + 0.5s debounce, calling refresh()")
                self?.refresh()
            }
        }
    }
    func stop() { timer?.invalidate() }
    func refresh() {
        NSLog("[DBG] DataFetcher.refresh() called loading=\(loading)")
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            guard let self else { return }
            do { try await self._fetch() }
            catch { NSLog("[DBG] fetch() threw: \(error)") }
        }
    }
    
    /// Actual fetch work — structured so defer always runs.
    private func _fetch() async throws {
        guard !loading || loadingDeadline.map({ Date().timeIntervalSince($0) > 35 }) ?? true else {
            NSLog("[DBG] _fetch() blocked — loading still true, deadline not expired")
            return
        }
        NSLog("[DBG] _fetch() enter")
        loading = true; error = nil; loadingDeadline = Date()
        defer { loading = false; loadingDeadline = nil; NSLog("[DBG] _fetch() exiting, set loading=false") }
        
        // Start Codex fetch in parallel (decoupled from CC data).
        // Cancel any in-flight Codex fetch and use [weak self] to match project pattern.
        codexTask?.cancel()
        codexTask = Task.detached { [weak self] in
            let codexResult = await CodexFetcher.fetch()
            guard let self else { return }
            await MainActor.run {
                self.codexStatus = codexResult ?? CodexStatus.failed("Unavailable")
            }
        }
        
        guard let tok = await TokenExtractor.extract() else {
            error = "Sign in with Firefox → Command Code"; return
        }
        
        let result = await withTimeout(25) { await self.fetchData(tok) }
        if Task.isCancelled { return }
        
        switch result {
        case .timeout: error = "Network timeout"
        case .success(let (h, s, c)):
            if let h = h { hourly = h }
            if let s = s { summary = s }
            if let c = c { credits = c }
        }
        
        try? await Task.sleep(nanoseconds: 600_000_000)
    }
    
    private nonisolated func fetchData(_ tok: String) async -> ([HourBucket]?, SummaryResp?, CreditsResp.C2?) {
        struct CR: Codable { let data: [ChartBucket] }
        async let c: CR? = get("https://api.commandcode.ai/internal/usage/charts", tok)
        async let s: SummaryResp? = get("https://api.commandcode.ai/internal/usage/summary", tok)
        async let b: CreditsResp? = get("https://api.commandcode.ai/internal/billing/credits", tok)
        let (cc, ss, bb) = await (c, s, b)
        return (cc.map { aggregateHourly($0.data) }, ss, bb?.credits)
    }
    
    private nonisolated func get<T: Codable>(_ u: String, _ tok: String) async -> T? {
        guard let url = URL(string: u) else { return nil }
        var r = URLRequest(url: url)
        r.setValue("\(TokenExtractor.name)=\(tok)", forHTTPHeaderField: "Cookie")
        r.timeoutInterval = 15
        do {
            let (d, resp) = try await DataFetcher.session.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(T.self, from: d)
        } catch { return nil }
    }
}

// MARK: - Task timeout

enum TimeoutResult<T> { case success(T), timeout }

private func withTimeout<T>(_ seconds: Double, _ op: @escaping () async -> T) async -> TimeoutResult<T> {
    do {
        let value = try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        return .success(value)
    } catch {
        return .timeout
    }
}
