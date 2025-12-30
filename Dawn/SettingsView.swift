import SwiftUI

struct SettingsView: View {
    @StateObject private var keybindingsManager = KeybindingsManager.shared
    @State private var showKeybinds = false

    var body: some View {
        ZStack {
            Color(NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0))

            if !showKeybinds {
                mainSettingsView
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }

            if showKeybinds {
                KeybindsView(manager: keybindingsManager, showKeybinds: $showKeybinds)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showKeybinds)
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

                // Keyboard Shortcuts - Bento Tile
                SettingsBentoTile(
                    icon: "keyboard",
                    title: "Keyboard Shortcuts",
                    subtitle: "\(KeybindAction.allCases.count) shortcuts configured"
                ) {
                    withAnimation {
                        showKeybinds = true
                    }
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
