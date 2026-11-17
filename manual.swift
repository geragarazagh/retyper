// manual.swift: the Retype key, a command of its own besides the language key, for the cases the detector judges
// wrong or a stretch found later. It does what it is told, with no judgement of the detector:
// - a selection: retyped in the other script (Latin → Cyrillic, Cyrillic → Latin), any length;
// - else the last word (the caret touches it, or the word and one space): retyped in the other script;
// - pressed again with nothing else done since, the same keys go on through the installed languages and back as typed
//   (cycle.swift): Latin typed → the best Cyrillic → the other Cyrillic → as typed → …; right after an automatic fix or a
//   retype by the language key the cycle goes on from what that chose. With two layouts it is a toggle, as before
//   2026-11-17, when the second press always went back. Back as typed after an automatic fix remembers the word.
// The layout follows the text at every step. The key is a shortcut with ⌘, ⌥ or ⌃, or one modifier tapped twice. A tap counts only
// when the modifier goes down and up alone and quickly: holding ⌥ for zoom with the wheel, or ⌥Space, is never a tap
// (a switcher that fires on an accidental double ⌥ retypes whole texts).
//
// Reading the selection: Accessibility first (kAXSelectedText of the focused element, replaced in place where the field
// allows it). Electron and Chromium apps (VS Code, Slack…) build that tree only when asked
// (AXManualAccessibility), so the Retype key asks for it in the app in front the first time. Where an app gives no
// Accessibility text at all, the selection is copied with ⌘C and the clipboard put back as it was right after; a
// clipboard history app may still keep that copy. A terminal's selection is its output, not text to replace: left alone.

import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// key >= 0: a shortcut (virtual key + Carbon modifiers); key == -1: the modifier in `mods` tapped twice.
struct ManualKey: Equatable {
    var key: Int
    var mods: Int

    /// ⌥ twice: Option alone does nothing in macOS or in common apps; ⇧ twice is Search Everywhere in JetBrains IDEs,
    /// ⌃ twice can be macOS's Dictation key, ⌘ twice is taken by launchers (Alfred, Raycast) when set.
    static let standard = ManualKey(key: -1, mods: optionKey)

    static var current: ManualKey {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: "retypeKey") != nil else { return standard }
            return ManualKey(key: d.integer(forKey: "retypeKey"), mods: d.integer(forKey: "retypeMods"))
        }
        set {
            let d = UserDefaults.standard
            if newValue == standard { d.removeObject(forKey: "retypeKey"); d.removeObject(forKey: "retypeMods") }
            else { d.set(newValue.key, forKey: "retypeKey"); d.set(newValue.mods, forKey: "retypeMods") }
        }
    }

    static func glyphs(_ mods: Int) -> String {
        (mods & controlKey != 0 ? "⌃" : "") + (mods & optionKey != 0 ? "⌥" : "") + (mods & shiftKey != 0 ? "⇧" : "") + (mods & cmdKey != 0 ? "⌘" : "")
    }

    var title: String {
        if key < 0 { let g = ManualKey.glyphs(mods); return g + " " + g }
        return ManualKey.glyphs(mods) + ManualKey.keyName(key)
    }

    static let named: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ForwardDelete: "⌦", kVK_Delete: "⌫", kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_Space: "Space", kVK_Escape: "Esc", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19"]

    // The Latin character of a key whatever layout is on: a shortcut reads ⌃⌥R, not ⌃⌥К (STT's way).
    static func keyName(_ key: Int) -> String {
        if let n = named[key] { return n }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = unsafeBitCast(raw, to: CFData.self)
        let layout = unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self)
        var dead: UInt32 = 0, count = 0
        var chars = [UniChar](repeating: 0, count: 4)
        UCKeyTranslate(layout, UInt16(key), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                       OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &count, &chars)
        return String(utf16CodeUnits: chars, count: count).uppercased()
    }
}

