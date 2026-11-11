// detect.swift: tells whether a word was typed in the wrong keyboard layout.
// Input: the word's keys (key code + Shift) and the installed layouts. Each layout's reading of
// the keys comes from macOS itself (UCKeyTranslate), so no layout tables are bundled and any
// installed layout works. Each reading is scored by its language's model (word list + character
// n-grams, data/<lang>.words and .ngram; or macOS's spell checker; or both), and the scores are
// compared as log-odds with a prior for "the layout is wrong here".
// No dependencies beyond Carbon/AppKit; nothing is written, logged or sent.
import AppKit
import Carbon
import Foundation

// Caps Lock is a state of its own: it gives capitals on letters but leaves «[ ; ' , .» as they are in ABC, while in
// Russian the same keys are the letters х ж э б ю and do become capitals. So it is passed apart from Shift.
public struct Key: Hashable { public var code: UInt16; public var shift: Bool; public var caps: Bool
  public init(_ code: UInt16, _ shift: Bool, _ caps: Bool = false) { self.code = code; self.shift = shift; self.caps = caps } }

public enum Script { case latin, cyrillic, other }

public final class Layout {
  public let id: String; public let lang: String?; public let script: Script
  private var table: [Int: String] = [:]
  init?(id: String) {
    self.id = id
    let all = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
    func prop(_ s: TISInputSource, _ k: CFString) -> AnyObject? {
      guard let v = TISGetInputSourceProperty(s, k) else { return nil }
      return Unmanaged<AnyObject>.fromOpaque(v).takeUnretainedValue() }
    guard let src = all.first(where: { (prop($0, kTISPropertyInputSourceID) as? String) == id }),
          let data = prop(src, kTISPropertyUnicodeKeyLayoutData) as? Data else { return nil }
    let langs = (prop(src, kTISPropertyInputSourceLanguages) as? [String]) ?? []
    let first = langs.first.map { String($0.prefix(2)) }
    lang = ["en", "ru", "uk"].contains(first ?? "") ? first : nil
    script = lang == "en" ? .latin : (lang == nil ? .other : .cyrillic)
    let kbd = UInt32(LMGetKbdType())
    for code in 0..<51 { for m in 0..<4 {
      var dead: UInt32 = 0; var len = 0; var chars = [UniChar](repeating: 0, count: 4)
      let mods = UInt32((m & 1 != 0 ? shiftKey : 0) | (m & 2 != 0 ? alphaLock : 0)) >> 8
      data.withUnsafeBytes { raw in
        let p = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
        _ = UCKeyTranslate(p, UInt16(code), UInt16(kUCKeyActionDown), mods, kbd,
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars) }
      table[code * 4 + m] = String(utf16CodeUnits: chars, count: len) } }
  }
  static func index(_ k: Key) -> Int { Int(k.code) * 4 + (k.shift ? 1 : 0) + (k.caps ? 2 : 0) }
  public func read(_ keys: [Key]) -> String { keys.map { table[Layout.index($0)] ?? "" }.joined() }
  public func read(_ k: Key) -> String { table[Layout.index(k)] ?? "" }
  /// The key that gives this character here (no Caps Lock), for turning text back into keys.
  public func key(for c: Character) -> Key? {
    if reverse.isEmpty { for (i, s) in table where i & 2 == 0 && s.count == 1 {
      let k = Key(UInt16(i / 4), i & 1 != 0); if let old = reverse[s], !old.shift || k.shift { continue }; reverse[s] = k } }
    return reverse[String(c)]
  }
  private var reverse: [String: Key] = [:]
}

