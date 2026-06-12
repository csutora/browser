import AppKit
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

// MARK: - Settings View Controller
class SettingsViewController: NSViewController {
    let navigationState = SettingsNavigationState()
    let historyManager: HistoryManager
    var onOpenURL: ((String) -> Void)?

    private var contentContainer: NSView!

    // Child views/controllers
    private var mainSettingsView: NSView?
    private var keybindsVC: KeybindsViewController?
    private var historyVC: HistoryViewController?

    private var cancellables = Set<AnyCancellable>()

    init(historyManager: HistoryManager) {
        self.historyManager = historyManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0).cgColor

        contentContainer = NSView()
        contentContainer.autoresizingMask = [.width, .height]
        container.addSubview(contentContainer)

        self.view = container

        navigationState.$currentPath
            .receive(on: DispatchQueue.main)
            .sink { [weak self] path in self?.navigateTo(path) }
            .store(in: &cancellables)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        contentContainer.frame = view.bounds
    }

    private func navigateTo(_ path: String) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }

        switch path {
        case "keybinds":
            showKeybinds()
        case "history":
            showHistory()
        default:
            showMainSettings()
        }
    }

    private func showMainSettings() {
        mainSettingsView = buildMainSettingsView()
        contentContainer.addSubview(mainSettingsView!)
        mainSettingsView?.frame = contentContainer.bounds
        mainSettingsView?.autoresizingMask = [.width, .height]
    }

    private func showKeybinds() {
        let vc = KeybindsViewController()
        vc.onBack = { [weak self] in
            self?.navigationState.navigate(to: "settings")
        }
        keybindsVC = vc
        contentContainer.addSubview(vc.view)
        vc.view.frame = contentContainer.bounds
        vc.view.autoresizingMask = [.width, .height]
    }

    private func showHistory() {
        let vc = HistoryViewController(historyManager: historyManager)
        vc.onBack = { [weak self] in
            self?.navigationState.navigate(to: "settings")
        }
        vc.onOpenURL = { [weak self] url in
            self?.onOpenURL?(url)
        }
        historyVC = vc
        contentContainer.addSubview(vc.view)
        vc.view.frame = contentContainer.bounds
        vc.view.autoresizingMask = [.width, .height]
    }

    // MARK: - Main Settings Page

    private func buildMainSettingsView() -> NSView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        // Center the fixed-width content horizontally when the scroll view is wider.
        scrollView.contentView = CenteringClipView()
        scrollView.contentView.drawsBackground = false

        let contentView = FlippedView()
        contentView.wantsLayer = true
        scrollView.documentView = contentView

        let maxW: CGFloat = 600
        let padH: CGFloat = 32
        let sectionSpacing: CGFloat = 24
        var y: CGFloat = 120 // .padding(.top, 120)

        // Header
        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.textColor = .labelColor
        title.frame = NSRect(x: padH, y: y, width: maxW, height: 34)
        contentView.addSubview(title)
        y += 34 + 8 + sectionSpacing // padding bottom 8 + section spacing

        // General Section
        y = addSection(title: "General", at: y, in: contentView, padH: padH, maxW: maxW, rows: [
            ("Homepage", { self.makeLabel("google.com") }),
            ("Search engine", { self.makeLabel("Google") })
        ])
        y += sectionSpacing

        // Appearance Section
        y = addSection(title: "Appearance", at: y, in: contentView, padH: padH, maxW: maxW, rows: [
            ("Fullscreen sidebar radius", { self.makeSliderControl() })
        ])
        y += sectionSpacing

        // Search Section
        y = addSection(title: "Search", at: y, in: contentView, padH: padH, maxW: maxW, rows: [
            ("Search suggestions", { self.makeToggle(key: "includeSearchSuggestions") }),
            ("History suggestions", { self.makeToggle(key: "includeHistorySuggestions") })
        ])
        y += sectionSpacing

        // Navigation tiles
        y = addBentoTile(
            icon: "keyboard", title: "Keyboard Shortcuts",
            subtitle: "\(KeybindAction.allCases.count) shortcuts configured",
            at: y, padH: padH, maxW: maxW, in: contentView
        ) { self.navigationState.navigate(to: "keybinds") }
        y += sectionSpacing

        y = addBentoTile(
            icon: "clock.arrow.circlepath", title: "Browsing History",
            subtitle: "View and manage your history",
            at: y, padH: padH, maxW: maxW, in: contentView
        ) { self.navigationState.navigate(to: "history") }
        y += sectionSpacing

        // Sync Section
        y = addSection(title: "Sync", at: y, in: contentView, padH: padH, maxW: maxW, rows: [
            ("iCloud Sync", { self.makeLabel("Not configured") })
        ])
        y += 32 // padding bottom

        contentView.frame = NSRect(x: 0, y: 0, width: maxW + padH * 2, height: y)

        return scrollView
    }

    // MARK: - Section Builder

    /// Builds a SettingsSection: title + VStack(spacing: 1) of rows with background
    private func addSection(title: String, at y: CGFloat, in container: NSView, padH: CGFloat, maxW: CGFloat, rows: [(String, () -> NSView)]) -> CGFloat {
        var currentY = y

        // Section title: .font(.system(size: 13, weight: .semibold)), .foregroundColor(.secondary), .textCase(.uppercase)
        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.drawsBackground = false
        titleLabel.frame = NSRect(x: padH, y: currentY, width: maxW, height: 16)
        container.addSubview(titleLabel)
        currentY += 16 + 12 // spacing: 12 between title and rows

        // Rows container: VStack(spacing: 1), background white 0.05, cornerRadius 8
        let rowsContainer = NSView()
        rowsContainer.wantsLayer = true
        rowsContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        rowsContainer.layer?.cornerRadius = 8
        rowsContainer.layer?.cornerCurve = .continuous
        rowsContainer.layer?.masksToBounds = true

        let rowH: CGFloat = 40 // padding vertical 10 + content ~20
        let totalRowsH = CGFloat(rows.count) * rowH + CGFloat(max(0, rows.count - 1)) // +1px divider between rows

        rowsContainer.frame = NSRect(x: padH, y: currentY, width: maxW, height: totalRowsH)
        container.addSubview(rowsContainer)

        var rowY: CGFloat = 0
        for (index, (rowTitle, controlFactory)) in rows.enumerated() {
            // Row: HStack { title, Spacer, control }, padding h:12 v:10, bg white 0.02
            let row = NSView(frame: NSRect(x: 0, y: rowY, width: maxW, height: rowH))
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.02).cgColor
            rowsContainer.addSubview(row)

            let label = NSTextField(labelWithString: rowTitle)
            label.font = .systemFont(ofSize: 13)
            label.textColor = .labelColor
            label.isBezeled = false
            label.isEditable = false
            label.drawsBackground = false
            label.frame = NSRect(x: 12, y: (rowH - 18) / 2, width: maxW * 0.5, height: 18)
            row.addSubview(label)

            let control = controlFactory()
            // Position control on right side
            let controlW = control.frame.width
            let controlH = control.frame.height
            control.frame = NSRect(x: maxW - 12 - controlW, y: (rowH - controlH) / 2, width: controlW, height: controlH)
            row.addSubview(control)

            rowY += rowH
            if index < rows.count - 1 {
                rowY += 1 // VStack spacing: 1
            }
        }

        return currentY + totalRowsH
    }

    // MARK: - Control Factories

    private func makeLabel(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.sizeToFit()
        return label
    }

    private func makeToggle(key: String) -> NSView {
        let toggle = NSSwitch()
        toggle.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))
        toggle.identifier = NSUserInterfaceItemIdentifier(key)
        toggle.setFrameSize(NSSize(width: 38, height: 22))
        return toggle
    }

    private func makeSliderControl() -> NSView {
        // HStack(spacing: 12) { Slider.frame(width: 120), Text.frame(width: 24) }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 120 + 12 + 24, height: 22))

        let currentValue = UserDefaults.standard.integer(forKey: "fullscreenSidebarRadius")

        let slider = NSSlider(value: Double(currentValue), minValue: 0, maxValue: 30, target: self, action: #selector(sliderChanged(_:)))
        slider.frame = NSRect(x: 0, y: 0, width: 120, height: 22)
        slider.identifier = NSUserInterfaceItemIdentifier("fullscreenSidebarRadius")
        slider.isContinuous = true
        container.addSubview(slider)

        let valueLabel = NSTextField(labelWithString: "\(currentValue)")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.isBezeled = false
        valueLabel.isEditable = false
        valueLabel.drawsBackground = false
        valueLabel.frame = NSRect(x: 132, y: 1, width: 24, height: 18)
        valueLabel.identifier = NSUserInterfaceItemIdentifier("fullscreenSidebarRadius_label")
        container.addSubview(valueLabel)

        return container
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        guard let key = sender.identifier?.rawValue else { return }
        UserDefaults.standard.set(sender.state == .on, forKey: key)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let key = sender.identifier?.rawValue else { return }
        let value = Int(sender.doubleValue)
        UserDefaults.standard.set(value, forKey: key)

        // Update the value label
        if let container = sender.superview,
           let valueLabel = container.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.identifier?.rawValue == key + "_label" }) {
            valueLabel.stringValue = "\(value)"
        }
    }

    // MARK: - Bento Tile

    private func addBentoTile(icon: String, title: String, subtitle: String, at y: CGFloat, padH: CGFloat, maxW: CGFloat, in container: NSView, action: @escaping () -> Void) -> CGFloat {
        let tileH: CGFloat = 84
        let tile = ClickableView(frame: NSRect(x: padH, y: y, width: maxW, height: tileH))
        tile.wantsLayer = true
        tile.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        tile.layer?.cornerRadius = 12
        tile.layer?.cornerCurve = .continuous
        tile.layer?.borderWidth = 1
        tile.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        tile.onClick = action
        container.addSubview(tile)

        // Icon: 24pt in 44x44 frame with white 0.1 bg, cornerRadius 10
        let iconView = NSImageView(frame: NSRect(x: 20, y: (tileH - 44) / 2, width: 44, height: 44))
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
        iconView.contentTintColor = .labelColor
        iconView.wantsLayer = true
        iconView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        iconView.layer?.cornerRadius = 10
        tile.addSubview(iconView)

        // Title: 15pt semibold
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.drawsBackground = false
        titleLabel.frame = NSRect(x: 80, y: tileH / 2 + 2, width: maxW - 120, height: 20)
        tile.addSubview(titleLabel)

        // Subtitle: 12pt
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.isBezeled = false
        subtitleLabel.isEditable = false
        subtitleLabel.drawsBackground = false
        subtitleLabel.frame = NSRect(x: 80, y: tileH / 2 - 18, width: maxW - 120, height: 16)
        tile.addSubview(subtitleLabel)

        // Chevron: 14pt semibold
        let chevron = NSImageView(frame: NSRect(x: maxW - 34, y: (tileH - 20) / 2, width: 14, height: 20))
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        chevron.contentTintColor = .secondaryLabelColor
        tile.addSubview(chevron)

        return y + tileH
    }
}

// MARK: - Flipped View (top-to-bottom layout)
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Clickable View
class ClickableView: NSView {
    var onClick: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
    }
}

// MARK: - Centering Clip View

/// Horizontally centers a document view that is narrower than the clip view.
class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let docView = documentView else { return rect }
        if docView.frame.width < rect.width {
            rect.origin.x = (docView.frame.width - rect.width) / 2.0
        }
        return rect
    }
}