/// A selection the Retype key (or ⌥Space's gated conversion) changed, while nothing else happened: pressed again, the
/// next step of its cycle; after the last, back as typed, and on.
struct SelectionChange {
    var orig: String                        // the text as selected
    var src: Int                            // the layout whose keys typed it
    var steps: [(layout: Int, out: String)] // the cycle (cycle.swift): each layout and the text it reads
    var at = -1                             // the step on screen; -1: orig
    var element: AXUIElement?               // replaced in place through Accessibility (and selected again)
    var selected = true                     // the text on screen is still selected (set through Accessibility, or not yet replaced)
    var now: String { at < 0 ? orig : steps[at].out }
    var layout: Int { at < 0 ? src : steps[at].layout }
}

extension Core {
    static func carbonMods(_ f: CGEventFlags) -> Int {
        (f.contains(.maskCommand) ? cmdKey : 0) | (f.contains(.maskAlternate) ? optionKey : 0)
            | (f.contains(.maskControl) ? controlKey : 0) | (f.contains(.maskShift) ? shiftKey : 0)
    }

    static func modOfKey(_ code: Int) -> Int {
        switch code {
        case kVK_Shift, kVK_RightShift: return shiftKey
        case kVK_Option, kVK_RightOption: return optionKey
        case kVK_Command, kVK_RightCommand: return cmdKey
        case kVK_Control, kVK_RightControl: return controlKey
        default: return 0
        }
    }

    func clearTaps() { tapMod = 0; lastTap = nil }

    // MARK: the key

    /// A modifier went down or up. Two clean taps of the same modifier (each down and up within 0.3 s, the second
    /// down within 0.4 s of the first up, nothing else between) are the double tap.
    func flagsChanged(_ e: CGEvent, _ proxy: CGEventTapProxy) {
        let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
        let mod = Core.modOfKey(code), held = Core.carbonMods(e.flags), now = CACurrentMediaTime()
        guard mod != 0 else { clearTaps(); return }            // Caps Lock, Fn, Globe
        if held == mod {                                         // this modifier down, alone
            if let l = lastTap, (l.mod != mod || now - l.at > 0.4) { lastTap = nil }
            tapMod = mod; tapDownAt = now
        } else if held == 0, tapMod == mod {                     // and up again
            tapMod = 0
            guard now - tapDownAt < 0.3 else { lastTap = nil; return }
            if let l = lastTap, l.mod == mod, tapDownAt - l.at < 0.4 {
                lastTap = nil
                let k = ManualKey(key: -1, mods: mod)
                if let r = recording { recording = nil; r(k); return }
                if manualKey == k { trace("double tap \(k.title)"); retype(proxy) }
            } else { lastTap = (mod, now) }
        } else { clearTaps() }                                   // two modifiers, or one let go while another is held
    }

