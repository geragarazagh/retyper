// The app's whole interface: one small window of a fixed size, the same as in the hot key apps (#HEX, OCR) without
// the shortcut rows: icon, name, version, Check for Updates…, the app's own row if it has one, Open at Login, links, Quit. Opening the
// app shows it, closing it leaves the app working in the background, with nothing in the Dock or the menu bar.
// The same file is used by every background app with no hot key of its own.

import AppKit
import ServiceManagement

// Open at Login is a launchd agent (Contents/Library/LaunchAgents in the bundle) that passes --login:
// an app started as a login item can't otherwise tell that from being opened by hand, and only the
// second should show the window. The agent's copy only starts the app through `open` and exits,
// because launchd kills what it started when the agent is unregistered, and that would take the
// running app down with the switch.
func startInBackgroundIfAtLogin() {
    guard CommandLine.arguments.contains("--login") else { return }
    let me = ProcessInfo.processInfo.processIdentifier
    if !NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").contains(where: { $0.processIdentifier != me }) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", Bundle.main.bundlePath, "--args", "--background"]
        try? p.run()
        p.waitUntilExit()
    }
    exit(0)
}

// The English text is the key; ru and uk come from lang/, picked by macOS from the system language.
// Wording of macOS's own terms (Open at Login, Quit, Privacy & Security) is copied from its .loctable files.
func L(_ s: String) -> String { NSLocalizedString(s, comment: "") }

func report(_ title: String, _ details: String) {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = title
    let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
    field.string = details; field.isEditable = false; field.isSelectable = true
    field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    let scroll = NSScrollView(frame: field.frame); scroll.documentView = field; scroll.hasVerticalScroller = true
    a.accessoryView = scroll
    a.addButton(withTitle: "OK")
    a.addButton(withTitle: L("Copy"))
    if a.runModal() == .alertSecondButtonReturn {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(title)\n\(details)", forType: .string)
    }
}

// The app's own icon, as Finder shows it now: on macOS 26+ the icon follows the theme (Assets.car), so it is fetched
// again whenever the window's appearance changes; NSApp.applicationIconImage keeps the one from launch.
final class AppIconView: NSImageView {
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    // NSWorkspace gives the icon at 32 pt and an image view never enlarges it by itself (seen at a third of the frame).
    private func refresh() {
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = bounds.size
        imageScaling = .scaleProportionallyUpOrDown
        image = icon
    }
}

@MainActor final class AppWindow: NSObject, NSWindowDelegate {
    let name: String
    let github: String
    let login: SMAppService
    let extra: NSView?       // an app's own row, between the version and Open at Login
    let panel: NSPanel
    let loginSwitch = NSSwitch()
    var onShow: (() -> Void)?
    var onClose: (() -> Void)?

    init(name: String, github: String, extra: NSView? = nil) {
        self.name = name
        self.github = github
        self.extra = extra
        login = SMAppService.agent(plistName: "\(Bundle.main.bundleIdentifier ?? "").login.plist")
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 260 + (extra?.frame.height ?? 0)),
                        styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        build()
        _ = Updates.shared   // starts the daily check
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            let f = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if e.keyCode == 53 && f.isEmpty || e.charactersIgnoringModifiers == "w" && f == .command { self.panel.performClose(nil); return nil }
            return e
        }
        // Open at Login stays off until a person turns it on: an app adds nothing to their login items by itself.
        // The switch is in this window, which the first launch shows.
        let d = UserDefaults.standard
        let first = !d.bool(forKey: "launched")
        if first { d.set(true, forKey: "launched") }
        if first || !CommandLine.arguments.contains("--background") { show() }
    }

    func build() {
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let v = panel.contentView!
        let W: CGFloat = 340, M: CGFloat = 20
        let up = extra?.frame.height ?? 0
        // Rows go 34 pt apart, #HEX's own pitch between its two shortcut rows; the app's row sits one pitch above Open at
        // Login (label 59 -> 93), and everything above moves up by the row, so the version keeps its 19 pt to the top row.
        if let extra { extra.frame.origin = NSPoint(x: 0, y: 84); v.addSubview(extra) }

        func text(_ s: String, _ font: NSFont, _ color: NSColor, _ frame: NSRect, _ align: NSTextAlignment) {
            let l = NSTextField(labelWithString: s)
            l.font = font; l.textColor = color; l.alignment = align; l.frame = frame
            v.addSubview(l)
        }
        // Icon, name, version and Check for Updates… keep #HEX's spacing: the button 32 pt under the version.
        let icon = AppIconView(frame: NSRect(x: (W - 64) / 2, y: 170 + up, width: 64, height: 64))
        v.addSubview(icon)
        text(name, .boldSystemFont(ofSize: 15), .labelColor, NSRect(x: M, y: 144 + up, width: W - 2 * M, height: 20), .center)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        text(version, .systemFont(ofSize: 11), .secondaryLabelColor, NSRect(x: M, y: 128 + up, width: W - 2 * M, height: 14), .center)
        let updates = NSButton(title: L("Check for Updates…"), target: Updates.shared, action: #selector(Updates.check))
        updates.bezelStyle = .rounded
        updates.controlSize = .small
        updates.font = .systemFont(ofSize: 11)
        updates.refusesFirstResponder = true
        updates.sizeToFit()
        updates.frame.origin = NSPoint(x: (W - updates.frame.width) / 2, y: 96 + up)
        v.addSubview(updates)

        text(L("Open at Login"), .systemFont(ofSize: 13), .labelColor, NSRect(x: M, y: 59, width: 236, height: 18), .left)
        loginSwitch.controlSize = .small
        loginSwitch.sizeToFit()
        loginSwitch.frame.origin = NSPoint(x: W - M - loginSwitch.frame.width + 5, y: 58)   // the switch draws 5 pt inside its frame
        loginSwitch.target = self; loginSwitch.action = #selector(loginChanged)
        loginSwitch.refusesFirstResponder = true
        v.addSubview(loginSwitch)

        var x = M
        for (label, url) in [(L("Herman Harazha"), "https://geragaraza.com"), (L("GitHub"), github)] {
            let b = NSButton(title: label, target: self, action: #selector(openLink(_:)))
            b.isBordered = false
            b.attributedTitle = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.linkColor])
            b.toolTip = url
            b.refusesFirstResponder = true
            b.sizeToFit()
            b.frame.origin = NSPoint(x: x, y: 20)
            v.addSubview(b)
            x += b.frame.width + 12
        }
        // A background app with no menu has no other way to be stopped.
        let quit = NSButton(title: L("Quit"), target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        quit.controlSize = .small
        quit.font = .systemFont(ofSize: 11)
        quit.refusesFirstResponder = true
        quit.sizeToFit()
        quit.frame.origin = NSPoint(x: W - M - quit.frame.width, y: 16)
        v.addSubview(quit)
    }

    func show() {
        loginSwitch.state = login.status == .enabled ? .on : .off
        onShow?()
        if !panel.isVisible { panel.center() }
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        Updates.shared.appOpened()
    }

    func windowWillClose(_ n: Notification) { onClose?() }
    func windowDidBecomeKey(_ n: Notification) { loginSwitch.state = login.status == .enabled ? .on : .off; onShow?() }

    @objc func openLink(_ b: NSButton) {
        if let s = b.toolTip, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    @objc func loginChanged() {
        do {
            if loginSwitch.state == .on {
                if login.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() } else { try login.register() }
            } else {
                try login.unregister()
            }
        } catch {
            report("\(name): \(L("Open at Login"))", "\(error)")
        }
        loginSwitch.state = login.status == .enabled ? .on : .off
    }
}
