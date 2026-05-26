import Foundation

struct ChartBucket: Codable, Identifiable {
    let model: String; let timeBucket: String; let requests: Int
    let totalCost: Double; let tokensTotal: Int; let tokensIn: Int; let tokensOut: Int
    var id: String { "\(timeBucket)-\(model)" }
    var modelShort: String { model.contains("/") ? String(model.split(separator:"/").last!) : model }
}

struct SummaryResp: Codable {
    let totalCount: Int; let totalCost: Double; let totalTokens: String; let successRate: Double
}

struct CreditsResp: Codable { let credits: C2; struct C2: Codable { let monthlyCredits: Double } }

struct Portion: Codable, Identifiable {
    let model: String; let tokens: Int; let colorIdx: Int; var id: String { model }
}
struct HourBucket: Codable, Identifiable {
    let hour: String; let tokens: Int; let cost: Double; let requests: Int
    let portions: [Portion]; var id: String { hour }
    var hourInt: Int { Int(hour.split(separator:":").first ?? "0") ?? 0 }
}

func aggregateHourly(_ buckets: [ChartBucket]) -> [HourBucket] {
    let utcFmt = DateFormatter()
    utcFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    utcFmt.timeZone = TimeZone(identifier: "UTC")!
    
    let jstFmt = DateFormatter()
    jstFmt.dateFormat = "HH:00"
    jstFmt.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    
    var groups: [String:[ChartBucket]] = [:]
    for b in buckets {
        guard let utcDate = utcFmt.date(from: b.timeBucket) else {
            let h = String(b.timeBucket.split(separator:" ").last?.prefix(5) ?? "00:00")
            groups[h, default:[]].append(b)
            continue
        }
        let jstHour = jstFmt.string(from: utcDate)
        groups[jstHour, default:[]].append(b)
    }
    
    let result = groups.compactMap { h,bs in
        var mm: [String:Int] = [:]
        for b in bs { mm[b.modelShort, default:0] += b.tokensTotal }
        let ps = mm.map { Portion(model:$0.key, tokens:$0.value, colorIdx: colorIdxFor($0.key)) }
            .sorted { $0.tokens > $1.tokens }
        return HourBucket(hour:h, tokens:bs.reduce(0){$0+$1.tokensTotal},
                          cost:bs.reduce(0){$0+$1.totalCost},
                          requests:bs.reduce(0){$0+$1.requests}, portions:ps)
    }
    
    // Sort chronologically: find the largest gap between consecutive hours,
    // split there, and move the first segment to the end.
    let numeric = result.sorted { $0.hourInt < $1.hourInt }
    guard numeric.count > 1 else { return numeric }
    
    var bestGap = 0
    var splitIdx = numeric.count - 1
    for i in 0..<(numeric.count - 1) {
        let a = numeric[i].hourInt
        let b = numeric[i + 1].hourInt
        let gap = b - a  // simple diff, not wrapped
        if gap > bestGap { bestGap = gap; splitIdx = i }
    }
    
    // Only rotate when gap is large enough to indicate a day boundary
    // (e.g. 23 → 0 = -23 diff, or 22 → 1 = 3). Small holes in consecutive
    // data (15→17 gap=2) should NOT trigger a split.
    if bestGap >= 6 {
        let tail = Array(numeric[...splitIdx])
        let head = Array(numeric[(splitIdx + 1)...])
        return head + tail
    }
    return numeric
}

func colorIdxFor(_ m: String) -> Int {
    let l = m.lowercased()
    if l.contains("deepseek-v4-pro") { return 0 }
    if l.contains("deepseek-v4-flash") { return 1 }
    if l.contains("kimi-k2.5") { return 2 }
    if l.contains("kimi-k2.6") { return 3 }
    if l.contains("minimax") { return 4 }
    return 5
}
func colorFor(_ i: Int) -> (Double,Double,Double) {
    switch i {
    case 0: return (99,102,241); case 1: return (34,197,230)
    case 2: return (168,85,247); case 3: return (244,63,94)
    case 4: return (251,146,60); default: return (161,161,170)
    }
}

// MARK: - Codex

struct CodexRateLimitBucket: Codable {
    let usedPercent: Double
    let windowDurationMins: Int
    let resetsAt: Int  // Unix timestamp (seconds)
}

struct CodexRateLimits: Codable {
    let primary: CodexRateLimitBucket
    let secondary: CodexRateLimitBucket
    let planType: String
}

struct CodexRPCResult: Codable {
    let rateLimits: CodexRateLimits
}

struct CodexStatus {
    let planName: String?
    let primaryPercent: Double?
    let primaryReset: String?
    let secondaryPercent: Double?
    let secondaryReset: String?
    let error: String?

    static func from(rateLimits: CodexRateLimits) -> CodexStatus {
        let plan: String? = rateLimits.planType.isEmpty ? nil
            : rateLimits.planType.prefix(1).uppercased() + rateLimits.planType.dropFirst()

        func countdown(from unixTimestamp: Int) -> String {
            let reset = Date(timeIntervalSince1970: TimeInterval(unixTimestamp))
            let remaining = reset.timeIntervalSinceNow
            guard remaining > 0 else { return "0m" }
            let hours = remaining / 3600
            if hours >= 1 {
                return String(format: "%.1fh", hours)
            } else {
                let minutes = Int(remaining / 60)
                return "\(minutes)m"
            }
        }

        return CodexStatus(
            planName: plan,
            primaryPercent: 100 - rateLimits.primary.usedPercent,
            primaryReset: countdown(from: rateLimits.primary.resetsAt),
            secondaryPercent: 100 - rateLimits.secondary.usedPercent,
            secondaryReset: countdown(from: rateLimits.secondary.resetsAt),
            error: nil
        )
    }

    static func failed(_ msg: String) -> CodexStatus {
        CodexStatus(
            planName: nil,
            primaryPercent: nil,
            primaryReset: nil,
            secondaryPercent: nil,
            secondaryReset: nil,
            error: msg
        )
    }
}
