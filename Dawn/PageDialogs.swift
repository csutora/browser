import AppKit

// a question a page puts to the person: a javascript alert, confirm or prompt, or a site asking to sign
// in. it belongs to its tab, covering only that tab's page and waiting there while other tabs are used.
struct PageDialog {
    enum Field {
        case text(placeholder: String, value: String, contentType: NSTextContentType? = nil)
        case secure(placeholder: String)
    }

    var title: String
    var message = ""
    var fields: [Field] = []
    var confirmTitle = "OK"
    var cancelTitle: String? = "Cancel"
    // called exactly once: whether it was confirmed, and what the fields held
    var completion: (Bool, [String]) -> Void
}

// the dialog over its page: the page dims and takes no input, and the card sits at the top of it
final class PageDialogView: FlippedView, NSTextFieldDelegate {
    private let dialog: PageDialog
    private let onDone: () -> Void
    private var finished = false

    private let card = FlippedView()
    private let darkBg = NSView()
    private let effectView = NSVisualEffectView()
    private let borderView = NSView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let messageScroll = NSScrollView()
    private let messageView = NSTextView()
    private var fields: [DialogField] = []
    private var buttons: [DialogButton] = []

    private let maxCardWidth: CGFloat = 380
    private let sideMargin: CGFloat = 16
    private let topInset: CGFloat = 28
    private let padding: CGFloat = 20
    private let maxMessageHeight: CGFloat = 240
    private let fieldHeight: CGFloat = 30
    private let buttonHeight: CGFloat = 28

    init(_ dialog: PageDialog, onDone: @escaping () -> Void) {
        self.dialog = dialog
        self.onDone = onDone
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        // drops land on the dialog rather than reaching the page under it
        registerForDraggedTypes([.fileURL, .URL, .string, .tiff, .png])

        card.wantsLayer = true
        card.layer?.masksToBounds = false
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.32
        card.layer?.shadowRadius = 18
        card.layer?.shadowOffset = CGSize(width: 0, height: -8)
        for v in [darkBg, effectView, borderView] {
            v.wantsLayer = true
            v.layer?.cornerRadius = 12
            v.layer?.cornerCurve = .continuous
            v.layer?.masksToBounds = true
            v.autoresizingMask = [.width, .height]
            card.addSubview(v)
        }
        darkBg.layer?.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 0.88).cgColor
        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        borderView.layer?.borderWidth = 1
        borderView.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        addSubview(card)

        titleLabel.stringValue = dialog.title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byWordWrapping
        card.addSubview(titleLabel)

        if !dialog.message.isEmpty {
            messageView.string = dialog.message
            messageView.font = .systemFont(ofSize: 13)
            messageView.textColor = .secondaryLabelColor
            messageView.isEditable = false
            messageView.isSelectable = true
            messageView.drawsBackground = false
            messageView.textContainerInset = .zero
            messageView.textContainer?.lineFragmentPadding = 0
            messageView.textContainer?.widthTracksTextView = true
            messageScroll.documentView = messageView
            messageScroll.drawsBackground = false
            messageScroll.scrollerStyle = .overlay
            messageScroll.autohidesScrollers = true
            card.addSubview(messageScroll)
        }

        for spec in dialog.fields {
            let field = DialogField(spec)
            field.textField.delegate = self
            fields.append(field)
            card.addSubview(field)
        }
        for (i, field) in fields.enumerated() {
            field.textField.nextKeyView = fields[(i + 1) % fields.count].textField
        }

        if let cancelTitle = dialog.cancelTitle {
            let cancel = DialogButton(title: cancelTitle, primary: false)
            cancel.onClick = { [weak self] in self?.finish(false) }
            buttons.append(cancel)
        }
        let confirm = DialogButton(title: dialog.confirmTitle, primary: true)
        confirm.onClick = { [weak self] in self?.finish(true) }
        buttons.append(confirm)
        buttons.forEach { card.addSubview($0) }

        setAccessibilityRole(.sheet)
        setAccessibilityLabel(dialog.title)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Showing

