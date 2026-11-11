// The app: one small window set once (Open at Login, Exceptions), nothing in the Dock or the menu bar; the work is core.swift.
// The only permission is Accessibility (macOS 27: «Device Control and Data Access»), for the event tap and for posting
// the retyped keys. No network except Sparkle's daily look at the update feed; no logs; the one file kept is Exceptions.txt.

import AppKit
import ApplicationServices
import Carbon.HIToolbox

startInBackgroundIfAtLogin()

private var tapPort: CFMachPort?
private weak var tapCore: Core?

@MainActor func startTap(_ core: Core) -> Bool {
    tapCore = core
    let mask = [CGEventType.keyDown, .flagsChanged, .scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { proxy, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
            // Keys pressed while the tap was off are missing from the word: a fix would delete the wrong letters.
            MainActor.assumeIsolated { tapCore?.reset("tap re-enabled") }
            return Unmanaged.passUnretained(event)
        }
        // The callback runs on the main run loop, where the tap was added.
        // nil from handle swallows the key; `tapCore?.handle(...) ?? pass` would have passed it anyway.
        return MainActor.assumeIsolated {
            guard let core = tapCore else { return Unmanaged.passUnretained(event) }
            return core.handle(type, event, proxy)
        }
    }, userInfo: nil) else { return false }
    tapPort = port
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
    return true
}

@MainActor final class App: NSObject, NSApplicationDelegate {
    var core: Core!
    var window: AppWindow?
    let exceptionsWindow = ExceptionsWindow()
    var tapOn = false

    func applicationDidFinishLaunching(_ n: Notification) {
        let data = Bundle.main.resourceURL!.appendingPathComponent("data")
        core = Core(dataDir: data)
        window = AppWindow(name: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Retyper",
                           github: Bundle.main.object(forInfoDictionaryKey: "GitHubURL") as? String ?? "https://github.com/geragarazagh",
                           extra: rows())
        window?.onShow = { [weak self] in self?.askAccess() }
        // A key being recorded swallows plain keys everywhere: recording ends with the window (and on an app switch).
        window?.onClose = { [weak self] in self?.core.stopRecording() }
        #if TRACE
        // --shot <file>: the window drawn off screen and written as a picture, then quit (pictures of every window
        // without anything on the screen). --exceptions picks that window.
        if let i = CommandLine.arguments.firstIndex(of: "--shot"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            let panel: NSWindow = CommandLine.arguments.contains("--exceptions") ? exceptionsWindow.panel : window!.panel
            if panel === exceptionsWindow.panel { exceptionsWindow.exceptions.reload(); exceptionsWindow.field.objectValue = ["yt", "j,y", "sysctl"]; exceptionsWindow.fitField() }
            panel.setFrameOrigin(NSPoint(x: -6000, y: -6000)); panel.orderFrontRegardless(); panel.makeFirstResponder(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                typealias F = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                let f = unsafeBitCast(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"), to: F.self)
                if let img = f(.null, 1 << 3, UInt32(panel.windowNumber), 1 | 8)?.takeRetainedValue() {
                    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
                    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
                }
                exit(0)
            }
            return
        }
        #endif
        core.load { [weak self] in self?.tryTap() }

        // Delivered at once: by default a background app gets distributed notifications coalesced, late or never
        // (measured on 26: a ⌥Space switch brought none in 1.5 s, a switch from the menu one after 0.56 s).
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(self, selector: #selector(sourceChanged), name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                       object: nil, suspensionBehavior: .deliverImmediately)
        dn.addObserver(self, selector: #selector(sourcesChanged), name: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                       object: nil, suspensionBehavior: .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let mine = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier == getpid()
            MainActor.assumeIsolated { if !mine { self?.core.stopRecording() }; self?.core.reset("app changed"); self?.core.cur = self?.core.index(of: Core.currentID()) }
        }
        if !AXIsProcessTrusted() { askAccess() }
        #if TRACE
        if CommandLine.arguments.contains("--exceptions") { editExceptions() }   // test pictures of that window
        #endif
    }

    @objc func sourceChanged() {
        trace("notification: current \(Core.currentID() ?? "-")")
        guard let c = core.index(of: Core.currentID()) else { core.cur = nil; return }
        if c != core.cur { core.switched(to: c, nil) }
    }

    @objc func sourcesChanged() { core.rebuild() }

    // macOS's own question, which leads to Privacy & Security; asked again whenever the window is opened without the grant.
    func askAccess() {
        guard !AXIsProcessTrusted() else { return }
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    // Accessibility can be granted at any moment, and macOS tells nobody: look every two seconds until it is.
    func tryTap() {
        guard !tapOn else { return }
        if AXIsProcessTrusted() && startTap(core) { tapOn = true; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.tryTap() }
    }

    var keyRow: KeyRow?

    // Retype (its key), then Exceptions, above Open at Login.
    func rows() -> NSView {
        let k = KeyRow(core: core); keyRow = k
        let e = exceptionsRow()
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: KeyRow.height + e.frame.height))
        e.frame.origin = .zero; k.view.frame.origin = NSPoint(x: 0, y: e.frame.height)
        v.addSubview(e); v.addSubview(k.view)
        return v
    }

    func exceptionsRow() -> NSView {
        let W: CGFloat = 340, M: CGFloat = 20
        let row = NSView(frame: NSRect(x: 0, y: 0, width: W, height: 34))
        let l = NSTextField(labelWithString: L("Exceptions"))
        l.font = .systemFont(ofSize: 13); l.frame = NSRect(x: M, y: 9, width: 180, height: 18)
        row.addSubview(l)
        let b = NSButton(title: L("Edit…"), target: self, action: #selector(editExceptions))
        b.bezelStyle = .rounded; b.controlSize = .small; b.font = .systemFont(ofSize: 11); b.refusesFirstResponder = true
        b.sizeToFit(); b.frame.origin = NSPoint(x: W - M - b.frame.width, y: 7)
        row.addSubview(b)
        return row
    }

    @objc func editExceptions() { exceptionsWindow.show(beside: window?.panel) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window?.show(); return false }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    #if TRACE
    // Test builds: --dark draws the app dark, for pictures of every window in both themes on a machine whose system
    // theme can't be switched over ssh (HoldQ's way).
    if CommandLine.arguments.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
    if CommandLine.arguments.contains("--light") { app.appearance = NSAppearance(named: .aqua) }
    #endif
    app.run()
}
