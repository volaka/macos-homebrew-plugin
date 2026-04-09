import AppKit
import SwiftUI
import Combine
import BrewNotifierCore

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private var checker: UpdateChecker
    private var settingsWindowController: NSWindowController?
    private var checkNowWindowController: CheckNowWindowController?
    private var upgradeAllWindowController: UpgradeWindowController?
    private var upgradeWindowControllers: [String: UpgradeWindowController] = [:]
    private var searchQuery: String = ""
    private var cancellables = Set<AnyCancellable>()

    // Stable references — we mutate these instead of swapping statusItem.menu
    private let stableMenu = NSMenu()
    private var searchField: NSSearchField?
    private var updatesMenuItem: NSMenuItem?
    private var checkNowMenuItem: NSMenuItem?
    private var progressMenuItem: NSMenuItem?
    private var isMenuOpen = false

    init(checker: UpdateChecker) {
        self.checker = checker
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setupButton()
        buildStableMenu()
        bindChecker()
    }

    // MARK: - Setup

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "mug", accessibilityDescription: "Brew Notifier")
        button.image?.isTemplate = true
        button.action = #selector(statusBarButtonClicked)
        button.target = self
    }

    /// Build the menu skeleton once. We mutate items in place — never swap statusItem.menu.
    private func buildStableMenu() {
        stableMenu.delegate = self

        // Search field row
        let searchItem = NSMenuItem()
        let searchContainer = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let field = NSSearchField(frame: NSRect(x: 10, y: 4, width: 220, height: 22))
        field.placeholderString = "Search packages…"
        field.delegate = self
        searchContainer.addSubview(field)
        searchItem.view = searchContainer
        searchField = field
        stableMenu.addItem(searchItem)
        stableMenu.addItem(.separator())

        // Updates submenu placeholder
        // autoenablesItems=true (default) disables items with action:nil — turn it off on stableMenu
        // so we control enabled state explicitly.
        stableMenu.autoenablesItems = false
        let updatesItem = NSMenuItem(title: "Updates", action: nil, keyEquivalent: "")
        updatesItem.submenu = NSMenu()
        updatesItem.isEnabled = true
        stableMenu.addItem(updatesItem)
        updatesMenuItem = updatesItem

        stableMenu.addItem(.separator())

        // Check Now / progress (swapped in updateCheckingState)
        let checkItem = NSMenuItem(title: "Check Now", action: #selector(checkNow), keyEquivalent: "r")
        checkItem.target = self
        checkItem.isEnabled = true
        stableMenu.addItem(checkItem)
        checkNowMenuItem = checkItem

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.isEnabled = true
        stableMenu.addItem(settingsItem)

        let updateAllItem = NSMenuItem(title: "Update All", action: #selector(upgradeAll), keyEquivalent: "u")
        updateAllItem.target = self
        updateAllItem.isEnabled = true
        stableMenu.addItem(updateAllItem)

        stableMenu.addItem(.separator())
        stableMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = stableMenu
    }

    private func bindChecker() {
        checker.$outdatedFormulae
            .combineLatest(checker.$outdatedCasks)
            .receive(on: RunLoop.main)
            .sink { [weak self] formulae, casks in
                self?.updateBadge(count: formulae.count + casks.count)
                self?.updateSubmenu(formulae: formulae, casks: casks)
            }
            .store(in: &cancellables)

        checker.$isChecking
            .receive(on: RunLoop.main)
            .sink { [weak self] isChecking in
                self?.updateCheckingState(isChecking)
            }
            .store(in: &cancellables)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        // Set first responder before mutating menu items so AppKit layout doesn't reset focus
        searchField?.stringValue = searchQuery
        if let window = statusItem.button?.window {
            window.makeFirstResponder(searchField)
        }
        // Sync progress bar state in case a check started while menu was closed
        updateCheckingState(checker.isChecking)
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    // MARK: - Badge

    private func updateBadge(count: Int) {
        guard let button = statusItem.button else { return }
        if count > 0 {
            button.title = " \(count)"
        } else {
            button.title = ""
        }
    }

    // MARK: - Menu mutation (never swaps statusItem.menu)

    private func updateSubmenu(formulae: [BrewPackage], casks: [BrewCask]) {
        guard let updatesItem = updatesMenuItem else { return }

        let filteredFormulae = filtered(formulae)
        let filteredCasks = filtered(casks)
        let totalCount = formulae.count + casks.count
        let displayCount = filteredFormulae.count + filteredCasks.count

        if totalCount == 0 {
            updatesItem.title = "All packages up to date"
            updatesItem.submenu = nil
        } else {
            updatesItem.title = searchQuery.isEmpty
                ? "Updates (\(totalCount))"
                : "Results (\(displayCount) of \(totalCount))"
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            addPackageItems(filteredFormulae, to: submenu, header: "Formulae")
            if !filteredCasks.isEmpty && !filteredFormulae.isEmpty { submenu.addItem(.separator()) }
            addPackageItems(filteredCasks, to: submenu, header: "Casks")
            updatesItem.submenu = submenu
        }
    }

    private func addPackageItems<T: BrewPackageProtocol>(_ packages: [T], to submenu: NSMenu, header: String) {
        guard !packages.isEmpty else { return }
        let headerItem = NSMenuItem(title: "\(header) (\(packages.count))", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        submenu.addItem(headerItem)
        for pkg in packages {
            let item = NSMenuItem(
                title: "  \(pkg.name)  \(pkg.installedVersions.first ?? "?") → \(pkg.currentVersion)",
                action: #selector(upgradePackage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = true
            item.representedObject = PackageMenuInfo(
                name: pkg.name,
                installed: pkg.installedVersions.first ?? "?",
                current: pkg.currentVersion
            )
            submenu.addItem(item)
        }
    }

    private func updateCheckingState(_ isChecking: Bool) {
        // When not checking: always restore Check Now (even if menu is closed) so state is clean.
        // When checking: only show progress bar if menu is currently open (prevents it on launch).
        if !isChecking {
            if let progress = progressMenuItem,
               let pidx = stableMenu.items.firstIndex(of: progress) {
                stableMenu.removeItem(at: pidx)
                stableMenu.insertItem(checkNowMenuItem!, at: pidx)
            }
            progressMenuItem = nil
            return
        }

        guard isMenuOpen else { return }
        guard let checkNowItem = checkNowMenuItem,
              let idx = stableMenu.items.firstIndex(of: checkNowItem) else { return }

        if isChecking {
            // Swap Check Now for a progress bar item
            let progressItem = NSMenuItem()
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
            let bar = NSProgressIndicator(frame: NSRect(x: 8, y: 4, width: 120, height: 14))
            bar.style = .bar
            bar.isIndeterminate = true
            bar.startAnimation(nil)
            let label = NSTextField(labelWithString: "Fetching…")
            label.frame = NSRect(x: 136, y: 3, width: 64, height: 16)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            container.addSubview(bar)
            container.addSubview(label)
            progressItem.view = container
            stableMenu.removeItem(at: idx)
            stableMenu.insertItem(progressItem, at: idx)
            progressMenuItem = progressItem
        }
    }

    // MARK: - Search

    private func filtered<T: BrewPackageProtocol>(_ packages: [T]) -> [T] {
        guard !searchQuery.isEmpty else { return packages }
        return packages.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }

    // MARK: - Actions

    @objc private func statusBarButtonClicked() {
        statusItem.button?.performClick(nil)
    }

    @objc private func checkNow() {
        if let existing = checkNowWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let windowController = CheckNowWindowController(service: BrewService()) { [weak self] formulae, casks in
            guard let self else { return }
            let ignored = Set(checker.settings.ignoredPackages)
            checker.updateResults(
                formulae: formulae.filter { !ignored.contains($0.name) },
                casks: casks.filter { !ignored.contains($0.name) }
            )
        }
        checkNowWindowController = windowController
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowController.startCheck()
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: windowController.window,
            queue: .main
        ) { [weak self] _ in
            self?.checkNowWindowController = nil
        }
    }

    @objc private func upgradePackage(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? PackageMenuInfo else { return }
        if let existing = upgradeWindowControllers[info.name] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let windowController = UpgradeWindowController(
            target: .single(name: info.name, from: info.installed, newVersion: info.current),
            onComplete: { [weak self] in self?.checker.checkNow() }
        )
        upgradeWindowControllers[info.name] = windowController
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowController.startUpgrade()
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: windowController.window,
            queue: .main
        ) { [weak self] _ in
            self?.upgradeWindowControllers.removeValue(forKey: info.name)
        }
    }

    @objc private func upgradeAll() {
        if let existing = upgradeAllWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let windowController = UpgradeWindowController(
            target: .all,
            onComplete: { [weak self] in self?.checker.checkNow() }
        )
        upgradeAllWindowController = windowController
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowController.startUpgrade()
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: windowController.window,
            queue: .main
        ) { [weak self] _ in
            self?.upgradeAllWindowController = nil
        }
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 340),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Brew Notifier Settings"
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(checker: checker))
            settingsWindowController = NSWindowController(window: window)
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - NSSearchFieldDelegate

extension StatusBarController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        searchQuery = field.stringValue
        updateSubmenu(formulae: checker.outdatedFormulae, casks: checker.outdatedCasks)
    }
}
