import Foundation

public enum EventType {
    case fetch
    case upgrade(String)   // detail string e.g. "wget 1.21.3 -> 1.21.4"
    case upgradeAll

    public var label: String {
        switch self {
        case .fetch: return "FETCH"
        case .upgrade: return "UPGRADE"
        case .upgradeAll: return "UPGRADE_ALL"
        }
    }

    var command: String {
        switch self {
        case .fetch: return "brew outdated --json=v2"
        case .upgrade(let detail):
            let pkg = detail.components(separatedBy: " ").first ?? detail
            return "brew upgrade \(pkg)"
        case .upgradeAll: return "brew upgrade"
        }
    }

    var detail: String? {
        if case .upgrade(let d) = self { return d }
        return nil
    }
}

public enum EventResult {
    case success(String)
    case failure(EventType, String)  // originating type + error message
}

public struct EventHandle {
    let type: EventType
    let startTime: Date
}

public final class LogService {
    public static let shared = LogService()

    private let logDirectory: URL
    private let queue = DispatchQueue(label: "com.volaka.BrewNotifier.LogService")
    private let settings: AppSettings

    private static var defaultLogDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/BrewNotifier")
    }

    public convenience init() {
        self.init(logDirectory: LogService.defaultLogDirectory)
    }

    public init(logDirectory: URL, settings: AppSettings = .shared) {
        self.logDirectory = logDirectory
        self.settings = settings
    }

    public var resolvedLogDirectory: URL {
        if let custom = settings.logDirectoryPath {
            return URL(fileURLWithPath: custom)
        }
        return logDirectory
    }

    // MARK: - Public API (fire-and-forget, safe to call from @MainActor)

    @discardableResult
    public func beginEvent(_ type: EventType) -> EventHandle {
        let handle = EventHandle(type: type, startTime: Date())
        queue.async { [weak self] in
            guard let self else { return }
            self.ensureDirectoryExists()
            self.pruneOldFiles()
            var header = "--- \(type.label) \(self.timestamp(handle.startTime))"
            if let detail = type.detail { header += " [\(detail)]" }
            header += " ---"
            self.writeLine(header, eventDate: handle.startTime)
            self.writeLine("Running: \(type.command)", eventDate: handle.startTime)
            self.writeLine("=== Output ===", eventDate: handle.startTime)
        }
        return handle
    }

    public func appendLine(_ line: String, to handle: EventHandle) {
        queue.async { [weak self] in
            self?.writeLine(line, eventDate: handle.startTime)
        }
    }

    public func endEvent(_ handle: EventHandle, result: EventResult) {
        queue.async { [weak self] in
            guard let self else { return }
            let endTime = Date()
            let elapsed = Int(endTime.timeIntervalSince(handle.startTime))
            switch result {
            case .success(let summary):
                self.writeLine("=== Result ===", eventDate: handle.startTime)
                self.writeLine(summary, eventDate: handle.startTime)
                self.writeLine("--- END \(self.timeOnly(endTime)) (\(elapsed)s) ---",
                               eventDate: handle.startTime)
            case .failure(let originType, let message):
                self.writeLine(
                    "--- ERROR \(self.timestamp(endTime)) [during \(originType.label)] ---",
                    eventDate: handle.startTime
                )
                self.writeLine(message, eventDate: handle.startTime)
                self.writeLine("--- END ---", eventDate: handle.startTime)
            }
            self.writeLine("", eventDate: handle.startTime)
        }
    }

    /// Blocks until all queued writes complete. Tests only — accessible via @testable import.
    func sync() {
        queue.sync {}
    }

    // MARK: - Private

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: resolvedLogDirectory, withIntermediateDirectories: true
        )
    }

    private func pruneOldFiles() {
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -(settings.logRetentionDays), to: Date()
        )!
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: resolvedLogDirectory, includingPropertiesForKeys: nil
        ) else { return }

        for url in files {
            let name = url.lastPathComponent
            guard name.hasPrefix("runtime-"), name.hasSuffix(".log") else { continue }
            let dateStr = String(name.dropFirst("runtime-".count).dropLast(".log".count))
            guard let fileDate = fmt.date(from: dateStr), fileDate < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func writeLine(_ line: String, eventDate: Date) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let fileName = "runtime-\(fmt.string(from: eventDate)).log"
        let fileURL = resolvedLogDirectory.appendingPathComponent(fileName)
        let data = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: fileURL)
        }
    }

    private func timestamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }

    private func timeOnly(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: date)
    }
}
