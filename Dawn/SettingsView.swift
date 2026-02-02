import SwiftUI
import Combine

// MARK: - Settings Navigation State
class SettingsNavigationState: ObservableObject {
    @Published var currentPath: String = "settings"
    var onNavigate: ((String) -> Void)?

    func navigate(to path: String) {
        currentPath = path
        onNavigate?(path)
    }
}

struct SettingsView: View {
    @ObservedObject var navigationState: SettingsNavigationState
    @ObservedObject var historyManager: HistoryManager
    let onOpenURL: (String) -> Void

    @StateObject private var keybindingsManager = KeybindingsManager.shared
    @AppStorage("fullscreenSidebarRadius") private var fullscreenSidebarRadius: Int = 13
    @AppStorage("includeSearchSuggestions") private var includeSearchSuggestions: Bool = true
    @AppStorage("includeHistorySuggestions") private var includeHistorySuggestions: Bool = true

    private var showKeybinds: Bool {
        navigationState.currentPath == "keybinds"
    }

    private var showHistory: Bool {
        navigationState.currentPath == "history"
    }

    private var showMainSettings: Bool {
        !showKeybinds && !showHistory
    }

    var body: some View {
        ZStack {
            Color(NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0))

            if showMainSettings {
                mainSettingsView
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }

            if showKeybinds {
                KeybindsView(manager: keybindingsManager, onBack: {
                    navigationState.navigate(to: "settings")
                })
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }

            if showHistory {
                HistoryView(
                    historyManager: historyManager,
                    onBack: {
                        navigationState.navigate(to: "settings")
                    },
                    onOpenURL: onOpenURL
                )
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: navigationState.currentPath)
    }

    var mainSettingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                Text("Settings")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.primary)
                    .padding(.bottom, 8)

                // General Section
                SettingsSection(title: "General") {
                    SettingsRow(title: "Homepage") {
                        Text("google.com")
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                    }

                    SettingsRow(title: "Search engine") {
                        Text("Google")
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                    }
                }

                // Appearance Section
                SettingsSection(title: "Appearance") {
                    SettingsRow(title: "Fullscreen sidebar radius") {
                        HStack(spacing: 12) {
                            Slider(value: Binding(
                                get: { Double(fullscreenSidebarRadius) },
                                set: { fullscreenSidebarRadius = Int($0) }
                            ), in: 0...30, step: 1)
                            .frame(width: 120)

                            Text("\(fullscreenSidebarRadius)")
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 24, alignment: .trailing)
                        }
                    }
                }

                // Search Section
                SettingsSection(title: "Search") {
                    SettingsRow(title: "Search suggestions") {
                        Toggle("", isOn: $includeSearchSuggestions)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    SettingsRow(title: "History suggestions") {
                        Toggle("", isOn: $includeHistorySuggestions)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }

                // Navigation Tiles
                SettingsBentoTile(
                    icon: "keyboard",
                    title: "Keyboard Shortcuts",
                    subtitle: "\(KeybindAction.allCases.count) shortcuts configured"
                ) {
                    navigationState.navigate(to: "keybinds")
                }

                SettingsBentoTile(
                    icon: "clock.arrow.circlepath",
                    title: "Browsing History",
                    subtitle: "View and manage your history"
                ) {
                    navigationState.navigate(to: "history")
                }

                // Sync Section (placeholder)
                SettingsSection(title: "Sync") {
                    SettingsRow(title: "iCloud Sync") {
                        Text("Not configured")
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                    }
                }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 120)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.automatic)
    }
}

// MARK: - Settings Components
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 1) {
                content
            }
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.primary)

            Spacer()

            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.02))
    }
}

// MARK: - Bento Tile
struct SettingsBentoTile: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Icon
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(.primary)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.08 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
