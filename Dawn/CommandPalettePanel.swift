import AppKit
import Combine

// MARK: - Command Palette Panel

class CommandPalettePanel {
    let state: CommandPaletteState
    private var overlayView: CommandPaletteOverlayView?

    var onSubmit: ((SuggestionType) -> Void)?
    var onSwitchToTab: ((Tab) -> Void)?
    var onDismiss: (() -> Void)?

    init(state: CommandPaletteState) {
        self.state = state
    }

    func show(in parentView: NSView) {
        hide()
        let overlay = CommandPaletteOverlayView(state: state)
        overlay.frame = parentView.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.onSubmit = { [weak self] type in
            switch type {
            case .recentTab(let tab):
                self?.onSwitchToTab?(tab)
            default:
                self?.onSubmit?(type)
            }
        }
        overlay.onDismiss = { [weak self] in
            self?.onDismiss?()
        }
        parentView.addSubview(overlay)
        overlayView = overlay

        DispatchQueue.main.async {
            overlay.focusInput()
        }
    }

    func hide() {
        overlayView?.removeFromSuperview()
        overlayView = nil
    }

    var isShowing: Bool { overlayView != nil }
}

// MARK: - Overlay View

private class CommandPaletteOverlayView: NSView {
    let state: CommandPaletteState
    var onSubmit: ((SuggestionType) -> Void)?
    var onDismiss: (() -> Void)?

    private let backdropView: BackdropClickView
    private let paletteContainer: NSView
    private let effectView: NSVisualEffectView
    private let darkBg: NSView
    private let inputContainer: AutocompleteField
    private let borderView: NSView
    private let divider: NSView
    private let scrollView: NSScrollView
    private let suggestionsView: FlippedView
    private var suggestionRows: [SuggestionRowView] = []
    private var keyMonitor: Any?

    private var cancellables = Set<AnyCancellable>()

    // Match original SwiftUI values exactly
    private let paletteWidth: CGFloat = 560
    private let inputHeight: CGFloat = 56
    private let rowHeight: CGFloat = 44
    private let visibleRows: Int = 5
    private var maxSuggestionsHeight: CGFloat { CGFloat(visibleRows) * rowHeight }
    // Fixed height used for centering (always 5 rows worth)
    private var fixedPaletteHeight: CGFloat { inputHeight + 1 + maxSuggestionsHeight + 16 }

