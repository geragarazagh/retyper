// The Exceptions window, opened from the main window's Exceptions row: the words an undo took back, as tags in the look
// of STT's Dictionary (Return or a comma adds a word, Delete removes one). Saved at every change into Exceptions.txt.

import AppKit

@MainActor final class ExceptionsWindow: NSObject, NSTokenFieldDelegate, NSWindowDelegate {
    let panel: NSPanel
    let field = NSTokenField()
    var exceptions = Exceptions()

    override init() {
        let W: CGFloat = 420, H: CGFloat = 250, M: CGFloat = 20
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = L("Exceptions")
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let v = panel.contentView!
        let note = NSTextField(wrappingLabelWithString: L("Words taken back by switching again or by ⌘Z are no longer fixed automatically. Return adds a word."))
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: M, y: H - 60, width: W - 2 * M, height: 44)   // three lines in any language
        v.addSubview(note)
        let scroll = NSScrollView(frame: NSRect(x: M, y: M, width: W - 2 * M, height: H - 60 - 8 - M))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        field.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: scroll.contentSize.height)
        field.autoresizingMask = [.width]
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",\n")
        field.tokenStyle = .rounded
        field.isBordered = false
        field.delegate = self
        field.target = self; field.action = #selector(edited)
        (field.cell as? NSTokenFieldCell)?.wraps = true
        scroll.documentView = field
        v.addSubview(scroll)
    }

    // The field grows with its tags and the scroll view scrolls (STT's lesson: a fixed field hid the words past its end).
    func fitField() {
        let w = field.frame.width
        field.preferredMaxLayoutWidth = w
        let min = field.enclosingScrollView?.contentSize.height ?? 150
        let cell = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 100_000)).height ?? 0
        field.frame.size.height = max(min, ceil(max(cell, field.intrinsicContentSize.height)) + 24)
    }

    func controlTextDidChange(_ n: Notification) { fitField(); edited() }
    func windowWillClose(_ n: Notification) { panel.makeFirstResponder(nil); edited() }

    @objc func edited() { if let list = field.objectValue as? [String] { exceptions.save(list) } }

    func show(beside main: NSWindow?) {
        exceptions.reload()
        field.objectValue = exceptions.list
        fitField()
        if !panel.isVisible, let main {
            let f = main.frame, s = main.screen?.visibleFrame ?? f
            var x = f.maxX + 12
            if x + panel.frame.width > s.maxX { x = f.midX - panel.frame.width / 2 }
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: f.maxY))
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(field)
        if let editor = field.currentEditor() { editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0) }
    }
}
