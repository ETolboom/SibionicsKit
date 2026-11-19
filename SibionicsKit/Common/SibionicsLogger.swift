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

    /// One file per local calendar day, `sibionics_log_yyyy-MM-dd.txt`, kept
    /// for `retainedDays` so a development run has a day-by-day trail.
    static let retainedDays = 30
    private static let filePrefix = "sibionics_log_"
    private static let fileSuffix = ".txt"

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The day the sink last wrote to; housekeeping runs when it changes.
    private static var lastDay: String?

    private static var directory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("sibionics", isDirectory: true)
    }

    static func fileName(for day: String) -> String { filePrefix + day + fileSuffix }

    private static func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let dir = directory, let data = line.data(using: .utf8) else { return }
        let day = dayFormatter.string(from: Date())
        if day != lastDay {
            housekeep(in: dir, today: day)
            lastDay = day
        }
        let url = dir.appendingPathComponent(fileName(for: day))
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Creates the directory, renames the old two-file rotation into dated
    /// files, and drops days past retention.
    private static func housekeep(in dir: URL, today: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        for legacy in ["sibionics_log_prev.txt", "sibionics_log.txt"] {
            let url = dir.appendingPathComponent(legacy)
            guard fm.fileExists(atPath: url.path) else { continue }
            let created = (try? fm.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
            let day = created.map(dayFormatter.string(from:)) ?? today
            let target = dir.appendingPathComponent(fileName(for: day))
            if fm.fileExists(atPath: target.path),
               let legacyData = try? Data(contentsOf: url),
               let handle = FileHandle(forWritingAtPath: target.path)
            {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: legacyData)
                try? handle.close()
                try? fm.removeItem(at: url)
            } else {
                try? fm.moveItem(at: url, to: target)
            }
        }

        guard let cutoff = Calendar.current.date(byAdding: .day, value: -(retainedDays - 1), to: Date())
        else { return }
        let oldestKept = dayFormatter.string(from: cutoff)
        for url in datedFiles(in: dir) where day(of: url) < oldestKept {
            try? fm.removeItem(at: url)
        }
    }

    private static func day(of url: URL) -> String {
        String(url.lastPathComponent.dropFirst(filePrefix.count).dropLast(fileSuffix.count))
    }

    /// Dated log files, oldest first (the names sort chronologically).
    private static func datedFiles(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(fileSuffix) && $0.count == fileName(for: "yyyy-MM-dd").count }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    /// Files to attach to a bug report, oldest first.
    public static func logFiles() -> [URL] {
        guard let dir = directory else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return datedFiles(in: dir)
    }
}