    init(state: CommandPaletteState) {
        self.state = state

        backdropView = BackdropClickView()
        paletteContainer = NSView()
        effectView = NSVisualEffectView()
        darkBg = NSView()
        borderView = NSView()
        inputContainer = AutocompleteField()
        divider = NSView()
        scrollView = NSScrollView()
        suggestionsView = FlippedView()

        super.init(frame: .zero)
        wantsLayer = true

        setupViews()
        setupKeyMonitor()
        setupObservers()
        updateSuggestions()
        updateTextDisplay()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func setupViews() {
        // Transparent backdrop (click to dismiss) - NO darkening per original
        backdropView.wantsLayer = true
        // Clear background - no color
        backdropView.onClick = { [weak self] in self?.onDismiss?() }
        addSubview(backdropView)

        // Palette container with shadow
        paletteContainer.wantsLayer = true
        paletteContainer.layer?.cornerRadius = 12
        paletteContainer.layer?.cornerCurve = .continuous
        paletteContainer.layer?.masksToBounds = false
        // Shadow: .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        paletteContainer.layer?.shadowColor = NSColor.black.cgColor
        paletteContainer.layer?.shadowOpacity = 0.3
        paletteContainer.layer?.shadowRadius = 20
        paletteContainer.layer?.shadowOffset = NSSize(width: 0, height: -10)
        addSubview(paletteContainer)

        // Dark background (behind material, added first)
        darkBg.wantsLayer = true
        darkBg.layer?.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 0.85).cgColor
        darkBg.layer?.cornerRadius = 12
        darkBg.layer?.cornerCurve = .continuous
        darkBg.layer?.masksToBounds = true
        paletteContainer.addSubview(darkBg)

        // Visual effect on top of dark bg (.ultraThinMaterial)
        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        paletteContainer.addSubview(effectView)

        // Border overlay - 0.15 alpha per original
        borderView.wantsLayer = true
        borderView.layer?.cornerRadius = 12
        borderView.layer?.borderWidth = 1
        borderView.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        paletteContainer.addSubview(borderView)

        // Input field
        inputContainer.onTextChange = { [weak self] newText in
            self?.state.handleTextChange(newDisplayText: newText)
        }
        paletteContainer.addSubview(inputContainer)

        // Divider
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        paletteContainer.addSubview(divider)

        // Scroll view (original: .scrollIndicators(.hidden))
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = suggestionsView
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        paletteContainer.addSubview(scrollView)
    }

    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            switch event.keyCode {
            case 0x35: // Escape
                self.onDismiss?()
                return nil
            case 0x7E: // Arrow Up
                self.state.moveSelection(by: -1)
                self.scrollToSelection()
                return nil
            case 0x7D: // Arrow Down
                self.state.moveSelection(by: 1)
                self.scrollToSelection()
                return nil
            case 0x30: // Tab - accept completion/preview
                self.state.acceptCompletion()
                return nil
            case 0x7C: // Right Arrow - accept completion if at end
                if !self.state.completionText.isEmpty || !self.state.previewText.isEmpty {
                    self.state.acceptCompletion()
                    return nil
                }
                return event
            case 0x24: // Return
                self.submitCurrent()
                return nil
            default:
                return event
            }
        }
    }

    private func setupObservers() {
        state.$suggestions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateSuggestions() }
            .store(in: &cancellables)

        state.$selectedIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateSelection()
                self?.updateTextDisplay()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(state.$inputText, state.$completionText, state.$previewText)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.updateTextDisplay() }
            .store(in: &cancellables)
    }

    func focusInput() {
        inputContainer.selectAllOnAppear = (state.mode == .navigate)
        inputContainer.focus()
    }

    private func submitCurrent() {
        if let type = state.selectCurrent() {
            onSubmit?(type)
        }
    }

    private func scrollToSelection() {
        guard state.selectedIndex < suggestionRows.count,
              state.suggestions.count > visibleRows else { return }
        let row = suggestionRows[state.selectedIndex]
        suggestionsView.scrollToVisible(row.frame)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        backdropView.frame = bounds

        let paletteW: CGFloat = min(paletteWidth, bounds.width - 40)
        let paletteX = (bounds.width - paletteW) / 2

        let dividerH: CGFloat = 1
        let hasSuggestions = !state.suggestions.isEmpty
        let actualSuggestionsH = min(maxSuggestionsHeight, CGFloat(state.suggestions.count) * rowHeight)
        let suggestionsAreaH = hasSuggestions ? actualSuggestionsH + 16 : 0 // +16 for vertical padding
        let totalH = inputHeight + (hasSuggestions ? dividerH + suggestionsAreaH : 0)

        // Vertically centered based on FIXED 5-row height (matching original)
        let topOffset = (bounds.height - fixedPaletteHeight) / 2

        paletteContainer.frame = NSRect(
            x: paletteX,
            y: bounds.height - topOffset - totalH,
            width: paletteW,
            height: totalH
        )

        let containerBounds = paletteContainer.bounds
        effectView.frame = containerBounds
        darkBg.frame = containerBounds
        borderView.frame = containerBounds

        // Input at top (in flipped-like layout: top = highest y in AppKit)
        inputContainer.frame = NSRect(x: 16, y: totalH - inputHeight, width: paletteW - 32, height: inputHeight)

        if hasSuggestions {
            divider.frame = NSRect(x: 0, y: totalH - inputHeight - dividerH, width: paletteW, height: dividerH)
            divider.isHidden = false
            scrollView.frame = NSRect(x: 0, y: 0, width: paletteW, height: suggestionsAreaH)
            scrollView.isHidden = false
        } else {
            divider.isHidden = true
            scrollView.isHidden = true
        }

        layoutSuggestionRows()
    }

    private func layoutSuggestionRows() {
        let w = scrollView.frame.width
        var y: CGFloat = 8 // .padding(.vertical, 8)

        for row in suggestionRows {
            row.frame = NSRect(x: 8, y: y, width: w - 16, height: rowHeight)
            y += rowHeight
        }

        suggestionsView.frame = NSRect(x: 0, y: 0, width: w, height: y + 8)
    }

    // MARK: - Updates

    private func updateSuggestions() {
        suggestionRows.forEach { $0.removeFromSuperview() }
        suggestionRows.removeAll()

        for (index, suggestion) in state.suggestions.enumerated() {
            let row = SuggestionRowView(suggestion: suggestion, isSelected: index == state.selectedIndex)
            row.onClick = { [weak self] in
                self?.state.selectedIndex = index
                self?.submitCurrent()
            }
            suggestionsView.addSubview(row)
            suggestionRows.append(row)
        }

        needsLayout = true
    }

    private func updateSelection() {
        for (index, row) in suggestionRows.enumerated() {
            row.isSelected = index == state.selectedIndex
        }

        scrollToSelection()
    }

    private func updateTextDisplay() {
        inputContainer.updateDisplay(
            inputText: state.inputText,
            completionText: state.completionText,
            previewText: state.previewText,
            completionJustAccepted: state.completionJustAccepted
        )
        if state.completionJustAccepted {
            DispatchQueue.main.async {
                self.state.completionJustAccepted = false
            }
        }
    }
}

