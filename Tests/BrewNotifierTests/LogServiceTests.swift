import XCTest
@testable import BrewNotifierCore

final class LogServiceTests: XCTestCase {

    var logDir: URL!
    var service: LogService!

    override func setUp() {
        super.setUp()
        logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogServiceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        service = LogService(logDirectory: logDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: logDir)
        super.tearDown()
    }

    // MARK: - Basic event writing

    func testFetchEventWritesBlockToFile() throws {
        let handle = service.beginEvent(.fetch)
        service.appendLine("wget 1.21.3 -> 1.21.4", to: handle)
        service.endEvent(handle, result: .success("1 formulae outdated, 0 casks outdated"))
        service.sync()

        let content = try logFileContent()
        XCTAssertTrue(content.contains("--- FETCH "), "Should contain FETCH header")
        XCTAssertTrue(content.contains("Running: brew outdated --json=v2"), "Should contain running line")
        XCTAssertTrue(content.contains("wget 1.21.3 -> 1.21.4"), "Should contain appended line")
        XCTAssertTrue(content.contains("1 formulae outdated, 0 casks outdated"), "Should contain result")
        XCTAssertTrue(content.contains("--- END "), "Should contain END footer")
    }

    func testUpgradeEventIncludesPackageInHeader() throws {
        let handle = service.beginEvent(.upgrade("wget 1.21.3 -> 1.21.4"))
        service.endEvent(handle, result: .success("SUCCESS"))
        service.sync()

        let content = try logFileContent()
        XCTAssertTrue(content.contains("--- UPGRADE "), "Should contain UPGRADE header")
        XCTAssertTrue(content.contains("[wget 1.21.3 -> 1.21.4]"), "Should contain package detail in header")
        XCTAssertTrue(content.contains("Running: brew upgrade wget"), "Should contain running line")
    }

    func testUpgradeAllEventWritesCorrectHeader() throws {
        let handle = service.beginEvent(.upgradeAll)
        service.endEvent(handle, result: .success("SUCCESS"))
        service.sync()

        let content = try logFileContent()
        XCTAssertTrue(content.contains("--- UPGRADE_ALL "), "Should contain UPGRADE_ALL header")
        XCTAssertTrue(content.contains("Running: brew upgrade\n"), "Should contain running line")
    }

    func testErrorEventWritesErrorBlock() throws {
        let handle = service.beginEvent(.fetch)
        service.endEvent(handle, result: .failure(.fetch, "brew not found"))
        service.sync()

        let content = try logFileContent()
        XCTAssertTrue(content.contains("--- ERROR "), "Should contain ERROR header")
        XCTAssertTrue(content.contains("[during FETCH]"), "Should contain originating event type")
        XCTAssertTrue(content.contains("brew not found"), "Should contain error message")
        XCTAssertFalse(content.contains("=== Result ==="), "Error event should not have result block")
    }

    func testMultipleConcurrentAppendsDoNotInterleave() throws {
        let handle = service.beginEvent(.fetch)
        let group = DispatchGroup()
        for idx in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                self.service.appendLine("line-\(idx)", to: handle)
                group.leave()
            }
        }
        group.wait()
        service.endEvent(handle, result: .success("done"))
        service.sync()

        let content = try logFileContent()
        for idx in 0..<100 {
            XCTAssertTrue(content.contains("line-\(idx)\n"), "line-\(idx) must appear as a complete line")
        }
    }

    // MARK: - Retention pruning

    func testOldFilesArePrunedOnBeginEvent() throws {
        let staleDate = Calendar.current.date(byAdding: .day, value: -31, to: Date())!
        let staleURL = logDir.appendingPathComponent("runtime-\(dateString(staleDate)).log")
        try "old log".write(to: staleURL, atomically: true, encoding: .utf8)

        let testDefaults = UserDefaults(suiteName: "LogServiceTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: testDefaults)
        settings.logRetentionDays = 30
        let svc = LogService(logDirectory: logDir, settings: settings)

        let handle = svc.beginEvent(.fetch)
        svc.endEvent(handle, result: .success("0 formulae"))
        svc.sync()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path),
                       "File older than retention should be pruned")
    }

    func testRecentFilesAreNotPruned() throws {
        let recentDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let recentURL = logDir.appendingPathComponent("runtime-\(dateString(recentDate)).log")
        try "recent log".write(to: recentURL, atomically: true, encoding: .utf8)

        let testDefaults = UserDefaults(suiteName: "LogServiceTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: testDefaults)
        settings.logRetentionDays = 30
        let svc = LogService(logDirectory: logDir, settings: settings)

        let handle = svc.beginEvent(.fetch)
        svc.endEvent(handle, result: .success("0 formulae"))
        svc.sync()

        XCTAssertTrue(FileManager.default.fileExists(atPath: recentURL.path),
                      "File within retention window should NOT be pruned")
    }

    // MARK: - Helpers

    private func logFileContent() throws -> String {
        let url = logDir.appendingPathComponent("runtime-\(dateString(Date())).log")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func dateString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}
