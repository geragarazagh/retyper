// core.swift: the word follows the layout.
// A session event tap keeps the keys of the last few words in memory (never on disk, never sent anywhere). At the end of
// a word (Space, Return, Tab) the detector says whether it was typed in the wrong layout; if so the word is retyped and
// the layout switched. When the person switches the layout themself right after a word (any way: ⌥Space, Globe, Caps
// Lock, the menu), the word is retyped in the new layout unless it reads right as it is. Switching back, or ⌘Z, undoes.
//
// Why it is built this way:
// - The tap filters (not listen-only): at a word end it holds the boundary key back, posts Backspaces, the new text and
//   then the boundary key itself, all from inside the callback through CGEventTapPostEvent. Keys typed meanwhile wait
//   behind the callback, so a fix while the next word is already being typed can neither eat nor reorder them.
// - The detector takes about 50 µs a word (p99 150 µs), so it runs in the callback; the tap and every TIS call stay on
//   the main thread (Text Input Sources asserts off it on macOS 14+).
// - Only what the keys mean is kept: key code, Shift, Caps Lock and the layout they were typed in. The text on screen is
//   read back from the layout (UCKeyTranslate), so nothing typed is ever stored as text.
// - Our own events carry a marker in eventSourceUserData and the tap passes them by.
// - Secure Input (a password field): macOS gives the tap no keys at all, and the app types nothing while it is on.

import AppKit
import Carbon.HIToolbox
import ApplicationServices

let ownMarker: Int64 = 0x4C61_796F_7574   // "Layout"

#if TRACE
func trace(_ s: @autoclosure () -> String) { FileHandle.standardError.write("\(String(format: "%.3f", CACurrentMediaTime())) \(s())\n".data(using: .utf8)!) }
#else
@inline(__always) func trace(_ s: @autoclosure () -> String) {}
#endif

/// One key as typed: its layout (index into the detector's layouts), or a word boundary.
struct Item {
    var key: Key
    var layout: Int
    var boundary: Character?   // " ", "\t", "\n"
}

/// The last fix or retype, while nothing else was typed after it: switching back or ⌘Z restores `orig`.
struct Action {
    var start: Int          // index in items where the changed span begins
    var count: Int          // items in the span (the words and the boundaries between them)
    var orig: [Item]        // the span as it was typed
    var origLayout: Int
    var auto: Bool
    var typed: String       // the last word as typed, for the exceptions
    var margin: Float = 0   // log10 odds the fix won by
}

/// After an automatic fix, switching back undoes it only when the fix was a close call. A clear one («ghbdtn» →
/// «привет», odds of 10^20) followed by the language key means the next word is in the other language: the switch
/// only switches. Measured on the test set (2026-11-11): 84 % of right fixes win by more than this, while the
/// collisions that go wrong in life («yt» → «не» 3.95) win by less. ⌘Z undoes any fix.
let undoBySwitchMargin: Float = 4.5

@MainActor final class Core {
    var detector: Detector?
    var models: [String: LangModel] = [:]
    let dataDir: URL
    var items: [Item] = []
    var cur: Int?                   // current layout, an index into detector.layouts
    var lastCyr: Int?
    var runStart = 0                // first item of the current run (since a switch, a fix or Return)
    var pending: Action?
    var settled = false             // after an undo the next switch only switches
    var comboAt: CFTimeInterval?    // a key with ⌘ ⌃ or ⌥ came last: maybe the language key
    var expectID: String?           // the layout we selected ourselves
    var rewriteUntil: CFTimeInterval = 0
    var exceptions = Exceptions()
    let source: CGEventSource? = {
        let s = CGEventSource(stateID: .privateState)
        s?.userData = ownMarker
        return s
    }()
    var enabled = true
    // manual.swift
    var manualKey = ManualKey.current
    var recording: ((ManualKey?) -> Void)?
    var tapMod = 0, tapDownAt: CFTimeInterval = 0, lastTap: (mod: Int, at: CFTimeInterval)?
    var selPending: SelectionChange?

