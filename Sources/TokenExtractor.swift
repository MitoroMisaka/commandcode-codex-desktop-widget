import Foundation

enum TokenExtractor {
    static let db = NSHomeDirectory() + "/Library/Application Support/Firefox/Profiles/7wpm1h7n.default-release/cookies.sqlite"
    static let name = "__Secure-commandcode_prod_.session_token"
    
    /// Runs cp + sqlite3 off the main thread. Firefox's cookies.sqlite can be
    /// 500KB+ with a WAL file; blocking the main actor on these synchronous
    /// Process calls freezes the UI (especially the spinner animation).
    static func extract() async -> String? {
        await Task.detached(priority: .utility) {
            let tmp = "/tmp/cc_\(ProcessInfo.processInfo.processIdentifier).sqlite"
            let cp = Process(); cp.executableURL = URL(fileURLWithPath:"/bin/cp"); cp.arguments=[db,tmp]
            try? cp.run(); cp.waitUntilExit()
            guard cp.terminationStatus == 0 else { return nil }
            defer { try? FileManager.default.removeItem(atPath:tmp) }
            
            let sql = Process(); sql.executableURL = URL(fileURLWithPath:"/usr/bin/sqlite3")
            sql.arguments = [tmp, "SELECT value FROM moz_cookies WHERE name='\(name)' AND host='.commandcode.ai'"]
            let pipe = Pipe(); sql.standardOutput = pipe
            try? sql.run(); sql.waitUntilExit()
            return String(data:pipe.fileHandleForReading.readDataToEndOfFile(), encoding:.utf8)?
                .trimmingCharacters(in:.whitespacesAndNewlines)
        }.value
    }
}
