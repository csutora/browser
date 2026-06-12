import AppKit

class AutocompleteField: NSView, NSTextFieldDelegate {
    private let inputField: NSTextField
    private var isUpdatingText = false
    var selectAllOnAppear = false

    var onTextChange: ((String) -> Void)?

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
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        inputField.frame = NSRect(x: 0, y: (h - 24) / 2, width: bounds.width, height: 24)
    }

    func focus() {
        window?.makeFirstResponder(inputField)
        if selectAllOnAppear && !inputField.stringValue.isEmpty {
            inputField.selectText(nil)
        }
    }

    func updateDisplay(inputText: String, completionText: String, previewText: String, completionJustAccepted: Bool = false) {
        isUpdatingText = true
        defer { isUpdatingText = false }

        let displayText: String
        let selectionStart: Int
        let selectionLength: Int

        if !previewText.isEmpty {
            // Preview mode: show full preview text, cursor at end (no selection)
            displayText = previewText
            selectionStart = previewText.count
            selectionLength = 0
        } else {
            // Normal mode: input + completion (completion part is selected)
            displayText = inputText + completionText
            selectionStart = inputText.count
            selectionLength = completionText.count
        }

        let needsTextUpdate = inputField.stringValue != displayText

        if needsTextUpdate || completionJustAccepted {
            if needsTextUpdate {
                inputField.stringValue = displayText
            }

            if let fieldEditor = inputField.currentEditor() as? NSTextView {
                if completionJustAccepted {
                    // Completion was accepted - move cursor to end
                    fieldEditor.setSelectedRange(NSRange(location: displayText.count, length: 0))
                } else if selectionLength > 0 {
                    // Set selection on completion part only
                    fieldEditor.setSelectedRange(NSRange(location: selectionStart, length: selectionLength))
                } else if needsTextUpdate && previewText.isEmpty && completionText.isEmpty {
                    // Text changed but no completion - keep cursor at end
                    fieldEditor.setSelectedRange(NSRange(location: displayText.count, length: 0))
                }
            }
        }
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