    /// The shortcut, when it is one: swallowed and acted on.
    func manualKeyDown(_ e: CGEvent, _ proxy: CGEventTapProxy) -> Bool {
        guard manualKey.key >= 0, Int(e.getIntegerValueField(.keyboardEventKeycode)) == manualKey.key,
              Core.carbonMods(e.flags) == manualKey.mods else { selPending = nil; return false }
        guard e.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return true }
        comboAt = nil; clearTaps()
        trace("shortcut \(manualKey.title)")
        retype(proxy)
        return true
    }

    /// While the window records a new key: the next shortcut (⌘, ⌥ or ⌃ with a key, or an F key), Esc to leave.
    /// A double tap is caught in flagsChanged. Plain keys are refused: they would stop typing that letter everywhere.
    func stopRecording() { if let r = recording { recording = nil; r(nil) } }

    func recordKey(_ e: CGEvent) -> Bool {
        guard let r = recording else { return false }
        let code = Int(e.getIntegerValueField(.keyboardEventKeycode)), mods = Core.carbonMods(e.flags)
        if code == kVK_Escape && mods == 0 { recording = nil; r(nil); return true }
        if mods & (cmdKey | optionKey | controlKey) == 0 && !(ManualKey.named[code]?.hasPrefix("F") ?? false) { NSSound.beep(); return true }
        recording = nil; r(ManualKey(key: code, mods: mods))
        return true
    }

    // MARK: retype

    /// The Retype key was pressed. Inside the tap callback (proxy set) for what the buffer knows; the selection is
    /// read after the callback, since another app's Accessibility answer can take a while and keys must not wait.
    func retype(_ proxy: CGEventTapProxy) {
        guard let d = detector, !secure() else { return }
        retypeApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // 1. Our last change (an automatic fix, a retype by the language key or by this key, or this key's way back),
        //    nothing typed since: the next step of the cycle.
        if let p = pending ?? again, p.start + p.count <= items.count { step(p, proxy); return }
        if let s = selPending { selPending = nil; DispatchQueue.main.async { self.stepSelection(s) }; return }
        // A shortcut since the last word (⌘A, ⌘C, a click in a menu): the word is no longer what the caret touches.
        if comboAt != nil { reset("shortcut before the Retype key") }
        // 2. A selection wins over the word typed before it (found 2026-11-11: text typed, then ⌘A and the key retyped
        // the old word). Accessibility answers after the callback, so the rest runs just after it.
        DispatchQueue.main.async { self.retypeAfter() }
    }

    func retypeAfter(asked: Bool = false) {
        var sel = AXIsProcessTrusted() ? Core.selection() : .unknown
        #if TRACE
        if ProcessInfo.processInfo.environment["SK_CLIPBOARD"] != nil { sel = .unknown }   // test the ⌘C way anywhere
        #endif
        if case let .text(text, el) = sel, !text.isEmpty {
            startSelection(text, element: el)
            return
        }
        // Electron and Chromium build their Accessibility tree only when asked: ask, look again a moment later.
        if case .unknown = sel, !asked, AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication, Core.isChromium(app) {
            askTree(app.processIdentifier)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.retypeAfter(asked: true) }
            return
        }
        // VS Code's editor (Monaco) shows Accessibility an empty selection unless its screen reader mode is on: in
        // Chromium apps an empty answer is not trusted, the clipboard is asked (measured 2026-11-11 on 14).
        if case .text("", _) = sel, let app = NSWorkspace.shared.frontmostApplication, Core.isChromium(app), items.isEmpty {
            copySelection { [weak self] text in
                // Monaco copies the whole line, ending in a line break, when nothing is selected: not a selection.
                guard let self, let text, !text.isEmpty, !text.hasSuffix("\n") else { return }
                self.startSelection(text, element: nil)
            }
            return
        }
        guard let d = detector else { return }
        // 3. The last word: forced into the other script, the first step of its cycle.
        var end = items.count
        if end > 0, items[end - 1].boundary == " " { end -= 1 }
        if end > 0, items[end - 1].boundary == nil {
            let ws = wordStart(before: end)
            let word = Array(items[ws..<end])
            let from = word[0].layout
            if word.allSatisfy({ $0.layout == from }) {
                let a = Action(start: ws, count: word.count, orig: word, origLayout: from, auto: false, typed: d.layouts[from].read(word.map { $0.key }))
                if step(a, nil) { trace("retype key: word"); return }
            }
        }
        // 4. A selection Accessibility can't see (Electron before its tree is on, apps without one).
        retypeSelection()
    }

    /// One step of the cycle for our last change, or the first one for a word (a.steps empty, shown as typed): the span
    /// retyped in the next layout, or, after the last, back as typed. False when there is no step (the word reads the same
    /// in every layout).
    @discardableResult
    func step(_ a: Action, _ proxy: CGEventTapProxy?) -> Bool {
        guard let d = detector else { return false }
        var p = a
        let shown = p.orig.firstIndex(where: { $0.boundary == nil }).map { items[p.start + $0].layout } ?? p.origLayout
        // Where the span stands in its cycle. The cycle is built once, at the first press, and kept: rebuilt each time,
        // its ties would follow the Cyrillic used last, which each step changes. A language key switch in between may
        // have moved the span to a layout the cycle lacks: then a new cycle from there.
        if shown == p.origLayout { p.at = -1 }
        else if let i = p.steps.firstIndex(of: shown) { p.at = i }
        else { p.steps = []; p.at = 0 }
        if p.steps.isEmpty {
            var words: [[Key]] = [[]]
            for x in p.orig { if x.boundary == nil { words[words.count - 1].append(x.key) } else if !words[words.count - 1].isEmpty { words.append([]) } }
            p.steps = d.retypeCycle(words.filter { !$0.isEmpty }, typed: p.origLayout, first: shown == p.origLayout ? nil : shown, lastCyrillic: lastCyr)
            if p.steps.isEmpty { return false }
        }
        let tail = Array(items[(p.start + p.count)...])   // boundaries typed after the change (its Space)
        let next = p.at + 1
        if next < p.steps.count {
            let to = p.steps[next]
            select(to)
            replace(from: p.start, with: p.orig.map { var x = $0; if x.boundary == nil { x.layout = to }; return x } + tail, typeIn: to, proxy)
            // After this key the span is his choice: the language key back to where it was typed takes it back, as
            // after any retype by hand (the «clear fix only switches» rule is for the automatic fix alone).
            p.at = next; p.margin = 0
            pending = p; again = nil; settled = false
            trace("retype key: step \(next + 1) of \(p.steps.count), \(d.layouts[to].id)")
        } else {
            select(p.origLayout)
            replace(from: p.start, with: p.orig + tail, typeIn: p.origLayout, proxy)
            if p.auto { exceptions.add(p.typed) }
            p.at = -1
            pending = nil; again = p; settled = true
            trace("retype key: back")
        }
        runStart = items.count
        return true
    }

    /// The Retype key's cycle over a selection (cycle.swift); `first` when ⌥Space's conversion already chose a layout.
    func selectionCycle(_ text: String, preferred: Int?, first: Int? = nil) -> SelectionChange? {
        guard let c = detector?.retypeCycle(selection: text, preferred: preferred, first: first, lastCyrillic: lastCyr) else { return nil }
        return SelectionChange(orig: text, src: c.src, steps: c.steps)
    }

    /// ⌥Space over a selection: converted only into a layout it reads much better in (sum of word scores, odds > 10).
    func plan(_ text: String, preferred: Int?) -> (out: String, target: Int, src: Int)? {
        guard let d = detector, let src = d.source(of: text, preferred: preferred, lastCyrillic: lastCyr) else { return nil }
        let words = d.selectionWords(text, src)
        guard !words.isEmpty else { return nil }
        var total = [Int: Float](), typed: Float = 0
        for k in words {
            let rs = d.readings(k, asTyped: src)
            typed += rs[src].score
            for r in rs where r.layout != src && d.layouts[r.layout].lang != nil { total[r.layout, default: 0] += r.score }
        }
        guard let best = total.max(by: { a, b in abs(a.value - b.value) < 0.5 ? (b.key == lastCyr || b.key == preferred) : a.value < b.value }),
              best.value - typed > 1 else { return nil }
        let out = d.convert(text, src, best.key)
        return out == text ? nil : (out, best.key, src)
    }

    /// The selection, through Accessibility or, where an app has none, through ⌘C. Electron and Chromium apps are asked
    /// for their Accessibility tree the first time, and looked at again a moment later (the main thread, where the
    /// key tap runs, never sleeps).
    func retypeSelection(asked: Bool = false) {
        guard AXIsProcessTrusted() else { return }
        var sel = Core.selection()
        #if TRACE
        if ProcessInfo.processInfo.environment["SK_CLIPBOARD"] != nil { sel = .unknown }   // test the ⌘C way anywhere
        #endif
        switch sel {
        case .text(let text, let el):
            guard !text.isEmpty else { trace("retype key: nothing selected"); return }
            startSelection(text, element: el)
        case .notText:
            trace("retype key: focus is not editable text")
        case .unknown:
            var testClipboard = false
            #if TRACE
            testClipboard = ProcessInfo.processInfo.environment["SK_CLIPBOARD"] != nil
            #endif
            if !asked, !testClipboard, let app = NSWorkspace.shared.frontmostApplication, Core.isChromium(app) {
                askTree(app.processIdentifier)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.retypeSelection(asked: true) }
                return
            }
            copySelection { [weak self] text in
                guard let self, let text, !text.isEmpty else { return }
                self.startSelection(text, element: nil)
            }
        }
    }

    /// The Retype key's first press over a selection: the first step of its cycle.
    func startSelection(_ text: String, element: AXUIElement?) {
        guard var s = selectionCycle(text, preferred: cur) else { trace("retype key: selection reads the same everywhere"); return }
        s.element = element
        show(s, step: 0)
    }

    /// Pressed again over the selection it changed: the next step, after the last back as typed, and round again.
    func stepSelection(_ s: SelectionChange) { show(s, step: s.at + 1 < s.steps.count ? s.at + 1 : -1) }

    /// Puts step `next` (-1: the text as selected) where the selection's current text is, and selects its layout.
    func show(_ s0: SelectionChange, step next: Int) {
        var s = s0
        let old = s.now, overSelection = s.at == -1 && s.selected   // the text as selected, still selected
        s.at = next
        let new = s.now
        trace("selection «\(old.prefix(40))» -> «\(new.prefix(40))»")
        // Chromium answers «success» to setting the selected text and changes nothing (VS Code on 14, 2026-11-11):
        // there the text is typed over the selection, as a person would.
        let chromium = NSWorkspace.shared.frontmostApplication.map(Core.isChromium) ?? false
        if !chromium, s.selected, let el = s.element, Core.setSelection(el, to: new) {
            select(s.layout); reset("selection retyped"); selPending = s; return
        }
        // Typed text goes wherever the focus is now, and a line break or tab can only be typed as Return or Tab, which
        // send a chat message or move the focus. So nothing is typed if the front app changed since the key was pressed
        // (the selection is read up to half a second later), if a password field took the focus, or if the selection
        // holds more than one line (security pass before 0.1, 2026-11-11). An app switch since clears selPending already.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == retypeApp, !secure(),
              !new.contains(where: { $0 == "\n" || $0 == "\t" || $0 == "\r" }) else { trace("selection not typed"); return }
        select(s.layout)
        reset("selection retyped")
        // The selection itself is typed over. Later the text is ours: still selected (set through Accessibility,
        // which then failed), one Backspace takes it; typed by us, a Backspace a letter.
        if !overSelection { for _ in 0..<(s0.selected ? 1 : old.count) { press(51, via: nil) } }
        type(new, in: s.layout, nil)
        s.selected = false; s.element = nil
        selPending = s
    }

    // MARK: Accessibility and the clipboard

    enum Selection { case text(String, AXUIElement), notText, unknown }

    /// .text: an editable text and its selection ("" when none). .notText: Accessibility answers, but the focus is no
    /// text to edit (a terminal's output). .unknown: the app gives no Accessibility text: the clipboard is the way.
    static func selection() -> Selection {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .unknown }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.5)
        var f: CFTypeRef?
        let el: AXUIElement? = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &f) == .success && f != nil ? (f as! AXUIElement) : nil
        guard let el else { return .unknown }
        // A list of files or rows (Finder) is no text: ⌘C there copies files, and typing their names back would jump
        // through the list by type-select (security pass before 0.1, left then; fixed 2026-11-13).
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role) == .success, let r = role as? String,
           Core.notTextRoles.contains(r) { return .notText }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else {
            var s: CFTypeRef?
            // Text that can't be edited but answers: leave it. No text at all from a focused element: the clipboard.
            return AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &s) == .success ? .notText : .unknown
        }
        var s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &s) == .success, let str = s as? String else { return .unknown }
        return .text(str, el)
    }

    /// Electron and Chromium build their Accessibility tree only when asked (AXManualAccessibility), and keep it at a
    /// cost in CPU. Asked for the Retype key, it is turned off again when the app leaves the front, unless something
    /// else had turned it on (security pass before 0.1, left then; done 2026-11-13).
    func askTree(_ pid: pid_t) {
        let el = AXUIElementCreateApplication(pid)
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, "AXManualAccessibility" as CFString, &v) == .success, (v as? Bool) == true { return }
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        treeAsked.insert(pid)
    }

    func dropTrees(except front: pid_t?) {
        for pid in treeAsked where pid != front {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanFalse)
        }
        treeAsked = treeAsked.filter { $0 == front }
    }

    static let notTextRoles: Set<String> = ["AXOutline", "AXList", "AXTable", "AXBrowser", "AXGrid", "AXRow", "AXCell", "AXImage", "AXButton"]

    static func isChromium(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        let fw = url.appendingPathComponent("Contents/Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: fw.path)) ?? []
        return names.contains { $0.hasPrefix("Electron Framework") || $0.contains("Chromium") || $0.hasPrefix("Google Chrome Framework") }
    }

    /// Replaces the selection in place and selects the new text, so the key pressed again finds it.
    static func setSelection(_ el: AXUIElement, to text: String) -> Bool {
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &r) == .success, let rv = r,
              CFGetTypeID(rv) == AXValueGetTypeID() else { return false }
        var range = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range) else { return false }
        var before: CFTypeRef?, after: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &before)
        guard AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success else { return false }
        // Safari's text areas (27.2, 2026-11-17; 0.1.2 too) answer «success» as Chromium does and keep their text: then
        // the text is typed over the selection, still selected as it was.
        AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &after)
        if let b = before as? String, let a = after as? String, a == b { trace("the field kept its text"); return false }
        var new = CFRange(location: range.location, length: (text as NSString).length)
        if let v = AXValueCreate(.cfRange, &new) { AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) }
        return true
    }

    /// ⌘C, the copied text, and the clipboard put back exactly as it was (every item, every type).
    func copySelection(_ done: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        // A password copied from a password manager (marked concealed) is never put through a copy and a restore: the
        // restore would look like a new copy to the manager's timed clearing and to clipboard history apps.
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        if copying || pb.types?.contains(concealed) == true || NSWorkspace.shared.frontmostApplication?.processIdentifier != retypeApp
            || secure() { done(nil); return }
        copying = true
        let saved = (pb.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
        let before = pb.changeCount
        // As a keyboard sends it: ⌘ down, C, ⌘ up. A bare C with the ⌘ flag copied nothing in TextEdit (14).
        func flags(_ down: Bool) {
            let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: down)
            e?.type = .flagsChanged; e?.flags = down ? .maskCommand : []; post(e, nil)
        }
        flags(true)
        press(CGKeyCode(kVK_ANSI_C), .maskCommand, text: "c", via: nil)
        flags(false)
        let start = CACurrentMediaTime()
        // The put-back is marked transient (nspasteboard.org), so clipboard history apps don't record it as a new copy.
        func restore() {
            pb.clearContents()
            pb.writeObjects(saved.map { pairs in
                let i = NSPasteboardItem(); for (t, d) in pairs { i.setData(d, forType: t) }
                i.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")); return i })
        }
        func check() {
            let late = CACurrentMediaTime() - start >= 0.4
            if pb.changeCount == before + 1 {
                let text = pb.string(forType: .string)
                restore()
                trace("copied «\(text?.prefix(40) ?? "-")», clipboard restored")
                copying = false
                done(late ? nil : text)   // a copy that came late is not typed over: the moment has passed
            } else if pb.changeCount == before && CACurrentMediaTime() - start < 2 {
                // Too slow for the retype, but the copy may still land (a busy Electron app): watch on, to put back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: check)
            } else { copying = false; trace("⌘C: no copy of ours to put back"); done(nil) }   // nothing, or someone else's copy
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: check)
    }
}