/// A word list in one byte buffer, sorted by UTF-8 bytes: lookups by binary search, about the size
/// of the file in memory (a [String: Float] of 100 000 words took ~12 MB and 100 ms to build).
final class WordTable {
  private var buf: [UInt8] = []; private var start: [UInt32] = []; private var len: [UInt8] = []; private var lp: [Float16] = []
  var count: Int { start.count }
  init(_ data: Data) {
    buf.reserveCapacity(data.count)
    var i = 0; let b = [UInt8](data); var cur = 0
    while i < b.count {
      var j = i; while j < b.count && b[j] != 9 { j += 1 }        // tab
      var k = j; while k < b.count && b[k] != 10 { k += 1 }       // newline
      if j < k {
        start.append(UInt32(cur)); len.append(UInt8(min(j - i, 255))); buf.append(contentsOf: b[i..<j]); cur += j - i
        lp.append(Float16(Float(String(decoding: b[(j + 1)..<k], as: UTF8.self)) ?? -9))
      }
      i = k + 1
    }
  }
  func get(_ s: String) -> Float? {
    var u = Array(s.utf8); let n = u.count
    var lo = 0, hi = start.count - 1
    while lo <= hi {
      let mid = (lo + hi) / 2; let st = Int(start[mid]), ln = Int(len[mid])
      var c = 0
      u.withUnsafeMutableBufferPointer { up in buf.withUnsafeBufferPointer { bp in
        let m = min(n, ln); var x = 0
        while x < m { let a = bp[st + x], q = up[x]; if a != q { c = a < q ? -1 : 1; break }; x += 1 }
        if c == 0 { c = ln < n ? -1 : (ln > n ? 1 : 0) } } }
      if c == 0 { return Float(lp[mid]) }
      if c < 0 { lo = mid + 1 } else { hi = mid - 1 }
    }
    return nil
  }
}

/// One language's model: word frequencies and a character n-gram model (log10 everywhere).
public final class LangModel {
  let lang: String; var words = WordTable(Data()); var ng: [String: Float] = [:]; var gamma: [String: Float] = [:]
  var order = 4; let letters: Set<Character>; let floorLP: Float
  public init(lang: String, dir: URL, maxWords: Int = .max) {
    self.lang = lang
    let alpha: [String: String] = ["en": "abcdefghijklmnopqrstuvwxyz", "ru": "абвгдежзийклмнопрстуфхцчшщъыьэюяё",
                                   "uk": "абвгґдеєжзиіїйклмнопрстуфхцчшщьюя"]
    letters = Set(alpha[lang]!); floorLP = -log10(Float(alpha[lang]!.count + 2))
    // The app carries the data lzfse-compressed (name.lzfse), the bench reads the plain files.
    func load(_ name: String) -> Data? {
      if let z = try? Data(contentsOf: dir.appendingPathComponent(name + ".lzfse")) { return try? (z as NSData).decompressed(using: .lzfse) as Data }
      return try? Data(contentsOf: dir.appendingPathComponent(name)) }
    if let d = load("\(lang).words") { words = WordTable(d) }
    if let d = load("\(lang).ngram"), let s = String(data: d, encoding: .utf8) {
      for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
        let p = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard p.count == 3 else { continue }
        if p[1].isEmpty { gamma[String(p[0])] = Float(p[2])! } else { ng[String(p[0]) + "\t" + String(p[1])] = Float(p[2])!
          order = max(order, p[0].count + 1) } } }
  }
  func charLP(_ h: Substring, _ c: Character) -> Float {
    if let v = ng[String(h) + "\t" + String(c)] { return v }
    if h.isEmpty { return floorLP }
    return (gamma[String(h)] ?? 0) + charLP(h.dropFirst(), c)
  }
  func charModel(_ w: String) -> Float {
    let s = String(repeating: "^", count: order - 1) + w + "$"; let a = Array(s); var lp: Float = 0
    for i in (order - 1)..<a.count { lp += charLP(Substring(String(a[(i - order + 1)..<i])), a[i]) }
    return lp
  }
  func isApostrophe(_ c: Character) -> Bool { lang == "uk" ? (c == "ʼ" || c == "'") : c == "'" }
  func key(_ w: String) -> String {
    var k = w.lowercased(); if lang == "ru" { k = k.replacingOccurrences(of: "ё", with: "е") }
    if lang == "uk" { k = k.replacingOccurrences(of: "'", with: "ʼ") }
    return k
  }
}

