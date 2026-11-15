import Foundation
import OSLog

/// os_log plus a rolling file in Documents/sibionics, because a user attaching
/// logs to a bug report is worth more than any amount of clever telemetry.
public final class SibionicsLogger: @unchecked Sendable {
    private static let subsystem = "org.loopkit.SibionicsKit"
    private static let lock = NSLock()

    private let logger: Logger
    private let fileManager = FileManager.default

    public init(category: String) {
        logger = Logger(subsystem: Self.subsystem, category: category)
    }

    public func debug(_ message: String, file: String = #file, _ function: String = #function, _ line: Int = #line) {
        emit(message, level: .debug, tag: "DEBUG", file: file, function, line)
    }

    public func info(_ message: String, file: String = #file, _ function: String = #function, _ line: Int = #line) {
        emit(message, level: .info, tag: "INFO", file: file, function, line)
    }

    public func warning(_ message: String, file: String = #file, _ function: String = #function, _ line: Int = #line) {
        emit(message, level: .default, tag: "WARN", file: file, function, line)
    }

    public func error(_ message: String, file: String = #file, _ function: String = #function, _ line: Int = #line) {
        emit(message, level: .error, tag: "ERROR", file: file, function, line)
    }

    private func emit(_ message: String, level: OSLogType, tag: String, file: String, _ function: String, _ line: Int) {
        let shortFile = file.components(separatedBy: "/").last ?? file
        let text = "\(shortFile) - \(function)#\(line): \(message)"
        logger.log(level: level, "\(text, privacy: .public)")
        Self.append("[\(Self.formatter.string(from: Date())) \(tag)] \(text)\n")
    }

    // MARK: - File sink

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
    }()

    private static func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        guard let dir = fm.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("sibionics", isDirectory: true) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let current = dir.appendingPathComponent("sibionics_log.txt")
        let previous = dir.appendingPathComponent("sibionics_log_prev.txt")

        let startOfDay = Calendar.current.startOfDay(for: Date())
        if let created = (try? fm.attributesOfItem(atPath: current.path))?[.creationDate] as? Date,
           created < startOfDay
        {
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: current, to: previous)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: current.path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            fm.createFile(atPath: current.path, contents: nil, attributes: [.creationDate: startOfDay])
            try? data.write(to: current)
        }
    }

    /// Files to attach to a bug report, oldest first.
    public static func logFiles() -> [URL] {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("sibionics", isDirectory: true) else { return [] }
        return ["sibionics_log_prev.txt", "sibionics_log.txt"]
            .map { dir.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