    init(dataDir: URL) { self.dataDir = dataDir }

    // MARK: layouts

    static func enabledLayoutIDs() -> [String] {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        return list.compactMap { s in
            guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return nil }
            return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        }
    }

    static func currentID() -> String? {
        guard let s = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    func index(of id: String?) -> Int? { detector?.layouts.firstIndex { $0.id == id } }

    /// Builds the detector over the enabled layouts. The language models load off the main thread once (~70 ms);
    /// the layout tables come from TIS, which wants the main thread.
    func load(_ done: @escaping () -> Void) {
        let dir = dataDir
        DispatchQueue.global(qos: .userInitiated).async {
            var m: [String: LangModel] = [:]
            for l in ["en", "ru", "uk"] { m[l] = LangModel(lang: l, dir: dir) }
            DispatchQueue.main.async { self.models = m; self.rebuild(); done() }
        }
    }

    func rebuild() {
        guard !models.isEmpty else { return }
        Detector.layoutCache = [:]
        var o = Options(); o.autoCyrillicPair = true
        detector = Detector(layoutIDs: Core.enabledLayoutIDs(), dataDir: dataDir, options: o, shared: models)
        reset("layouts")
        cur = index(of: Core.currentID())
        lastCyr = detector?.layouts.indices.first { detector?.layouts[$0].script == .cyrillic }
        trace("layouts \(detector?.layouts.map { $0.id } ?? []) cur \(String(describing: cur))")
    }

    // MARK: state

    func reset(_ why: String) {
        if !items.isEmpty || pending != nil { trace("reset: \(why)") }
        items = []; runStart = 0; pending = nil; settled = false; comboAt = nil; deferred = nil; selPending = nil
    }

    func screen<C: Collection>(_ its: C) -> String where C.Element == Item {
        guard let d = detector else { return "" }
        return its.map { $0.boundary.map(String.init) ?? d.layouts[$0.layout].read($0.key) }.joined()
    }

    /// Start of the word that ends at `end` (exclusive): the item after the last boundary before it.
    func wordStart(before end: Int) -> Int {
        var i = end
        while i > 0, items[i - 1].boundary == nil { i -= 1 }
        return i
    }

    func trim() {
        let cut = items.count - 80
        guard cut > 0 else { return }
        items.removeFirst(cut); runStart = max(0, runStart - cut)
        if let p = pending { if p.start >= cut { pending!.start -= cut } else { pending = nil } }
    }

    // MARK: posting

    func post(_ e: CGEvent?, _ proxy: CGEventTapProxy?) {
        guard let e else { return }
        e.setIntegerValueField(.eventSourceUserData, value: ownMarker)
        if let proxy { e.tapPostEvent(proxy) } else { e.post(tap: .cgSessionEventTap) }
    }

    func press(_ code: CGKeyCode, _ flags: CGEventFlags = [], text: String? = nil, via proxy: CGEventTapProxy?) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = flags
            if let text { let u = Array(text.utf16); e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u) }
            post(e, proxy)
        }
    }

    /// Types text the way keys would: each character with the key that gives it in `layout` when there is one (some
    /// apps read the key code), and always with the character itself attached (what Cocoa, browsers and Electron read).
    func type(_ text: String, in layout: Int?, _ proxy: CGEventTapProxy?) {
        for c in text {
            if c == "\n" { press(36, via: proxy); continue }
            if c == "\t" { press(48, via: proxy); continue }
            let k = layout.flatMap { detector?.layouts[$0].key(for: c) }
            press(CGKeyCode(k?.code ?? 0), k?.shift == true ? .maskShift : [], text: String(c), via: proxy)
        }
    }

    /// Replaces what is on screen from item `start` to the end with `new`: Backspaces for what differs, then the rest
    /// typed. A common beginning is kept (numbers riding along in a back fix stay where they are).
    func replace(from start: Int, with new: [Item], typeIn layout: Int?, _ proxy: CGEventTapProxy?) {
        let old = Array(screen(items[start...])), now = Array(screen(new))
        var same = 0
        while same < old.count, same < now.count, old[same] == now[same] { same += 1 }
        for _ in same..<old.count { press(51, via: proxy) }
        type(String(now[same...]), in: layout, proxy)
        items.replaceSubrange(start..., with: new)
        trace("retype «\(String(old))» -> «\(String(now))»")
    }

    func select(_ layout: Int) {
        guard let d = detector else { return }
        let id = d.layouts[layout].id
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let src = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource])?.first else { return }
        if Core.currentID() != id { expectID = id; TISSelectInputSource(src) }
        cur = layout
        if d.layouts[layout].script == .cyrillic { lastCyr = layout }
        // Keys already pressed may still carry the old layout's characters: for a moment they are re-read (see keyDown).
        rewriteUntil = CACurrentMediaTime() + 1
    }

    // MARK: the tap

    /// nil swallows the event. Runs in the tap callback on the main thread.
    func handle(_ type: CGEventType, _ event: CGEvent, _ proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if event.getIntegerValueField(.eventSourceUserData) == ownMarker { return pass }
        guard enabled, detector != nil else { return pass }
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            clearTaps()
            if !Core.onMenu(event.location) { reset("click") }
            return pass
        case .keyDown:
            if recordKey(event) { return nil }
            if manualKeyDown(event, proxy) { return nil }
            clearTaps()
            return keyDown(event, proxy) ? nil : pass
        case .flagsChanged:
            flagsChanged(event, proxy)
            return pass
        case .scrollWheel:
            clearTaps()   // ⌥ held for zoom with the wheel is never a tap
            return pass
        default:
            return pass
        }
    }

    /// True when the event was swallowed (and replaced by posted ones).
    private func keyDown(_ event: CGEvent, _ proxy: CGEventTapProxy) -> Bool {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let f = event.flags
        let cmd = f.contains(.maskCommand), ctrl = f.contains(.maskControl), opt = f.contains(.maskAlternate)
        let now = CACurrentMediaTime()
        // The layout may have changed a moment ago and the notification not arrived yet.
        let id = Core.currentID()
        if let c = index(of: id), c != cur { switched(to: c, proxy) }
        else if index(of: id) == nil && cur != nil { cur = nil; reset("not a keyboard layout") }
        guard let cur else { return false }
        // The person let go of the language key's modifier and typed on before our wait noticed: retype first.
        if let w = deferred, !(cmd || ctrl || opt) { deferred = nil; follow(w.new, from: w.old, proxy) }

        if cmd && code == kVK_ANSI_Z && !ctrl && !opt && !f.contains(.maskShift) {
            comboAt = nil
            if undo(proxy) { return true }
            reset("⌘Z"); return false
        }
        if cmd || ctrl || opt {
            // Perhaps the language key (⌥Space, ⌃Space…): nothing is decided until the next key or a layout change.
            if comboAt != nil { reset("shortcut") }
            comboAt = now; return false
        }
        if comboAt != nil { comboAt = nil; reset("shortcut") }
        let key = Key(UInt16(code), f.contains(.maskShift), f.contains(.maskAlphaShift))

        switch code {
        case kVK_Delete:
            if !items.isEmpty { items.removeLast() }
            if items.count < runStart { runStart = items.count }
            pending = nil; settled = false
            return false
        case kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab:
            settled = false
            return boundary(code, event, proxy)
        case 0..<51:
            pending = nil; settled = false
            items.append(Item(key: key, layout: cur, boundary: nil)); trim()
            // Pressed before our layout switch reached the system: give it the character of the layout now selected.
            if now < rewriteUntil, let d = detector {
                let want = d.layouts[cur].read(key)
                var len = 0; var buf = [UniChar](repeating: 0, count: 8)
                event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
                let got = String(utf16CodeUnits: buf, count: len)
                if !want.isEmpty, got != want {
                    let u = Array(want.utf16); event.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                    trace("in flight «\(got)» -> «\(want)»")
                }
            }
            return false
        default:
            reset("key \(code)"); return false
        }
    }

    /// Space, Return or Tab: the auto fix happens here, before the key reaches the app (Return may send a message).
    private func boundary(_ code: Int, _ event: CGEvent, _ proxy: CGEventTapProxy) -> Bool {
        let ch: Character = code == kVK_Space ? " " : (code == kVK_Tab ? "\t" : "\n")
        pending = nil
        defer { if ch == "\n" { runStart = items.count } }
        guard let d = detector, let cur else { return false }
        let ws = wordStart(before: items.count)
        let word = items[ws...]
        func plain() -> Bool { items.append(Item(key: Key(UInt16(code), false), layout: cur, boundary: ch)); trim(); return false }
        guard !word.isEmpty, word.allSatisfy({ $0.layout == cur }) else { return plain() }
        let keys = word.map { $0.key }
        let typed = d.layouts[cur].read(keys)
        if exceptions.contains(typed) { trace("exception «\(typed)»"); return plain() }
        // Words before it in this run, oldest first, and the word on screen just before it.
        var prevRun: [[Key]] = []; var prevScreen: String?
        var e = ws
        while e > 0, items[e - 1].boundary != nil { e -= 1 }
        if e > 0 { prevScreen = screen(items[wordStart(before: e)..<e]) }
        var starts: [Int] = []
        var i = e
        while i > runStart {
            let s = max(runStart, wordStart(before: i))
            if items[s..<i].allSatisfy({ $0.layout == cur && $0.boundary == nil }) { prevRun.insert(items[s..<i].map { $0.key }, at: 0); starts.insert(s, at: 0) } else { break }
            i = s
            while i > runStart, items[i - 1].boundary != nil { i -= 1 }
        }
        let ctx = Detector.Context(prevScreen: prevScreen, prevRun: prevRun, lastCyrillic: lastCyr)
        var v = d.decide(keys, typed: cur, ctx)
        // Latin ↔ Cyrillic first; Russian ↔ Ukrainian only when that finds nothing (as measured, «Detector» in the card).
        if !isWrong(v) { v = d.decide(keys, typed: cur, ctx, cyrillicPair: true) }
        trace("word «\(typed)» prev «\(prevScreen ?? "-")» run \(prevRun.count) -> \(v)")
        guard case let .wrong(target, back) = v else { return plain() }
        let start = back > 0 && back <= starts.count ? starts[starts.count - back] : ws
        let orig = Array(items[start...])
        let fixed = orig.map { var x = $0; if x.boundary == nil { x.layout = target }; return x }
        select(target)
        replace(from: start, with: fixed, typeIn: target, proxy)
        // The boundary key itself, after the fix: Return may send a message, Tab may leave the field.
        let copy = event.copy()
        copy?.setIntegerValueField(.eventSourceUserData, value: ownMarker)
        copy?.tapPostEvent(proxy)
        items.append(Item(key: Key(UInt16(code), false), layout: target, boundary: ch))
        // Undo by switching back or ⌘Z is only offered after a Space: after Return or Tab the caret may be elsewhere.
        if ch == " " {
            let rs = d.readings(keys, asTyped: cur)
            pending = Action(start: start, count: orig.count, orig: orig, origLayout: cur, auto: true, typed: typed, margin: rs[target].score - rs[cur].score)
        }
        runStart = items.count
        trim()
        return true
    }

    private func isWrong(_ v: Verdict) -> Bool { if case .wrong = v { return true }; return false }

    /// ⌘Z right after an automatic fix: the word goes back as typed, with its layout, and is remembered.
    private func undo(_ proxy: CGEventTapProxy) -> Bool {
        guard let p = pending, p.auto, p.start + p.count <= items.count else { return false }
        let tail = Array(items[(p.start + p.count)...])
        let back = tail.map { var x = $0; x.layout = p.origLayout; return x }
        select(p.origLayout)
        replace(from: p.start, with: p.orig + back, typeIn: p.origLayout, proxy)
        exceptions.add(p.typed)
        pending = nil; settled = true; runStart = items.count
        trace("⌘Z undo, remembered «\(p.typed)»")
        return true
    }

    // MARK: switching

    /// The layout changed: by us (ignored), or by the person, any way they like. Called from the notification or, when
    /// a key comes first, from the tap (then `proxy` is set).
    func switched(to new: Int, _ proxy: CGEventTapProxy?) {
        guard let d = detector else { return }
        let id = d.layouts[new].id
        let old = cur
        cur = new
        if d.layouts[new].script == .cyrillic { lastCyr = new }
        if expectID == id { expectID = nil; return }
        expectID = nil
        if IsSecureEventInputEnabled() { reset("secure input"); return }
        if let c = comboAt, CACurrentMediaTime() - c > 0.6 { reset("shortcut") }
        comboAt = nil
        trace("switch \(old.map { d.layouts[$0].id } ?? "-") -> \(id)")
        // While ⌥ (or ⌘, ⌃) of the language key is still held, macOS's switching is not over: keys posted then made it
        // switch back (seen on 26, 8 ms later). So the retype waits for the modifiers to be let go, or for the next key.
        if proxy == nil && Core.modifiersHeld() { deferred = (new, old, CACurrentMediaTime()); waitForRelease(); return }
        follow(new, from: old, proxy)
    }

    var deferred: (new: Int, old: Int?, at: CFTimeInterval)?

    static func modifiersHeld() -> Bool {
        !CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty
    }

    private func waitForRelease() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
            guard let self, let w = self.deferred else { return }
            if Core.modifiersHeld() && CACurrentMediaTime() - w.at < 3 { self.waitForRelease(); return }
            self.deferred = nil
            self.follow(w.new, from: w.old, nil)
        }
    }

    /// What a switch by the person does to the text: the span of our last change follows the layout (back where it was
    /// typed = undo), or the last word is retyped, or a selection converted.
    func follow(_ new: Int, from old: Int?, _ proxy: CGEventTapProxy?) {
        guard let d = detector, cur == new else { return }
        defer { runStart = items.count }
        if settled { settled = false; trace("settled: only switch"); return }

        // After our fix or retype: the span follows the layout; back to where it was typed = undo.
        if let p = pending, p.start + p.count <= items.count {
            let tail = Array(items[(p.start + p.count)...])
            if new == p.origLayout && p.auto && p.margin > undoBySwitchMargin {
                trace("clear fix (\(p.margin)): only switch"); pending = nil; return
            }
            if new == p.origLayout {
                replace(from: p.start, with: p.orig + tail, typeIn: new, proxy)
                if p.auto { exceptions.add(p.typed); trace("undo, remembered «\(p.typed)»") }
                pending = nil; settled = true
            } else {
                let span = p.orig.map { var x = $0; if x.boundary == nil { x.layout = new }; return x }
                replace(from: p.start, with: span + tail, typeIn: new, proxy)
            }
            return
        }

        // The last word: the caret touches it, or the word and one space after it.
        var end = items.count
        var touching = true
        if end > 0, items[end - 1].boundary == " " { end -= 1; touching = false }
        if end > 0, items[end - 1].boundary == nil {
            let ws = wordStart(before: end)
            let word = Array(items[ws..<end])
            let from = word[0].layout
            guard word.allSatisfy({ $0.layout == from }), from != new else { return }
            let keys = word.map { $0.key }
            // A key that gives the same character in both layouts ends the word for good («PDF-», a digit).
            let last = keys.last!
            if d.layouts[from].read(last) == d.layouts[new].read(last) { trace("same last key: only switch"); return }
            guard d.manualRetype(keys, typed: from, to: new, touching: touching) else { trace("gate: «\(d.layouts[from].read(keys))» stays"); return }
            let tail = Array(items[end...])
            let span = word.map { var x = $0; x.layout = new; return x }
            replace(from: ws, with: span + tail, typeIn: new, proxy)
            pending = Action(start: ws, count: word.count, orig: word, origLayout: from, auto: false, typed: d.layouts[from].read(keys))
            return
        }
        if items.isEmpty { convertSelection(to: new, from: old, proxy) }
    }

    // MARK: selection

    /// A selection in an editable text when the layout is switched: if the selected text reads much better in another
    /// layout (it was typed in the wrong one), it is retyped as the keys that made it read there, and that layout is
    /// selected; the same judgement as the automatic fix, over the whole selection. Text that reads right is left alone,
    /// so selecting a word and switching to type over it in the other language changes nothing.
    func convertSelection(to new: Int, from old: Int?, _ proxy: CGEventTapProxy?) {
        guard AXIsProcessTrusted(), case let .text(text, el) = Core.selection(), !text.isEmpty,
              let p = plan(text, forced: false, preferred: new) else { return }
        replaceSelection(text, with: p.out, target: p.target, element: el, src: p.src)
    }

    static func script(_ c: Character) -> Script {
        guard let u = c.unicodeScalars.first else { return .other }
        if (0x0400...0x04FF).contains(u.value) { return .cyrillic }
        return u.value < 0x250 ? .latin : .other
    }

    /// A click on the menu bar or an open menu (the input menu among them) moves no caret.
    static func onMenu(_ p: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {
            guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b), r.contains(p) else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            if (w[kCGWindowAlpha as String] as? Double ?? 1) == 0 { continue }
            return layer >= Int(CGWindowLevelForKey(.mainMenuWindow))
        }
        return false
    }
}

