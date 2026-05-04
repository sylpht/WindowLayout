import Foundation

/// Lightweight file logger at `~/Library/Logs/WindowLayout/WindowLayout.log`.
/// Auto-rotates when the file exceeds `maxBytes` (keeps one .1 backup).
enum Log {
    /// Rotate when the log exceeds this many bytes. One backup kept (`.log.1`).
    static let maxBytes: Int = 1_048_576  // 1 MB

    static let fileURL: URL = {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let dir = lib.appendingPathComponent("Logs").appendingPathComponent("WindowLayout")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WindowLayout.log")
    }()

    // ISO8601DateFormatter is documented thread-safe (per Apple), but isn't marked Sendable.
    // The `nonisolated(unsafe)` annotation tells Swift 6 we know what we're doing — all
    // access happens through the serial `queue` below.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let queue = DispatchQueue(label: "com.windowlayout.log", qos: .utility)

    static func info(_ message: String) {
        write("INFO", message)
    }

    static func warn(_ message: String) {
        write("WARN", message)
    }

    static func error(_ message: String) {
        write("ERROR", message)
    }

    private static func write(_ level: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(level) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            rotateIfNeeded()
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    /// If the live log exceeds `maxBytes`, rename it to `.log.1` (overwriting any prior backup).
    /// Called from inside the serial `queue` so no concurrent writers race.
    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size > maxBytes else { return }
        let backup = fileURL.deletingPathExtension().appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }
}
