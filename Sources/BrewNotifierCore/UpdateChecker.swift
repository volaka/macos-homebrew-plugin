import Foundation
import Combine

@MainActor
public final class UpdateChecker: ObservableObject {
    @Published public private(set) var outdatedFormulae: [BrewPackage] = []
    @Published public private(set) var outdatedCasks: [BrewCask] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var isChecking = false

    public var totalCount: Int { outdatedFormulae.count + outdatedCasks.count }

    private let service: BrewService
    private let logger: LogService
    private var timer: Timer?
    public var settings: AppSettings { AppSettings.shared }

    public init(service: BrewService = BrewService(), logger: LogService = .shared) {
        self.service = service
        self.logger = logger
    }

    public func start() {
        scheduleTimer()
        Task { await check() }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func checkNow() {
        Task { await check() }
    }

    /// Called by CheckNowWindowController after it completes a check.
    public func updateResults(formulae: [BrewPackage], casks: [BrewCask]) {
        outdatedFormulae = formulae
        outdatedCasks = casks
    }

    public func reschedule() {
        stop()
        scheduleTimer()
    }

    // MARK: - Private

    private func scheduleTimer() {
        switch settings.scheduleMode {
        case .interval:
            let interval = TimeInterval(settings.checkIntervalMinutes * 60)
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { await self?.check() }
            }
        case .daily:
            scheduleDailyTimer()
        }
    }

    private func scheduleDailyTimer() {
        let delay = DailySchedule.secondsUntilNextFire(targetHour: settings.dailyStartHour)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task {
                await self?.check()
                await self?.scheduleDailyTimer()
            }
        }
    }

    private func check() async {
        let handle = logger.beginEvent(.fetch)
        isChecking = true
        lastError = nil
        do {
            let result = try await service.fetchOutdatedWithProgress { [logger, handle] line in
                logger.appendLine(line, to: handle)
            }
            let ignored = Set(settings.ignoredPackages)
            outdatedFormulae = result.formulae.filter { !ignored.contains($0.name) }
            outdatedCasks = result.casks.filter { !ignored.contains($0.name) }
            let summary = "\(outdatedFormulae.count) formulae outdated, \(outdatedCasks.count) casks outdated"
            logger.endEvent(handle, result: .success(summary))
        } catch {
            lastError = error.localizedDescription
            logger.endEvent(handle, result: .failure(.fetch, error.localizedDescription))
        }
        isChecking = false
    }
}
