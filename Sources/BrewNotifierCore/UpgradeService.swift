import Foundation

public enum UpgradeServiceError: Error, LocalizedError {
    case brewNotFound
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .brewNotFound:
            return "Homebrew not found. Please install it at https://brew.sh"
        case .executionFailed(let msg):
            return "Upgrade failed: \(msg)"
        }
    }
}

public final class UpgradeService {
    private let brewPathOverride: String?
    private let stubbedExitCode: Int32?
    private let stubbedStderr: String?
    private let logger: LogService

    public init(
        brewPathOverride: String? = nil,
        stubbedExitCode: Int32? = nil,
        stubbedStderr: String? = nil,
        logger: LogService = .shared
    ) {
        self.brewPathOverride = brewPathOverride
        self.stubbedExitCode = stubbedExitCode
        self.stubbedStderr = stubbedStderr
        self.logger = logger
    }

    private func resolvedBrewPath() -> String? {
        if let override = brewPathOverride {
            return FileManager.default.fileExists(atPath: override) ? override : nil
        }
        return BrewService.brewPath()
    }

    /// Runs `brew upgrade <package>` non-blockingly, streaming stdout+stderr to progressHandler.
    /// `logDetail` is the human-readable string shown in the log header (e.g. "argocd 3.3.2 -> 3.3.3").
    public func upgradeWithProgress(
        package: String,
        logDetail: String? = nil,
        progressHandler: @escaping (String) -> Void
    ) async throws {
        if let exitCode = stubbedExitCode {
            if exitCode != 0 {
                throw UpgradeServiceError.executionFailed(stubbedStderr ?? "unknown")
            }
            return
        }
        let eventType = EventType.upgrade(logDetail ?? package)
        let handle = logger.beginEvent(eventType)
        let combined: (String) -> Void = { [logger, handle] line in
            logger.appendLine(line, to: handle)
            progressHandler(line)
        }
        do {
            try await runBrewWithProgress(arguments: ["upgrade", package], progressHandler: combined)
            logger.endEvent(handle, result: .success("SUCCESS"))
        } catch {
            logger.endEvent(handle, result: .failure(eventType, error.localizedDescription))
            throw error
        }
    }

    /// Runs `brew upgrade` (all packages) non-blockingly, streaming stdout+stderr to progressHandler.
    public func upgradeAllWithProgress(
        progressHandler: @escaping (String) -> Void
    ) async throws {
        if let exitCode = stubbedExitCode {
            if exitCode != 0 {
                throw UpgradeServiceError.executionFailed(stubbedStderr ?? "unknown")
            }
            return
        }
        let handle = logger.beginEvent(.upgradeAll)
        let combined: (String) -> Void = { [logger, handle] line in
            logger.appendLine(line, to: handle)
            progressHandler(line)
        }
        do {
            try await runBrewWithProgress(arguments: ["upgrade"], progressHandler: combined)
            logger.endEvent(handle, result: .success("SUCCESS"))
        } catch {
            logger.endEvent(handle, result: .failure(.upgradeAll, error.localizedDescription))
            throw error
        }
    }

    private func runBrewWithProgress(
        arguments: [String],
        progressHandler: @escaping (String) -> Void
    ) async throws {
        guard let brew = resolvedBrewPath() else {
            throw UpgradeServiceError.brewNotFound
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: brew)
                    process.arguments = arguments

                    let outputPipe = Pipe()
                    let errorPipe = Pipe()
                    process.standardOutput = outputPipe
                    process.standardError = errorPipe

                    let handler = { (handle: FileHandle) in
                        let data = handle.availableData
                        guard !data.isEmpty,
                              let text = String(data: data, encoding: .utf8) else { return }
                        for line in text.components(separatedBy: "\n") where !line.isEmpty {
                            progressHandler(line)
                        }
                    }
                    outputPipe.fileHandleForReading.readabilityHandler = handler
                    errorPipe.fileHandleForReading.readabilityHandler = handler

                    try process.run()
                    process.waitUntilExit()

                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil

                    if process.terminationStatus != 0 {
                        let errMsg = String(
                            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8
                        ) ?? "unknown error"
                        continuation.resume(throwing: UpgradeServiceError.executionFailed(errMsg))
                        return
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

}