// MARK: - Backdrop Click View

private class BackdropClickView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

// MARK: - Suggestion Row View

private class SuggestionRowView: NSView {
    var isSelected: Bool {
        didSet { updateAppearance() }
    }

    var onClick: (() -> Void)?

    private let iconView: NSImageView
    private let titleLabel: NSTextField
    private let secondaryLabel: NSTextField
    private let returnIcon: NSImageView
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(suggestion: Suggestion, isSelected: Bool) {
        self.isSelected = isSelected

        iconView = NSImageView()
        titleLabel = NSTextField(labelWithString: "")
        secondaryLabel = NSTextField(labelWithString: "")
        returnIcon = NSImageView()

        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous

        // Icon - size 14, frame width 20
        iconView.image = NSImage(systemSymbolName: suggestion.iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        iconView.contentTintColor = .secondaryLabelColor
        addSubview(iconView)

        // Title
        titleLabel.stringValue = suggestion.displayText
        titleLabel.font = .systemFont(ofSize: 14)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.drawsBackground = false
        addSubview(titleLabel)

        // Secondary text (below title in VStack, not side-by-side)
        if let secondary = suggestion.secondaryText {
            secondaryLabel.stringValue = secondary
            secondaryLabel.font = .systemFont(ofSize: 12)
            secondaryLabel.textColor = .secondaryLabelColor
            secondaryLabel.lineBreakMode = .byTruncatingTail
            secondaryLabel.maximumNumberOfLines = 1
            secondaryLabel.isBezeled = false
            secondaryLabel.isEditable = false
            secondaryLabel.drawsBackground = false
            addSubview(secondaryLabel)
        } else {
            secondaryLabel.isHidden = true
        }

        // Return icon (shown when selected)
        returnIcon.image = NSImage(systemSymbolName: "return", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        returnIcon.contentTintColor = .secondaryLabelColor
        returnIcon.isHidden = !isSelected
        addSubview(returnIcon)

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let contentPadH: CGFloat = 16 // padding horizontal 16

        // Icon: frame width 20, centered vertically
        iconView.frame = NSRect(x: contentPadH, y: (h - 20) / 2, width: 20, height: 20)

        let textX: CGFloat = contentPadH + 20 + 12 // icon width + spacing 12
        let returnW: CGFloat = isSelected ? 24 : 0
        let availW = bounds.width - textX - contentPadH - returnW

        if secondaryLabel.isHidden {
            // Single line - center vertically
            titleLabel.frame = NSRect(x: textX, y: (h - 18) / 2, width: max(0, availW), height: 18)
        } else {
            // VStack(spacing: 2) - title on top, secondary below
            let totalTextH: CGFloat = 18 + 2 + 16 // title + spacing + secondary
            let textY = (h - totalTextH) / 2
            secondaryLabel.frame = NSRect(x: textX, y: textY, width: max(0, availW), height: 16)
            titleLabel.frame = NSRect(x: textX, y: textY + 16 + 2, width: max(0, availW), height: 18)
        }

        // Return icon on right
        returnIcon.frame = NSRect(x: bounds.width - contentPadH - 16, y: (h - 16) / 2, width: 16, height: 16)
    }

    override func mouseDown(with event: NSEvent) {
        // Must handle mouseDown to receive mouseUp
    }

    override func mouseUp(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if bounds.contains(localPoint) {
            onClick?()
        }
    }

    private func updateAppearance() {
        returnIcon.isHidden = !isSelected

        if isSelected {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
            iconView.contentTintColor = .labelColor
        } else if isHovered {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
            iconView.contentTintColor = .secondaryLabelColor
        } else {
            layer?.backgroundColor = nil
            iconView.contentTintColor = .secondaryLabelColor
        }
        titleLabel.textColor = .labelColor

        needsLayout = true
    }
}