public struct Options {
  public var lambda: Float = 0.9          // weight of the word list against the character model
  public var useWords = true, useNgram = true, useSpell = false
  public var spellOnlyScore = false       // candidate 2: macOS spell checker alone
  public var spellWordLP: Float = -6.0    // a spell-valid word missing from the list counts as this frequent
  public var priorStart: Float = -1.0     // log10 P(layout wrong) for a word with no same-script word before it
  public var priorRun: Float = -2.5       // ... right after a word that was typed in the same layout
  public var fixThreshold: Float = 1.0    // auto fix when log10 odds (wrong:right) exceed this
  public var minLetters = 2               // auto never fixes cores shorter than this
  public var shortLen = 2, shortExtra: Float = 1.0 // extra odds needed for cores of <= shortLen letters
  public var gateSpace: Float = 0.0       // manual switch after "word ": skip retype if typed wins by this
  public var gateTouch: Float = 3.0       // manual switch right after the word (caret touches it)
  public var altOOV: Float = 1.0          // extra odds needed when the other reading is not a known word
  public var plausFloor: Float = -1.8     // an unknown word is taken as a word only if its letters look this word-like
  public var shortByContext = false
  public var capsExtra: Float = 2.0       // extra odds for short ALL CAPS (acronyms)
  public var capsShort = 4                // ALL CAPS cores up to this length count as short (acronyms)
  public var cyrTie: Float = 0.5          // ru vs uk readings closer than this: the Cyrillic used last wins
  public var autoCyrillicPair = false     // auto ru <-> uk (on only where measured right in 80-90 % of words or more)
  public var backMax = 3
  public var backFix = true               // a confirmed mistake also fixes the word before it (same run)
  public var tailPunct: Float = -1.0, otherPunct: Float = -3.0, innerJunk: Float = -6.0, cyrCamel: Float = -3.0
  public init() {}
}

public struct Reading { public let layout: Int; public let text: String; public let score: Float; public let isWord: Bool; public let clean: Bool
  public let shape: Float   // mean character-model log10 per letter: how word-like the letters look
  public let lang: String }

public enum Verdict: Equatable { case wrong(target: Int, back: Int), right, unsure }

public final class Detector {
  public let layouts: [Layout]; var models: [String: LangModel] = [:]; public var opt: Options
  lazy var spell = NSSpellChecker.shared
  // Only the bench's spell checker candidates touch it: the first call starts macOS's spelling service.
  lazy var spellLang: [String: String] = {
    let avail = Set(NSSpellChecker.shared.availableLanguages)
    var m: [String: String] = [:]; for l in ["en", "ru", "uk"] where avail.contains(l) { m[l] = l }
    spell.automaticallyIdentifiesLanguages = false
    return m }()
  var spellCache: [String: Bool] = [:]
  static var layoutCache: [String: Layout] = [:]
  // log10 price of punctuation right after / before a word (rough shares in running text):
  // a comma or full stop follows ~1 word in 20, a semicolon ~1 in 300.
  static let tailPrice: [Character: Float] = [".": -1.3, ",": -1.2, "!": -2.0, "?": -2.0, ":": -2.0, ";": -2.5, ")": -2.0,
    "\"": -2.0, "'": -2.5, "»": -2.0, "…": -2.5]
  static let leadPrice: [Character: Float] = ["\"": -2.0, "(": -2.0, "«": -2.0, "'": -2.5]
  public init(layoutIDs: [String], dataDir: URL, options: Options = Options(), maxWords: Int = .max, shared: [String: LangModel]? = nil) {
    layouts = layoutIDs.compactMap { id in
      if let l = Detector.layoutCache[id] { return l }
      let l = Layout(id: id); Detector.layoutCache[id] = l; return l }
    opt = options
    for l in Set(layouts.compactMap { $0.lang }) { models[l] = shared?[l] ?? LangModel(lang: l, dir: dataDir, maxWords: maxWords) }
  }

