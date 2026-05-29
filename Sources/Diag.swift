import Foundation

/// Diagnostic logger — writes to a log file since macOS 26 redacts both NSLog
/// and os_log output from LSUIElement/accessory apps in `log show` / `log stream`.
let diagLogPath = NSHomeDirectory() + "/.hermes/logs/widget.log"

@inline(__always)
func dbg(_ msg: @autoclosure () -> String) {
    let line = "[\(DateFormatter.dbgTs.string(from: Date()))] \(msg())\n"
    if let data = line.data(using: .utf8) {
        // Append mode — create file if needed
        if FileManager.default.fileExists(atPath: diagLogPath) {
            if let fh = FileHandle(forWritingAtPath: diagLogPath) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: diagLogPath, contents: data)
        }
    }
}

private extension DateFormatter {
    static let dbgTs: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return f
    }()
}