    func present(in host: NSView) {
        frame = host.bounds
        autoresizingMask = [.width, .height]
        host.addSubview(self)
        (host as? DawnWebView)?.dialogView = self
        layoutSubtreeIfNeeded()

        let final = card.frame
        alphaValue = 0
        card.frame = final.offsetBy(dx: 0, dy: -10)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            context.allowsImplicitAnimation = true
            animator().alphaValue = 1
            card.animator().frame = final
        }
        takeFocus()
    }

    // the keyboard goes to the dialog whenever its page is on screen: to the first field still to be
    // filled in (the password, when asked again with the username kept), else the first
    func takeFocus() {
        guard !finished, let window, !isHiddenOrHasHiddenAncestor else { return }
        let field = fields.first(where: { $0.textField.stringValue.isEmpty }) ?? fields.first
        window.makeFirstResponder(field?.textField ?? self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        takeFocus()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        takeFocus()
    }

    // MARK: - Answering

    func cancel() {
        finish(false)
    }

    private func finish(_ confirmed: Bool) {
        guard !finished else { return }
        finished = true
        let values = fields.map(\.textField.stringValue)

        // the page gets the keyboard back before anything it does next (like asking again) takes it
        let web = superview as? DawnWebView
        if web?.dialogView === self { web?.dialogView = nil }
        let responder = window?.firstResponder
        if responder === self || fields.contains(where: { $0.textField.currentEditor().map { $0 === responder } ?? false }) {
            window?.makeFirstResponder(superview)
        }

        dialog.completion(confirmed, values)
        onDone()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
        })
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finish(true)
        case #selector(NSResponder.cancelOperation(_:)):
            finish(dialog.cancelTitle == nil)
        default:
            return false
        }
        return true
    }

    override var acceptsFirstResponder: Bool { !finished }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: finish(true)
        case 53: finish(dialog.cancelTitle == nil)
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        finish(dialog.cancelTitle == nil)
    }

    // MARK: - Shielding the page

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !finished, !isHidden else { return nil }
        return super.hitTest(point) ?? (frame.contains(point) ? self : nil)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func smartMagnify(with event: NSEvent) {}
    override func swipe(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let width = min(maxCardWidth, max(220, bounds.width - sideMargin * 2))
        let inner = width - padding * 2
        var y = padding

        let titleHeight = ceil(titleLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner + 4, height: .greatestFiniteMagnitude)).height ?? 16)
        titleLabel.preferredMaxLayoutWidth = inner + 4
        // a label insets its text by a couple of points; out by as much, it lines up with the rest
        titleLabel.frame = NSRect(x: padding - 2, y: y, width: inner + 4, height: titleHeight)
        y += titleHeight

        if messageScroll.superview != nil {
            y += 6
            messageView.frame = NSRect(x: 0, y: 0, width: inner, height: 0)
            messageView.textContainer?.containerSize = NSSize(width: inner, height: .greatestFiniteMagnitude)
            let textHeight: CGFloat
            if let manager = messageView.layoutManager, let container = messageView.textContainer {
                manager.ensureLayout(for: container)
                textHeight = ceil(manager.usedRect(for: container).height)
            } else {
                textHeight = 16
            }
            let shown = min(textHeight, maxMessageHeight)
            messageView.frame = NSRect(x: 0, y: 0, width: inner, height: textHeight)
            messageScroll.hasVerticalScroller = textHeight > shown
            messageScroll.frame = NSRect(x: padding, y: y, width: inner, height: shown)
            y += shown
        }

        if !fields.isEmpty {
            y += 14
            for (i, field) in fields.enumerated() {
                if i > 0 { y += 8 }
                field.frame = NSRect(x: padding, y: y, width: inner, height: fieldHeight)
                y += fieldHeight
            }
        }

        y += 18
        var x = width - padding
        for button in buttons.reversed() {
            let w = button.preferredWidth
            x -= w
            button.frame = NSRect(x: x, y: y, width: w, height: buttonHeight)
            x -= 8
        }
        y += buttonHeight + 16

        let cardX = ((bounds.width - width) / 2).rounded()
        card.frame = NSRect(x: cardX, y: min(topInset, max(8, bounds.height - y)), width: width, height: y)
    }
}

// MARK: - Parts

private final class DialogField: NSView {
    let textField: NSTextField

    init(_ spec: PageDialog.Field) {
        switch spec {
        case .text(let placeholder, let value, let contentType):
            let field = DialogTextField(string: value)
            field.contentType = contentType
            textField = field
            textField.placeholderAttributedString = Self.placeholder(placeholder)
        case .secure(let placeholder):
            let field = DialogSecureField(string: "")
            field.contentType = .password
            textField = field
            textField.placeholderAttributedString = Self.placeholder(placeholder)
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        styleFocus(false)

        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 13)
        textField.textColor = .labelColor
        textField.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        (textField as? DialogTextField)?.onFocus = { [weak self] in self?.styleFocus($0) }
        (textField as? DialogSecureField)?.onFocus = { [weak self] in self?.styleFocus($0) }
        addSubview(textField)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func placeholder(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 13)])
    }

    private func styleFocus(_ focused: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            layer?.borderColor = NSColor.white.withAlphaComponent(focused ? 0.3 : 0.1).cgColor
        }
    }

    override func layout() {
        super.layout()
        let height = textField.cell?.cellSize.height ?? 16
        textField.frame = backingAlignedRect(NSRect(x: 9, y: (bounds.height - height) / 2, width: bounds.width - 18, height: height), options: .alignAllEdgesNearest)
    }

    // a click anywhere in the box edits it, not only on the line of text
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textField)
    }
}

private final class DialogTextField: NSTextField {
    var onFocus: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?(true) }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocus?(false)
    }
}

private final class DialogSecureField: NSSecureTextField {
    var onFocus: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?(true) }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocus?(false)
    }
}

private final class DialogButton: NSView {
    var onClick: (() -> Void)?
    private let label: NSTextField
    private let primary: Bool
    private var hovered = false
    private var pressed = false
    private var trackingArea: NSTrackingArea?

    init(title: String, primary: Bool) {
        self.primary = primary
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = primary ? NSColor.black.withAlphaComponent(0.88) : .labelColor
        label.alignment = .center
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        style()
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredWidth: CGFloat {
        max(76, ceil(label.intrinsicContentSize.width) + 28)
    }

    override func layout() {
        super.layout()
        let height = label.cell?.cellSize.height ?? 16
        label.frame = backingAlignedRect(NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height), options: .alignAllEdgesNearest)
    }

    private func style() {
        let alpha: CGFloat = primary ? (pressed ? 0.72 : hovered ? 1 : 0.9) : (pressed ? 0.18 : hovered ? 0.13 : 0.08)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        style()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        style()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        style()
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        guard inside != pressed else { return }
        pressed = inside
        style()
    }

    override func mouseUp(with event: NSEvent) {
        let clicked = pressed
        pressed = false
        hovered = bounds.contains(convert(event.locationInWindow, from: nil))
        style()
        if clicked { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
