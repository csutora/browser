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

        // Flipped, so the page is top-anchored: a section growing/collapsing only moves content below
        // it, instead of re-coordinating the whole page (which visually shredded collapse animations).
        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = container

        // Vertical stack of fixed-width (600) blocks, centered. Auto-layout so dynamic blocks (the
        // search-engine disclosure) reflow the whole column when they grow / shrink.
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: clip.topAnchor),
            container.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            container.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 120),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -32),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.widthAnchor.constraint(equalToConstant: 600),
        ])

        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.textColor = .labelColor

        let searchEngines = SearchEngineSettingsView()
        searchEngines.onLayoutChange = { [weak scrollView] in scrollView?.documentView?.layoutSubtreeIfNeeded() }

        let blocks: [NSView] = [
            title,
            makeSectionView(title: "General", rows: [
                makeSettingRow("Homepage") { self.makeLabel("google.com") },
                searchEngines,
            ]),
            makeSectionView(title: "Appearance", rows: [
                makeSettingRow("Fullscreen sidebar radius") { self.makeSliderControl() },
            ]),
            makeSectionView(title: "Search", rows: [
                makeSettingRow("Search suggestions") { self.makeToggle(key: "includeSearchSuggestions") },
                makeSettingRow("History suggestions") { self.makeToggle(key: "includeHistorySuggestions") },
            ]),
            makeBentoTileView(icon: "keyboard", title: "Keyboard Shortcuts",
                              subtitle: "\(KeybindAction.allCases.count) shortcuts configured") { self.navigationState.navigate(to: "keybinds") },
            makeBentoTileView(icon: "clock.arrow.circlepath", title: "Browsing History",
                              subtitle: "View and manage your history") { self.navigationState.navigate(to: "history") },
            makeSectionView(title: "Sync", rows: [
                makeSettingRow("iCloud Sync") { self.makeLabel("Not configured") },
            ]),
        ]
        for block in blocks {
            stack.addArrangedSubview(block)
            block.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        // The big title hugs left rather than stretching its text box visually; constraint is enough.
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        return scrollView
    }

    // MARK: - Section Builder

    /// A standard section row: title label left, control right, fixed 40pt height.
    private func makeSettingRow(_ rowTitle: String, _ controlFactory: () -> NSView) -> NSView {
        let row = NSView()
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.02).cgColor
        row.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let label = NSTextField(labelWithString: rowTitle)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)

        let control = controlFactory()
        let size = control.frame.size
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        control.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        row.addSubview(control)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    /// A settings section: uppercase title + a rounded box stacking arbitrary row views.
    private func makeSectionView(title: String, rows: [NSView]) -> NSView {
        let container = NSView()

        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        box.layer?.cornerRadius = 8
        box.layer?.cornerCurve = .continuous
        box.layer?.masksToBounds = true
        box.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(box)

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.spacing = 1
        rowsStack.alignment = .width
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: box.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])

        for row in rows {
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            box.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            box.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            box.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
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

    private func makeBentoTileView(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> NSView {
        let tileH: CGFloat = 84
        let maxW: CGFloat = 600
        let tile = ClickableView(frame: NSRect(x: 0, y: 0, width: maxW, height: tileH))
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.heightAnchor.constraint(equalToConstant: tileH).isActive = true
        tile.wantsLayer = true
        tile.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        tile.layer?.cornerRadius = 12
        tile.layer?.cornerCurve = .continuous
        tile.layer?.borderWidth = 1
        tile.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        tile.onClick = action

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

        return tile
    }
}

// MARK: - Flipped View (top-to-bottom layout)
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Clickable View
class ClickableView: NSView {
    var onClick: (() -> Void)?
    var restColor = NSColor.white.withAlphaComponent(0.05)
    var hoverColor = NSColor.white.withAlphaComponent(0.08)
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
        layer?.backgroundColor = hoverColor.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = restColor.cgColor
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
