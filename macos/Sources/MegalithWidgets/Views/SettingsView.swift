import AppKit
import ServiceManagement
import SwiftUI

/// The gear popover: same options as the Linux app, plus screen corner and
/// open at login.
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
                SettingRow(title: "Appearance", hint: "Follows Zed's light and dark themes") {
                    Segmented(options: Appearance.allCases, selection: setting(\.appearance)) {
                        Text($0.rawValue.capitalized)
                    }
                }
                SettingRow(title: "Position", hint: "Screen corner the widget sits in") {
                    Segmented(options: Corner.allCases, selection: setting(\.corner)) { CornerGlyph(corner: $0) }
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

/// A tiny screen with a dot in the chosen corner.
private struct CornerGlyph: View {
    let corner: Corner

    var body: some View {
        let alignment: Alignment = switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
        RoundedRectangle(cornerRadius: 2)
            .strokeBorder(lineWidth: 1)
            .frame(width: 16, height: 11)
            .overlay(alignment: alignment) {
                RoundedRectangle(cornerRadius: 1).frame(width: 5, height: 4).padding(2)
            }
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
