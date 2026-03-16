import AppKit
import SwiftUI
import BrewNotifierCore

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var checker: UpdateChecker

    @State private var newIgnoredPackage = ""

    private let intervalOptions = [15, 30, 60, 120, 360]

    var body: some View {
        Form {
            Section("Schedule") {
                Picker("Mode", selection: $settings.scheduleMode) {
                    Text("Every interval").tag(ScheduleMode.interval)
                    Text("Once daily").tag(ScheduleMode.daily)
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.scheduleMode) { _ in
                    checker.reschedule()
                }

                if settings.scheduleMode == .interval {
                    Picker("Check every", selection: $settings.checkIntervalMinutes) {
                        ForEach(intervalOptions, id: \.self) { minutes in
                            Text(label(for: minutes)).tag(minutes)
                        }
                    }
                    .onChange(of: settings.checkIntervalMinutes) { _ in
                        checker.reschedule()
                    }
                } else {
                    Picker("Start at", selection: $settings.dailyStartHour) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(hourLabel(hour)).tag(hour)
                        }
                    }
                    .onChange(of: settings.dailyStartHour) { _ in
                        checker.reschedule()
                    }
                }
            }

            Section("Ignored Packages") {
                if settings.ignoredPackages.isEmpty {
                    Text("No ignored packages").foregroundStyle(.secondary)
                } else {
                    ForEach(settings.ignoredPackages, id: \.self) { pkg in
                        HStack {
                            Text(pkg)
                            Spacer()
                            Button(action: { remove(pkg) }, label: {
                                Image(systemName: "minus.circle.fill").foregroundColor(.red)
                            })
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack {
                    TextField("Package name", text: $newIgnoredPackage)
                        .onSubmit(addIgnored)
                    Button("Add", action: addIgnored)
                        .disabled(newIgnoredPackage.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Logs") {
                Stepper("Retention: \(settings.logRetentionDays) days",
                        value: $settings.logRetentionDays, in: 1...365)

                HStack {
                    Text("Log folder")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open in Finder") {
                        NSWorkspace.shared.open(LogService.shared.resolvedLogDirectory)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Check Now") { checker.checkNow() }
                    .disabled(checker.isChecking)
            }

            if let error = checker.lastError {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 400, height: 440)
    }

    private func hourLabel(_ hour: Int) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h a"
        var comps = DateComponents()
        comps.hour = hour; comps.minute = 0
        let date = Calendar.current.date(from: comps) ?? Date()
        return fmt.string(from: date)
    }

    private func label(for minutes: Int) -> String {
        switch minutes {
        case 60: return "1 hour"
        case 120: return "2 hours"
        case 360: return "6 hours"
        default: return "\(minutes) minutes"
        }
    }

    private func addIgnored() {
        let name = newIgnoredPackage.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !settings.ignoredPackages.contains(name) else { return }
        settings.ignoredPackages.append(name)
        newIgnoredPackage = ""
    }

    private func remove(_ pkg: String) {
        settings.ignoredPackages.removeAll { $0 == pkg }
    }
}
