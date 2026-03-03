# BrewNotifier

A macOS menu bar app that tracks outdated Homebrew packages and lets you upgrade them without leaving the menu bar.

## Screenshots

| Menu bar | Main menu | Package list |
|---|---|---|
| ![Top bar](images/top-bar.png) | ![Main menu](images/main-menu.png) | ![Menu with submenu](images/main-menu-with-submenu.png) |

## Features

- **Badge count** on the menu bar icon showing how many packages have updates
- **Package list** with formulae and casks grouped separately, showing installed → latest version
- **Search** to filter packages by name — filters live as you type
- **Check Now** — opens a popup with live `brew outdated` output and a summary when done
- **Upgrade individual packages** — click any package to open an upgrade popup with live `brew upgrade` output
- **Update All** — runs `brew upgrade` with live output in a popup
- **Auto-refresh** — after any upgrade completes, the outdated list is automatically refreshed
- **Scheduled checks** — interval-based (every N minutes) or daily at a configured hour
- **Ignored packages** — exclude packages from the outdated list via Settings

## Installation

Download the latest `BrewNotifier-vX.X.X.zip` from [Releases](../../releases), unzip, and move `BrewNotifier.app` to `/Applications`.

**First launch:** macOS will block the app since it's not notarized. Right-click → Open → Open to bypass Gatekeeper, or run:

```bash
xattr -d com.apple.quarantine /Applications/BrewNotifier.app
```

## Requirements

- macOS 13 (Ventura) or later
- [Homebrew](https://brew.sh) installed

## Build & Run

```bash
swift build
.build/debug/BrewNotifier
```

## Test

```bash
swift test
```

## Project Structure

```
Sources/
  BrewNotifierCore/       # Library — business logic, testable
    Models.swift          # BrewPackage, BrewCask, PackageMenuInfo
    BrewService.swift     # Runs brew outdated --json=v2
    UpgradeService.swift  # Runs brew upgrade [package]
    UpdateChecker.swift   # Scheduling, @Published state
    AppSettings.swift     # UserDefaults-backed settings
    DailySchedule.swift   # Wall-clock daily schedule helper
  BrewNotifier/           # Executable — AppKit UI
    App.swift             # AppDelegate entry point
    StatusBarController.swift
    CheckNowWindowController.swift
    UpgradeWindowController.swift
    SettingsView.swift
Tests/
  BrewNotifierTests/      # 28 unit tests
```

## Settings

Open Settings from the menu bar (⌘,):

- **Check interval** — how often to check for updates (interval mode)
- **Schedule mode** — interval (every N minutes) or daily (once at a configured hour)
- **Daily start hour** — hour of day for daily checks (e.g. 9 = 9 AM)
- **Ignored packages** — packages to exclude from the outdated list
