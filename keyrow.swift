// The Retype row of the window: which key retypes by hand (manual.swift). Built after macOS's own Dictation shortcut in
// Keyboard settings: a pop-up of double presses, Customize… to record a shortcut, Off; the wording of those items is
// macOS's own (KeyboardSettings.appex Localizable.loctable: DoubleTapControl, DoubleTapCommand, DoubleTapGlobeSymbol,
// CustomizeKey, OffKey, PressKeysNow). Variant A of the test sheets (RETYPE_UI=button, test builds only) is one
// button as in STT's key rows: click, then press a shortcut or tap a modifier twice.

import AppKit
import Carbon.HIToolbox

@MainActor final class KeyRow: NSObject {
    let view: NSView
    let core: Core
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    let button = NSButton(title: "", target: nil, action: nil)
    var asButton = false
    static let height: CGFloat = 72   // the window's row pitch (34), two lines of caption (ru, uk need both), air after it
    // macOS's pattern for the Globe key, «Press %@ Twice», with the key's own sign: Apple's full names («Press Either
    // Command Key Twice») don't fit the row in Russian and Ukrainian.
    static let doubles: [Int] = [optionKey, shiftKey, cmdKey, controlKey]

    init(core: Core) {
        self.core = core
        let W: CGFloat = 340, M: CGFloat = 20
        view = NSView(frame: NSRect(x: 0, y: 0, width: W, height: KeyRow.height))
        super.init()
        #if TRACE
        asButton = ProcessInfo.processInfo.environment["RETYPE_UI"] == "button" || CommandLine.arguments.contains("--button")
        #endif
        let l = NSTextField(labelWithString: L("Retype"))
        l.font = .systemFont(ofSize: 13); l.frame = NSRect(x: M, y: 47, width: 120, height: 18)
        view.addSubview(l)
        // From the window it must be clear that the system's own language key retypes the last word too
        // (the third way, besides a double tap and a shortcut). A caption under the row, as macOS puts under Dictation.
        let cap = NSTextField(wrappingLabelWithString: KeyRow.languageKeyNote())
        cap.font = .systemFont(ofSize: 11); cap.textColor = .secondaryLabelColor
        cap.frame = NSRect(x: M, y: 10, width: W - 2 * M, height: 28)
        view.addSubview(cap)
        if asButton {
            button.frame = NSRect(x: W - M - 160, y: 41, width: 160, height: 28)
            button.bezelStyle = .rounded; button.setButtonType(.pushOnPushOff); button.refusesFirstResponder = true
            button.target = self; button.action = #selector(buttonClicked)
            view.addSubview(button)
        } else {
            popup.controlSize = .small; popup.font = .systemFont(ofSize: 11)
            popup.frame = NSRect(x: W - M - 186, y: 42, width: 190, height: 26)
            popup.target = self; popup.action = #selector(picked)
            popup.refusesFirstResponder = true
            view.addSubview(popup)
        }
        refresh()
    }

    /// «The language key (⌥Space) also retypes the last word.» The key is read from macOS's own setting for
    /// «Select the previous input source» (symbolic hot key 60, else 61 «next source»); without one, no key is named (the same noun in both states, so the caption never changes its wording).
    static func languageKeyNote() -> String {
        let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        for id in ["60", "61"] {
            guard let e = all[id] as? [String: Any], (e["enabled"] as? Bool) ?? ((e["enabled"] as? Int) == 1),
                  let p = (e["value"] as? [String: Any])?["parameters"] as? [Int], p.count == 3 else { continue }
            let f = p[2]   // NSEvent modifier flags
            let mods = (f & (1 << 18) != 0 ? controlKey : 0) | (f & (1 << 19) != 0 ? optionKey : 0) | (f & (1 << 17) != 0 ? shiftKey : 0) | (f & (1 << 20) != 0 ? cmdKey : 0)
            let key = p[1] == kVK_Space ? L("Space") : ManualKey.keyName(p[1])
            return String(format: L("The language key (%@) also retypes the last word."), ManualKey.glyphs(mods) + key)
        }
        return L("The language key also retypes the last word.")
    }

    func refresh() {
        let k = core.manualKey
        if asButton { button.title = k.key == -2 ? L("Off") : k.title; button.state = .off; return }
        popup.removeAllItems()
        for mod in KeyRow.doubles {
            popup.addItem(withTitle: String(format: L("Press %@ Twice"), ManualKey.glyphs(mod))); popup.lastItem?.tag = mod
        }
        popup.menu?.addItem(.separator())
        if k.key >= 0 { popup.addItem(withTitle: k.title); popup.lastItem?.tag = -1 }
        popup.addItem(withTitle: L("Customize…")); popup.lastItem?.tag = -2
        popup.addItem(withTitle: L("Off")); popup.lastItem?.tag = -3
        if k.key == -1 { popup.selectItem(withTag: k.mods) } else if k.key == -2 { popup.selectItem(withTag: -3) } else { popup.selectItem(withTag: -1) }
    }

    func set(_ k: ManualKey) { core.manualKey = k; ManualKey.current = k; refresh() }

    @objc func picked() {
        guard let tag = popup.selectedItem?.tag else { return }
        switch tag {
        case -1: break
        case -2: record()
        case -3: set(ManualKey(key: -2, mods: 0))
        default: set(ManualKey(key: -1, mods: tag))
        }
    }

    @objc func buttonClicked() { if core.recording != nil { core.recording = nil; refresh() } else { record() } }

    // The tap records (it sees taps of a modifier, which the window does not); Esc leaves.
    // While recording, the control itself says so (macOS's «Press keys now»).
    func record() {
        if asButton { button.title = L("Press keys now"); button.state = .on }
        else { popup.addItem(withTitle: L("Press keys now")); popup.lastItem?.tag = -4; popup.selectItem(withTag: -4) }
        core.recording = { [weak self] k in
            guard let self else { return }
            if let k { self.set(k) } else { self.refresh() }
        }
    }
}