  func spellValid(_ w: String, _ lang: String) -> Bool? {
    guard let sl = spellLang[lang] else { return nil }
    let k = lang + "\t" + w; if let v = spellCache[k] { return v }
    let r = spell.checkSpelling(of: w, startingAt: 0, language: sl, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
    let v = r.location == NSNotFound; spellCache[k] = v; return v
  }

  /// Score of one reading in its layout's language: log10 P(text | language), with punctuation
  /// around the letters priced, and readings that cannot be a word pushed far down.
  func score(_ text: String, _ m: LangModel) -> (Float, Bool, Bool, Float) {
    let a = Array(text)
    func isL(_ c: Character) -> Bool { m.letters.contains(Character(c.lowercased())) }
    guard let first = a.firstIndex(where: isL), let last = a.lastIndex(where: isL) else { return (opt.innerJunk * Float(max(a.count, 1)), false, false, -9) }
    var s: Float = 0; var odd = false
    for c in a[..<first] { if let p = Detector.leadPrice[c] { s += p } else { s += opt.otherPunct; odd = true } }
    for c in a[(last + 1)...] { if let p = Detector.tailPrice[c] { s += p } else { s += opt.otherPunct; odd = true } }
    let core = String(a[first...last])
    // inside the letters only an apostrophe or a hyphen between letters is allowed
    var parts: [String] = []; var cur = ""; var junk = 0
    for (i, c) in core.enumerated() {
      if isL(c) { cur.append(c); continue }
      let ca = Array(core)
      if (c == "-" || m.isApostrophe(c)) && i > 0 && i < ca.count - 1 && isL(ca[i - 1]) && isL(ca[i + 1]) {
        if c == "-" { parts.append(cur); cur = "" } else { cur.append(m.lang == "uk" ? "ʼ" : "'") }
      } else { junk += 1; parts.append(cur); cur = "" }
    }
    parts.append(cur)
    if junk > 0 { s += opt.innerJunk * Float(junk) }
    // case: inner capitals are normal in Latin brand names (iPhone, GitHub), never in Cyrillic words
    let up = core.filter { $0.isUppercase }.count
    if m.lang != "en", up > 0, up < core.filter(isL).count, core.dropFirst().contains(where: { $0.isUppercase }) { s += opt.cyrCamel }
    var isWord = junk == 0; var charSum: Float = 0; var charN = 0
    for p in parts where !p.isEmpty {
      let k = m.key(p)
      var wlp: Float? = opt.useWords ? m.words.get(k) : nil
      if opt.spellOnlyScore {
        let v = spellValid(k, m.lang) ?? false; if !v { isWord = false }
        s += v ? 0 : -3; continue }
      if wlp == nil, opt.useSpell, k.count >= 3, spellValid(k, m.lang) == true { wlp = opt.spellWordLP }
      if wlp == nil { isWord = false }
      let clp: Float = opt.useNgram ? m.charModel(k) : -2.0 * Float(k.count) - 4
      charSum += clp; charN += k.count + 1
      if let w = wlp { let x = opt.lambda * pow(10, w), y = (1 - opt.lambda) * pow(10, clp); s += log10(x + y) }
      else { s += log10(1 - opt.lambda) + clp }
    }
    return (s, isWord, junk == 0 && !odd, charN > 0 ? charSum / Float(charN) : -9)
  }

  /// Each layout's reading of the keys, scored by its own language. With `asTyped`, the reading of
  /// that layout is scored by every language of its script and the best kept: Russian typed while
  /// the Ukrainian layout is on is still right where the two layouts agree.
  public func readings(_ keys: [Key], asTyped: Int? = nil) -> [Reading] {
    layouts.enumerated().map { (i, l) in
      let t = l.read(keys)
      guard let lang = l.lang, let m = models[lang] else { return Reading(layout: i, text: t, score: -99, isWord: false, clean: false, shape: -9, lang: "") }
      var (s, w, c, sh) = score(t, m); var lg = lang
      if i == asTyped {
        for (ol, om) in models where ol != lang && Detector.scriptOfLang(ol) == l.script {
          let (s2, w2, c2, sh2) = score(t, om); if s2 > s { (s, w, c, sh, lg) = (s2, w2, c2, sh2, ol) } } }
      return Reading(layout: i, text: t, score: s, isWord: w, clean: c, shape: sh, lang: lg) }
  }
  static func scriptOfLang(_ l: String) -> Script { l == "en" ? .latin : .cyrillic }
  static func showsCyrillic(_ s: String?) -> Bool { s?.contains(where: { "іїєґІЇЄҐыэъёЫЭЪЁ".contains($0) }) ?? false }

  /// Shapes of code, paths and addresses, judged on the text as typed.
  /// .hard: never touched (URL scheme, e-mail, flags, identifiers, letters mixed with digits).
  /// .soft: looks like a path or file name, but the same key is a letter in a Cyrillic layout
  ///        (ю = ".", ё = "\\" or "`", б = ","): touched only when the other reading is a known word.
  enum Shape { case none, soft, hard }
  func structural(_ t: String, _ l: Layout) -> Shape {
    if t.contains("://") || t.hasPrefix("$") || t.hasPrefix("#") { return .hard }
    // "@" with letters after it is an address or a handle; at the very end it is the Russian «"» key
    if let at = t.firstIndex(of: "@"), at != t.startIndex, t[t.index(after: at)...].contains(where: { $0.isLetter }) { return .hard }
    if t.hasPrefix("-") && t.count > 1 { return .hard }
    // a flag after a bracket or quote, as in usage lines: "[-o", "(-v"
    let ta = Array(t)
    for i in ta.indices.dropFirst() where ta[i] == "-" && !ta[i - 1].isLetter && !ta[i - 1].isNumber { return .hard }
    let hasDigit = t.contains(where: { $0.isNumber }), hasLetter = t.contains(where: { $0.isLetter })
    if hasDigit && hasLetter { return .hard }
    guard l.script == .latin else { return .none }
    if t.contains("_") || t.contains("=") { return .hard }
    let lettersOnly = t.filter { $0.isLetter }
    // camelCase / mixed case after the first letter (but not ALL CAPS): code or a brand typed right
    if lettersOnly.count >= 2, lettersOnly.dropFirst().contains(where: { $0.isUppercase }),
       lettersOnly.contains(where: { $0.isLowercase }) { return .hard }
    if t.hasPrefix("/") || t.hasPrefix("./") || t.hasPrefix("../") || t.hasPrefix("~") || t.contains("@") || t.contains("\\") { return .soft }
    let a = Array(t)
    for i in a.indices.dropFirst().dropLast() where (a[i] == "." || a[i] == "/") && a[i - 1].isLetter && a[i + 1].isLetter { return .soft }
    return .none
  }

  public struct Context {
    public var prevScreen: String?         // the word on screen before this one (after any fix), nil at a start
    public var prevRun: [[Key]] = []       // keys of the words before it typed in this same layout, still as typed
                                           // (since the last switch, fix, click or Return), oldest first
    public var lastCyrillic: Int?          // index of the Cyrillic layout used last
    public init(prevScreen: String? = nil, prevRun: [[Key]] = [], lastCyrillic: Int? = nil) {
      self.prevScreen = prevScreen; self.prevRun = prevRun; self.lastCyrillic = lastCyrillic }
  }

  func scriptOf(_ s: String?) -> Script? {
    guard let s = s else { return nil }
    for c in s.unicodeScalars { if (0x0400...0x04FF).contains(c.value) { return .cyrillic }
      if (0x41...0x5A).contains(c.value) || (0x61...0x7A).contains(c.value) { return .latin } }
    return nil
  }

  /// Best alternative for the keys typed in layout `t`: (index, log10 odds alt:typed).
  func best(_ rs: [Reading], _ t: Int, cyrillicPair: Bool, lastCyr: Int?) -> (Int, Float)? {
    let tl = layouts[t]; let tr = rs[t]
    var cands: [(Int, Float)] = []; var pairBest: Float = -.infinity
    for r in rs where r.layout != t {
      let l = layouts[r.layout]; guard l.lang != nil, l.lang != tl.lang, r.text != tr.text else { continue }
      if l.script == tl.script && !cyrillicPair { pairBest = max(pairBest, r.score - tr.score); continue }
      if l.script != tl.script && cyrillicPair { continue }
      cands.append((r.layout, r.score - tr.score))
    }
    guard var b = cands.max(by: { $0.1 < $1.1 }) else { return nil }
    // Ukrainian typed on the Russian layout (or the reverse) is explained best by the other Cyrillic
    // layout, not by Latin: with the pair off such a word is left alone, never sent into Latin.
    if pairBest > b.1 { return nil }
    // two Cyrillic readings close together: the one used last wins
    // (and when the two have the same letters and differ only in punctuation, the one used last
    // wins outright: the language decides the punctuation, not the reverse)
    if let lc = lastCyr, b.0 != lc, let o = cands.first(where: { $0.0 == lc }),
       b.1 - o.1 < opt.cyrTie || rs[o.0].text.filter({ $0.isLetter }) == rs[b.0].text.filter({ $0.isLetter }) { b = o }
    return b
  }

  func coreLen(_ s: String) -> Int { s.filter { $0.isLetter }.count }

  /// Auto: at the end of a word typed in layout `t`.
  public func decide(_ keys: [Key], typed t: Int, _ ctx: Context, cyrillicPair: Bool = false) -> Verdict {
    let rs = readings(keys, asTyped: t)
    let shape = structural(rs[t].text, layouts[t])
    if shape == .hard || coreLen(rs[t].text) == 0 { return .right }
    guard let (a, d) = best(rs, t, cyrillicPair: cyrillicPair, lastCyr: ctx.lastCyrillic) else { return .right }
    if shape == .soft && !(rs[a].isWord && !(rs[t].isWord && rs[t].clean)) { return .right }
    let n = min(coreLen(rs[t].text), coreLen(rs[a].text))
    let same = scriptOf(ctx.prevScreen) == layouts[t].script
    // we only ever turn text into an ordinary word: letters, with ordinary punctuation around them
    if !rs[a].clean || (!rs[a].isWord && rs[a].shape < opt.plausFloor) { return d < -opt.gateSpace ? .right : .unsure }
    let letters = rs[t].text.filter { $0.isLetter }
    let caps = letters.count >= 2 && letters.allSatisfy { $0.isUppercase }
    let short = n <= opt.shortLen || (caps && n <= opt.capsShort)
    // after a number a short word is a unit ("3 шт", "5 kg", "100 гб"), not a slip
    if n <= 3, let p = ctx.prevScreen, p.contains(where: { $0.isNumber }), !p.contains(where: { $0.isLetter }) { return .unsure }
    var need = opt.fixThreshold + (short ? opt.shortExtra : 0) + (caps && n <= opt.capsShort ? opt.capsExtra : 0) + (rs[a].isWord ? 0 : opt.altOOV)
    // For ru <-> uk a word before it in the same script is no evidence: most words read the same in
    // both Cyrillic layouts. Only a letter one of them lacks (і ї є ґ / ы э ъ ё) shows which is in use.
    var prior = same ? opt.priorRun : opt.priorStart
    if cyrillicPair && same && !Detector.showsCyrillic(ctx.prevScreen) { prior = opt.priorStart }
    var odds = d + prior
    var back = 0
    if opt.backFix && d > 0 {
      // The layout cannot change between words without a switch, so if this word is a mistake the
      // mistake may have begun a word or three earlier: words held as unsure, or ones that read the
      // same in both layouts (numbers), are fixed with it when together they make the stronger case.
      var sum = d; var k = 0
      for pk in ctx.prevRun.reversed().prefix(opt.backMax) {
        k += 1
        let prs = readings(pk, asTyped: t)
        if structural(prs[t].text, layouts[t]) != .none { break }
        if prs[a].text == prs[t].text { continue }        // same in both: rides along
        let pd = prs[a].score - prs[t].score
        guard pd > -0.5, prs[a].clean, coreLen(prs[t].text) > 0, prs[a].isWord || prs[a].shape >= opt.plausFloor else { break }
        sum += pd
        let joint = sum + opt.priorStart
        if joint > odds { odds = joint; back = k }
      }
    }
    // a word shorter than minLetters (one letter: в, и, я = d, b, z) is fixed only when the word
    // before it is already in the other script ("привет d" -> "привет в") or confirms it (back)
    let ctxAlt = scriptOf(ctx.prevScreen) == layouts[a].script
    if odds > need && (n >= opt.minLetters || back > 0 || (opt.shortByContext && ctxAlt)) { return .wrong(target: a, back: back) }
    if d < -opt.gateSpace { return .right }
    return .unsure
  }

  /// Manual: the input source was switched from `t` to `to` right after the word.
  /// Returns true when the word should be retyped in `to`.
  public func manualRetype(_ keys: [Key], typed t: Int, to: Int, touching: Bool) -> Bool {
    let rs = readings(keys, asTyped: t)
    if rs[to].text == rs[t].text { return false }
    let d = rs[to].score - rs[t].score
    if layouts[t].lang == nil || layouts[to].lang == nil { return true }
    // one letter and the language key right after it (no space): never a deliberate switch
    // (Spotlight: «н» typed for the «Y» of YouTube)
    if touching && coreLen(rs[t].text) <= 1 { return true }
    // after "word " a switch is often deliberate: retype only into something that reads as a word
    if !touching && (!rs[to].clean || (!rs[to].isWord && rs[to].shape < opt.plausFloor)) { return false }
    return d > -(touching ? opt.gateTouch : opt.gateSpace)
  }
}
