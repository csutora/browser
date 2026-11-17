import AppKit

private class GhostLabel: NSTextField {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

class AutocompleteField: NSView, NSTextFieldDelegate {
    private let inputField: NSTextField
    private let ghostLabel = GhostLabel(labelWithString: "")
    private var ghostText = ""
    private var isUpdatingText = false
    var selectAllOnAppear = false

    var onTextChange: ((String) -> Void)?
    var onAcceptGhost: (() -> Void)?

    override init(frame: NSRect) {
        inputField = NSTextField()
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        wantsLayer = true

        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.font = .systemFont(ofSize: 18)
        inputField.textColor = .white
        inputField.placeholderString = "Search or enter URL..."
        inputField.cell?.wraps = false
        inputField.cell?.isScrollable = true
        inputField.delegate = self
        addSubview(inputField)

        ghostLabel.font = .systemFont(ofSize: 18)
        ghostLabel.textColor = NSColor.white.withAlphaComponent(0.35)
        ghostLabel.cell?.wraps = false
        ghostLabel.lineBreakMode = .byClipping
        ghostLabel.isHidden = true
        ghostLabel.onClick = { [weak self] in self?.onAcceptGhost?() }
        addSubview(ghostLabel)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        inputField.frame = NSRect(x: 0, y: (h - 24) / 2, width: bounds.width, height: 24)
        layoutGhost()
    }

    func focus() {
        window?.makeFirstResponder(inputField)
        if selectAllOnAppear && !inputField.stringValue.isEmpty {
            inputField.selectText(nil)
        }
    }

    var caretIsAtEnd: Bool {
        guard let editor = inputField.currentEditor() else { return true }
        let range = editor.selectedRange
        return range.length == 0 && range.location == (inputField.stringValue as NSString).length
    }

    func updateDisplay(inputText: String, completionText: String, previewText: String, completionJustAccepted: Bool = false) {
        isUpdatingText = true
        defer { isUpdatingText = false }

        // the field only ever holds real text (the typed input, or the full preview when
        // arrowing through suggestions). the inline completion is a ghost overlay instead,
        // accepted explicitly via tab, right arrow, or clicking it.
        let displayText = previewText.isEmpty ? inputText : previewText
        let needsTextUpdate = inputField.stringValue != displayText

        if needsTextUpdate {
            inputField.stringValue = displayText
        }
        if needsTextUpdate || completionJustAccepted,
           let fieldEditor = inputField.currentEditor() as? NSTextView {
            fieldEditor.setSelectedRange(NSRange(location: (displayText as NSString).length, length: 0))
        }

        ghostText = previewText.isEmpty ? completionText : ""
        layoutGhost()
    }

    private func layoutGhost() {
        guard !ghostText.isEmpty, !inputField.stringValue.isEmpty else {
            ghostLabel.isHidden = true
            return
        }
        let font = inputField.font ?? .systemFont(ofSize: 18)
        let typedWidth = NSAttributedString(
            string: inputField.stringValue, attributes: [.font: font]
        ).size().width
        guard typedWidth < bounds.width - 12 else {
            ghostLabel.isHidden = true
            return
        }
        ghostLabel.stringValue = ghostText
        let ghostWidth = NSAttributedString(
            string: ghostText, attributes: [.font: font]
        ).size().width + 6
        ghostLabel.frame = NSRect(
            x: typedWidth, y: inputField.frame.minY,
            width: min(ghostWidth, bounds.width - typedWidth), height: 24
        )
        ghostLabel.isHidden = false
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard !isUpdatingText else { return }
        onTextChange?(inputField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Return, Escape, Up, Down, Tab are handled by the key monitor in CommandPaletteOverlayView
        // We only need to prevent default behavior for these
        if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
           commandSelector == #selector(NSResponder.cancelOperation(_:)) ||
           commandSelector == #selector(NSResponder.moveUp(_:)) ||
           commandSelector == #selector(NSResponder.moveDown(_:)) ||
           commandSelector == #selector(NSResponder.insertTab(_:)) {
            return true // Handled by key monitor
        }
        return false
    }
}
