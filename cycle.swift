// cycle.swift: the order in which the Retype key (manual.swift) walks a text through the installed languages. Pressed
// again and again, the same keys are read in each language in turn and then come back as typed: Latin typed → the best
// Cyrillic reading → the other Cyrillic → as typed → … So a word meant as Ukrainian that came out Russian («ghbdsn»:
// «привыт» / «привіт», the Latin «s» key is ы in Russian and і in Ukrainian) is one more press away (his wish
// 2026-11-17; until then a second press only went back). With two layouts installed the cycle is the old toggle.
// Pure: layouts, readings and scores in, the order out; test/cycletest checks it on the real layout tables.

extension Detector {
  /// The layouts the Retype key steps through for a text typed in layout `t`, the typed layout itself left out (it
  /// closes the cycle). `text[i]` and `score[i]`: the text read in layout i and its score (log10, summed over words).
  /// - One step per language (en, ru, uk): of several layouts of one language (ABC and US, Russian and Russian-PC) the one
  ///   given as `first`, else the Cyrillic used last, else the best reading; such layouts differ in punctuation, not
  ///   letters, and a step that only moves a comma is not a language. Layouts of no known language are left out, as the
  ///   detector leaves them out; the typed language is the end of the cycle, not a step.
  /// - First step: `first` when given (the automatic fix or the language key already chose it: the cycle goes on from
  ///   there), else the best reading in the other script, the Cyrillic used last when two are within cyrTie: what the
  ///   first press has always done.
  /// - Then the rest: the other script before the typed one's own (Latin ↔ Cyrillic is what the key is mostly for; ru ↔
  ///   uk differ in a few letters), each group by score.
  /// - A step that reads the same as the typed text or an earlier step is dropped, so every press changes the text
  ///   («nfr» is «так» in Russian and Ukrainian alike: one step, not two); moving only the layout is the language key's job.
  public func retypeCycle(typed t: Int, first: Int?, text: [String], score: [Float], lastCyrillic: Int?) -> [Int] {
    let tl = layouts[t]
    var byLang: [String: Int] = [:]
    for i in layouts.indices where i != t {
      guard let lang = layouts[i].lang, lang != tl.lang else { continue }
      func rank(_ j: Int) -> (Int, Float) { (j == first ? 2 : (j == lastCyrillic ? 1 : 0), score[j]) }
      if let have = byLang[lang], rank(have) >= rank(i) { continue }
      byLang[lang] = i
    }
    var rest = byLang.values.sorted()
    var order: [Int] = []
    if let f = first, f != t {
      order.append(f)
      rest.removeAll { $0 == f || (layouts[f].lang != nil && layouts[$0].lang == layouts[f].lang) }
    } else {
      let other = rest.filter { layouts[$0].script != tl.script }
      let pool = other.isEmpty ? rest : other
      if var b = pool.max(by: { score[$0] < score[$1] }) {
        if let lc = lastCyrillic, lc != b, pool.contains(lc), score[b] - score[lc] < opt.cyrTie { b = lc }
        order.append(b); rest.removeAll { $0 == b }
      }
    }
    rest.sort { a, b in
      let ao = layouts[a].script != tl.script, bo = layouts[b].script != tl.script
      return ao != bo ? ao : score[a] > score[b]
    }
    order += rest
    var seen: Set<String> = [text[t]]
    return order.filter { seen.insert(text[$0]).inserted }
  }

  /// The same for the words of one change (a word, or the words a back fix took with it): each word read and scored in
  /// every layout, the scores summed.
  public func retypeCycle(_ words: [[Key]], typed t: Int, first: Int?, lastCyrillic: Int?) -> [Int] {
    var score = [Float](repeating: 0, count: layouts.count)
    var text = [String](repeating: "", count: layouts.count)
    for (n, w) in words.enumerated() {
      let rs = readings(w, asTyped: t)
      for r in rs { score[r.layout] += r.score; text[r.layout] += (n > 0 ? " " : "") + r.text }
    }
    return retypeCycle(typed: t, first: first, text: text, score: score, lastCyrillic: lastCyrillic)
  }

  // MARK: selections: the text is all there is, so the keys are found back through the layout that typed it

  static func script(of c: Character) -> Script {
    guard let u = c.unicodeScalars.first else { return .other }
    if (0x0400...0x04FF).contains(u.value) { return .cyrillic }
    return u.value < 0x250 ? .latin : .other
  }

  /// The layout whose keys typed a text: of its main script, the one that gives all its letters, tried first the
  /// Cyrillic used last (for Cyrillic text) or `preferred` (for Latin).
  public func source(of text: String, preferred: Int?, lastCyrillic: Int?) -> Int? {
    var latin = 0, cyr = 0
    for c in text where c.isLetter { switch Detector.script(of: c) { case .latin: latin += 1; case .cyrillic: cyr += 1; default: break } }
    guard latin + cyr > 0 else { return nil }
    let fromScript: Script = latin >= cyr ? .latin : .cyrillic
    let firstPick = fromScript == .cyrillic ? lastCyrillic : preferred
    let candidates = layouts.indices.filter { layouts[$0].script == fromScript }.sorted { a, _ in a == firstPick }
    func gives(_ l: Int) -> Bool { text.allSatisfy { c in !c.isLetter || Detector.script(of: c) != fromScript || layouts[l].key(for: c) != nil } }
    return candidates.first(where: gives)
  }

  /// The keys of each word of a text typed in `src` (a word with a character `src` can't type is left out).
  public func selectionWords(_ text: String, _ src: Int) -> [[Key]] {
    var out: [[Key]] = []
    for w in text.split(whereSeparator: { $0.isWhitespace }) where w.contains(where: { $0.isLetter }) {
      var k: [Key] = []
      for c in w { guard let x = layouts[src].key(for: c) else { k = []; break }; k.append(x) }
      if !k.isEmpty { out.append(k) }
    }
    return out
  }

  /// What the keys of `text` (typed in `src`) give in layout `to`; a character `src` can't type stays as it is.
  public func convert(_ text: String, _ src: Int, _ to: Int) -> String {
    var out = ""
    for c in text { if let k = layouts[src].key(for: c) { let r = layouts[to].read(k); out += r.isEmpty ? String(c) : r } else { out.append(c) } }
    return out
  }

  /// The cycle over a selection: the layout that typed it and each step with the text it gives (nil: none changes it).
  public func retypeCycle(selection text: String, preferred: Int?, first: Int?, lastCyrillic: Int?) -> (src: Int, steps: [(layout: Int, out: String)])? {
    guard let src = source(of: text, preferred: preferred, lastCyrillic: lastCyrillic) else { return nil }
    var score = [Float](repeating: 0, count: layouts.count)
    for k in selectionWords(text, src) { for r in readings(k, asTyped: src) { score[r.layout] += r.score } }
    let outs: [String] = layouts.indices.map { $0 == src ? text : convert(text, src, $0) }
    let order = retypeCycle(typed: src, first: first, text: outs, score: score, lastCyrillic: lastCyrillic)
    if order.isEmpty { return nil }
    let steps: [(layout: Int, out: String)] = order.map { (layout: $0, out: outs[$0]) }
    return (src: src, steps: steps)
  }
}
