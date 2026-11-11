// manual.swift: the Retype key, a command of its own besides the language key, for the cases the detector judges
// wrong or a stretch found later. It does what it is told, with no judgement of the detector:
// - right after our fix or retype (nothing typed since): takes it back, as ⌘Z does;
// - a selection: retyped in the other script (Latin → Cyrillic, Cyrillic → Latin), any length; pressed again, back;
// - else the last word (the caret touches it, or the word and one space): retyped in the other script; again, back.
// The layout follows the text. The key is a shortcut with ⌘, ⌥ or ⌃, or one modifier tapped twice. A tap counts only
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

/// A selection the Retype key changed, while nothing else happened: pressed again, it goes back.
struct SelectionChange {
    var orig: String
    var now: String
    var origLayout: Int?
    var element: AXUIElement?   // replaced in place through Accessibility (and selected again), else typed over
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
        guard let d = detector, !IsSecureEventInputEnabled() else { return }
        retypeApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // 1. Our last change, nothing typed since: back.
        if let p = pending, p.start + p.count <= items.count {
            let tail = Array(items[(p.start + p.count)...]).map { x -> Item in var y = x; if y.boundary == nil { y.layout = p.origLayout }; return y }
            select(p.origLayout)
            replace(from: p.start, with: p.orig + tail, typeIn: p.origLayout, proxy)
            if p.auto { exceptions.add(p.typed) }
            pending = nil; settled = true; runStart = items.count
            trace("retype key: back")
            return
        }
        if let s = selPending { selPending = nil; DispatchQueue.main.async { self.revertSelection(s) }; return }
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
            if let p = plan(text, forced: true, preferred: cur) { replaceSelection(text, with: p.out, target: p.target, element: el, src: p.src) }
            return
        }
        // Electron and Chromium build their Accessibility tree only when asked: ask, look again a moment later.
        if case .unknown = sel, !asked, AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication, Core.isChromium(app) {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanTrue)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.retypeAfter(asked: true) }
            return
        }
        // VS Code's editor (Monaco) shows Accessibility an empty selection unless its screen reader mode is on: in
        // Chromium apps an empty answer is not trusted, the clipboard is asked (measured 2026-11-11 on 14).
        if case .text("", _) = sel, let app = NSWorkspace.shared.frontmostApplication, Core.isChromium(app), items.isEmpty {
            copySelection { [weak self] text in
                // Monaco copies the whole line, ending in a line break, when nothing is selected: not a selection.
                guard let self, let text, !text.isEmpty, !text.hasSuffix("\n"), let p = self.plan(text, forced: true, preferred: self.cur) else { return }
                self.replaceSelection(text, with: p.out, target: p.target, element: nil, src: p.src)
            }
            return
        }
        guard let d = detector else { return }
        // 3. The last word: forced into the other script.
        var end = items.count
        if end > 0, items[end - 1].boundary == " " { end -= 1 }
        if end > 0, items[end - 1].boundary == nil {
            let ws = wordStart(before: end)
            let word = Array(items[ws..<end])
            let from = word[0].layout
            if word.allSatisfy({ $0.layout == from }), let to = otherScript(word.map { $0.key }, from: from) {
                let tail = Array(items[end...])
                select(to)
                replace(from: ws, with: word.map { var x = $0; x.layout = to; return x } + tail, typeIn: to, nil)
                pending = Action(start: ws, count: word.count, orig: word, origLayout: from, auto: false, typed: d.layouts[from].read(word.map { $0.key }))
                settled = false; runStart = items.count
                trace("retype key: word")
                return
            }
        }
        // 4. A selection Accessibility can't see (Electron before its tree is on, apps without one).
        retypeSelection()
    }

    /// The best layout of the other script for these keys (the Cyrillic used last when two are close).
    func otherScript(_ keys: [Key], from: Int) -> Int? {
        guard let d = detector else { return nil }
        let fromScript = d.layouts[from].script
        let cands = d.layouts.indices.filter { d.layouts[$0].script != fromScript && d.layouts[$0].script != .other && d.layouts[$0].lang != nil }
        guard cands.count > 1 else { return cands.first }
        let rs = d.readings(keys)
        return cands.max { a, b in abs(rs[a].score - rs[b].score) < 0.5 ? (b == lastCyr) : rs[a].score < rs[b].score }
    }

    /// What a text becomes: the keys that typed it (in the layout of its main script that gives all its letters) read
    /// in another layout. forced: always the other script; else only a layout it reads much better in (⌥Space's gate).
    func plan(_ text: String, forced: Bool, preferred: Int?) -> (out: String, target: Int, src: Int)? {
        guard let d = detector else { return nil }
        var latin = 0, cyr = 0
        for c in text where c.isLetter { switch Core.script(c) { case .latin: latin += 1; case .cyrillic: cyr += 1; default: break } }
        guard latin + cyr > 0 else { return nil }
        let fromScript: Script = latin >= cyr ? .latin : .cyrillic
        let firstPick = fromScript == .cyrillic ? lastCyr : preferred
        let candidates = d.layouts.indices.filter { d.layouts[$0].script == fromScript }.sorted { a, _ in a == firstPick }
        func gives(_ l: Int) -> Bool { text.allSatisfy { c in !c.isLetter || Core.script(c) != fromScript || d.layouts[l].key(for: c) != nil } }
        guard let src = candidates.first(where: gives) else { return nil }
        var total = [Int: Float](), typed: Float = 0, words = 0
        for w in text.split(whereSeparator: { $0.isWhitespace }) where w.contains(where: { $0.isLetter }) {
            var k: [Key] = []
            for c in w { guard let x = d.layouts[src].key(for: c) else { k = []; break }; k.append(x) }
            guard !k.isEmpty else { continue }
            let rs = d.readings(k, asTyped: src)
            typed += rs[src].score; words += 1
            for r in rs where r.layout != src && d.layouts[r.layout].lang != nil { total[r.layout, default: 0] += r.score }
        }
        if forced { total = total.filter { d.layouts[$0.key].script != fromScript } }
        let tie = forced ? lastCyr : preferred
        guard let best = total.max(by: { a, b in abs(a.value - b.value) < 0.5 ? (b.key == lastCyr || b.key == tie) : a.value < b.value })
                ?? (forced ? d.layouts.indices.first(where: { d.layouts[$0].script != fromScript && d.layouts[$0].lang != nil }).map { ($0, Float(0)) } : nil)
        else { return nil }
        if !forced { guard words > 0, best.value - typed > 1 else { return nil } }
        var out = ""
        for c in text { if let k = d.layouts[src].key(for: c) { let r = d.layouts[best.key].read(k); out += r.isEmpty ? String(c) : r } else { out.append(c) } }
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
            guard !text.isEmpty, let p = plan(text, forced: true, preferred: cur) else { trace("retype key: nothing selected"); return }
            replaceSelection(text, with: p.out, target: p.target, element: el, src: p.src)
        case .notText:
            trace("retype key: focus is not editable text")
        case .unknown:
            var testClipboard = false
            #if TRACE
            testClipboard = ProcessInfo.processInfo.environment["SK_CLIPBOARD"] != nil
            #endif
            if !asked, !testClipboard, let app = NSWorkspace.shared.frontmostApplication, Core.isChromium(app) {
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanTrue)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.retypeSelection(asked: true) }
                return
            }
            copySelection { [weak self] text in
                guard let self, let text, !text.isEmpty, let p = self.plan(text, forced: true, preferred: self.cur) else { return }
                self.replaceSelection(text, with: p.out, target: p.target, element: nil, src: p.src)
            }
        }
    }

    func replaceSelection(_ text: String, with out: String, target: Int, element: AXUIElement?, src: Int) {
        trace("selection «\(text.prefix(40))» -> «\(out.prefix(40))»")
        // Chromium answers «success» to setting the selected text and changes nothing (VS Code on 14, 2026-11-11):
        // there the text is typed over the selection, as a person would.
        let chromium = NSWorkspace.shared.frontmostApplication.map(Core.isChromium) ?? false
        if !chromium, let el = element, Core.setSelection(el, to: out) {
            select(target); reset("selection retyped")
            selPending = SelectionChange(orig: text, now: out, origLayout: src, element: el); return
        }
        // Typed text goes wherever the focus is now, and a line break or tab can only be typed as Return or Tab, which
        // send a chat message or move the focus. So nothing is typed if the front app changed since the key was pressed
        // (the selection is read up to half a second later), if a password field took the focus, or if the selection
        // holds more than one line (security pass before 0.1, 2026-11-11).
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == retypeApp, !IsSecureEventInputEnabled(),
              !out.contains(where: { $0 == "\n" || $0 == "\t" || $0 == "\r" }) else { trace("selection not typed"); return }
        select(target)
        reset("selection retyped")
        type(out, in: target, nil)
        selPending = SelectionChange(orig: text, now: out, origLayout: src, element: nil)
    }

    func revertSelection(_ s: SelectionChange) {
        if let l = s.origLayout { select(l) }
        if let el = s.element, Core.setSelection(el, to: s.orig) { selPending = SelectionChange(orig: s.now, now: s.orig, origLayout: nil, element: el); return }
        // Typing back: the same guards as typing it (replaceSelection). An app switch since clears selPending already.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == retypeApp, !IsSecureEventInputEnabled(),
              !s.orig.contains(where: { $0 == "\n" || $0 == "\t" || $0 == "\r" }) else { trace("selection not typed back"); return }
        // Set through Accessibility, the new text is still selected: one Backspace takes it. Typed, a Backspace a letter.
        for _ in 0..<(s.element == nil ? s.now.count : 1) { press(51, via: nil) }
        type(s.orig, in: s.origLayout, nil)
        trace("selection back")
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
        guard AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success else { return false }
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
            || IsSecureEventInputEnabled() { done(nil); return }
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
