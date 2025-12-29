import SwiftUI

struct SettingsView: View {
    var body: some View {
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

                // Keyboard Shortcuts Section (placeholder)
                SettingsSection(title: "Keyboard Shortcuts") {
                    Text("Coming soon...")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                }

                // Sync Section (placeholder)
                SettingsSection(title: "Sync") {
                    SettingsRow(title: "iCloud Sync") {
                        Text("Not configured")
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                    }
                }

                Spacer()
            }
            .padding(32)
            .frame(maxWidth: 600, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0)))
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
