import AppKit
import ServiceManagement
import SwiftUI

/// Preferences and macOS desktop integration.
struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Themed { p in
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Settings")

                SettingRow(title: "Notifications", hint: "Alert when a PR needs you again") {
                    Toggle("", isOn: setting(\.notifications)).switchStyle(p)
                }
                SettingRow(title: "Show drafts", hint: "Include draft pull requests") {
                    Toggle("", isOn: setting(\.showDrafts)).switchStyle(p)
                }
                SettingRow(title: "Refresh every", hint: "How often GitHub is checked") {
                    Segmented(options: [1, 2, 5, 15], selection: setting(\.refreshMinutes)) { Text("\($0)m") }
                }
                SettingRow(title: "Appearance", hint: "System, dark or light theme") {
                    Segmented(options: Appearance.allCases, selection: setting(\.appearance)) {
                        Text($0.rawValue.capitalized)
                    }
                }
                SettingRow(title: "Avoid desktop widgets", hint: "Find free space near the selected corner") {
                    Toggle("", isOn: setting(\.automaticPlacement)).switchStyle(p)
                        .disabled(store.prefs.settings.corner == .custom)
                }
                SettingRow(title: "Position", hint: "Choose a corner or enter coordinates") {
                    Segmented(options: Corner.allCases, selection: setting(\.corner)) { CornerGlyph(corner: $0) }
                }
                if store.prefs.settings.corner == .custom {
                    SettingRow(title: "Coordinates", hint: "From the main work area's top-left") {
                        HStack(spacing: 6) {
                            Text("X")
                            TextField("X", value: coordinate(\.customX), format: .number.grouping(.never))
                                .frame(width: 55)
                            Text("Y")
                            TextField("Y", value: coordinate(\.customY), format: .number.grouping(.never))
                                .frame(width: 55)
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }
                if let notice = store.placementNotice {
                    Text(notice)
                        .font(Fonts.ui(11.5))
                        .foregroundStyle(p.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
                SettingRow(title: "Open at login", hint: "Start the widget when you log in") {
                    Toggle("", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin)).switchStyle(p)
                }

                sectionTitle("Repositories")
                repositories(p)

                HStack {
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .font(Fonts.mono(11.5))
                        .foregroundStyle(p.faint)
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                        .buttonStyle(.plain)
                        .font(Fonts.ui(12))
                        .foregroundStyle(p.muted)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .overlay(alignment: .top) {
                    Rectangle().fill(p.border.opacity(0.55)).frame(height: 1)
                }
                .padding(.top, 6)
            }
            .padding(6)
            .frame(width: 360)
            .font(Fonts.ui(13))
            .foregroundStyle(p.text)
            .presentationBackground(p.panel)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Fonts.ui(13, .semibold))
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private func repositories(_ p: Palette) -> some View {
        let repos = store.repositories
        if repos.isEmpty {
            Text("Repositories show up here once pull requests load.")
                .font(Fonts.ui(11.5))
                .foregroundStyle(p.faint)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(repos, id: \.self) { repo in
                        HStack {
                            Text(repo)
                                .font(Fonts.mono(12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 16)
                            Toggle("", isOn: Binding(
                                get: { store.prefs.isWatched(repo) },
                                set: { store.setWatched(repo, $0) }
                            ))
                            .switchStyle(p)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                }
            }
            .frame(maxHeight: 196)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<Settings, Value>) -> Binding<Value> {
        Binding(
            get: { store.prefs.settings[keyPath: keyPath] },
            set: { value in store.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }

    private func coordinate(_ keyPath: WritableKeyPath<Settings, Int>) -> Binding<Int> {
        Binding(
            get: { store.prefs.settings[keyPath: keyPath] },
            set: { value in
                store.updateSettings {
                    $0[keyPath: keyPath] = min(max(value, Int(Int32.min)), Int(Int32.max))
                }
            }
        )
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("couldn't change login item: \(error)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    let hint: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        Themed { p in
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Fonts.ui(13, .medium))
                    Text(hint).font(Fonts.ui(11.5)).foregroundStyle(p.faint)
                }
                Spacer(minLength: 0)
                control()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }
}

private struct CornerGlyph: View {
    let corner: Corner

    var body: some View {
        let (icon, title): (String, String) = switch corner {
        case .topLeft: ("arrow-up-left", "Top left")
        case .topRight: ("arrow-up-right", "Top right")
        case .bottomLeft: ("arrow-down-left", "Bottom left")
        case .bottomRight: ("arrow-down-right", "Bottom right")
        case .custom: ("crosshairs", "Custom")
        }
        HStack(spacing: 5) {
            Icon(icon)
            if corner == .custom {
                Text("Custom")
            }
        }
        .accessibilityLabel(title)
        .help(title)
    }
}

private extension Toggle {
    func switchStyle(_ p: Palette) -> some View {
        toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .tint(p.accent)
    }
}