// MARK: exceptions

/// Words an undo has taken back: never fixed automatically again. One plain file, a word per line, as typed
/// (lower case); the window's Exceptions row edits it.
struct Exceptions {
    static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "SourceKey")
        return dir.appendingPathComponent("Exceptions.txt")
    }
    private(set) var words: Set<String> = []
    private var stamp: Date?

    init() { reload() }

    static func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }

    mutating func reload() {
        let attr = try? FileManager.default.attributesOfItem(atPath: Exceptions.file.path)
        stamp = attr?[.modificationDate] as? Date
        let text = (try? String(contentsOf: Exceptions.file, encoding: .utf8)) ?? ""
        words = Set(text.split(separator: "\n").map { Exceptions.norm(String($0)) }.filter { !$0.isEmpty })
    }

    mutating func contains(_ typed: String) -> Bool {
        let attr = try? FileManager.default.attributesOfItem(atPath: Exceptions.file.path)
        if attr?[.modificationDate] as? Date != stamp { reload() }   // edited in the window or by hand
        return words.contains(Exceptions.norm(typed))
    }

    mutating func add(_ typed: String) { var w = list; w.append(typed); save(w) }

    var list: [String] {
        ((try? String(contentsOf: Exceptions.file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    mutating func save(_ list: [String]) {
        var seen = Set<String>()
        let clean = list.map(Exceptions.norm).filter { !$0.isEmpty && seen.insert($0).inserted }
        let fm = FileManager.default
        if clean.isEmpty { try? fm.removeItem(at: Exceptions.file); try? fm.removeItem(at: Exceptions.file.deletingLastPathComponent()) }
        else {
            try? fm.createDirectory(at: Exceptions.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (clean.joined(separator: "\n") + "\n").write(to: Exceptions.file, atomically: true, encoding: .utf8)
        }
        reload()
    }
}
