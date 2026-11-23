// Command line interface for Retyper: fix wrong-layout text with Retyper's measured detector, manage Exceptions.txt, and check status.
// Run as retyper-cli (symlink to Retyper.app/Contents/MacOS/Retyper) or as Retyper with subcommands:
//
//   retyper-cli fix [--from en|ru|uk] [--to en|ru|uk] [TEXT... | -]
//   retyper-cli exceptions list [--json]
//   retyper-cli exceptions add WORD...
//   retyper-cli exceptions remove WORD...
//   retyper-cli status [--json]
//   retyper-cli --version | --help

import AppKit
import ApplicationServices

private let retyperCliName = "retyper-cli"

private let rtAppBundle: Bundle = {
    let real = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let appURL = real.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return Bundle(url: appURL) ?? .main
}()

private func retyperAnswersForItself() -> Bool {
    typealias Lookup = @convention(c) (pid_t) -> pid_t
    let me = getpid()
    if let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") {
        let r = unsafeBitCast(f, to: Lookup.self)(me)
        if r > 0 { return r == me }
    }
    return getppid() == 1
}

private func rtFail(_ s: String) -> Never {
    FileHandle.standardError.write(Data((s + "\n").utf8))
    exit(1)
}

private func rtJSON(_ obj: Any) -> Never {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else { rtFail("Could not encode JSON.") }
    print(text)
    exit(0)
}

private func rtRunning() -> Bool {
    guard let id = rtAppBundle.bundleIdentifier else { return false }
    return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != getpid() }
}

private func layoutKeys(_ word: String, in layout: Layout) -> [Key]? {
    var out: [Key] = []
    for c in word {
        guard let k = layout.key(for: c) else { return nil }
        out.append(k)
    }
    return out
}

@MainActor private func runFix(_ args: [String], usage: String) -> Never {
    var fromLang: String? = nil, toLang: String? = nil
    var textParts: [String] = []
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--from":
            guard i + 1 < args.count else { rtFail(usage) }
            fromLang = args[i + 1]; i += 2
        case "--to":
            guard i + 1 < args.count else { rtFail(usage) }
            toLang = args[i + 1]; i += 2
        default:
            textParts.append(args[i]); i += 1
        }
    }
    let input: String
    if textParts.isEmpty || textParts == ["-"] {
        input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    } else {
        input = textParts.joined(separator: " ")
    }

    guard let dataDir = rtAppBundle.resourceURL?.appendingPathComponent("data") else { rtFail("Language data missing from bundle.") }
    var models: [String: LangModel] = [:]
    for l in ["en", "ru", "uk"] { models[l] = LangModel(lang: l, dir: dataDir) }
    var opt = Options(); opt.autoCyrillicPair = true
    let detector = Detector(layoutIDs: Core.enabledLayoutIDs(), dataDir: dataDir, options: opt, shared: models)
    guard !detector.layouts.isEmpty else { rtFail("No keyboard layouts found.") }

    // Direct conversion when --from and --to are both specified.
    if let fl = fromLang, let tl = toLang {
        guard let fIdx = detector.layouts.firstIndex(where: { $0.lang == fl }),
              let tIdx = detector.layouts.firstIndex(where: { $0.lang == tl }) else {
            rtFail("Layout not installed for --from \(fl) or --to \(tl).")
        }
        let fromL = detector.layouts[fIdx], toL = detector.layouts[tIdx]
        var out = ""
        for ch in input {
            if let k = fromL.key(for: ch) { out += toL.read(k) } else { out.append(ch) }
        }
        print(out, terminator: textParts.isEmpty || textParts == ["-"] ? "" : "\n")
        exit(0)
    }

    // Automatic word-by-word fix preserving whitespace, respecting Exceptions.txt.
    var exc = Exceptions()
    var ctx = Detector.Context()
    var tokens: [(isSpace: Bool, text: String)] = []
    var cur = "", inSpace = false
    for ch in input {
        let sp = ch.isWhitespace
        if cur.isEmpty { inSpace = sp; cur.append(ch) }
        else if sp == inSpace { cur.append(ch) }
        else { tokens.append((inSpace, cur)); inSpace = sp; cur = String(ch) }
    }
    if !cur.isEmpty { tokens.append((inSpace, cur)) }

    var wordIdxHistory: [Int] = []
    var lastLayout: Int? = nil
    for idx in tokens.indices {
        if tokens[idx].isSpace {
            if tokens[idx].text.contains("\n") { ctx.prevRun = []; wordIdxHistory = []; lastLayout = nil }
            continue
        }
        let word = tokens[idx].text
        if exc.contains(word) { ctx.prevScreen = word; ctx.prevRun = []; wordIdxHistory = []; continue }
        // Pick the layout that can type this word (preferring --from if given, else matching script).
        var typedIdx: Int? = nil
        var keys: [Key]? = nil
        if let fl = fromLang, let i = detector.layouts.firstIndex(where: { $0.lang == fl }), let ks = layoutKeys(word, in: detector.layouts[i]) {
            typedIdx = i; keys = ks
        } else {
            let hasCyr = word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
            let ordered = detector.layouts.indices.sorted { a, b in
                let ma = (detector.layouts[a].script == (hasCyr ? .cyrillic : .latin)) ? 0 : 1
                let mb = (detector.layouts[b].script == (hasCyr ? .cyrillic : .latin)) ? 0 : 1
                return ma < mb
            }
            for i in ordered {
                if let ks = layoutKeys(word, in: detector.layouts[i]) { typedIdx = i; keys = ks; break }
            }
        }
        guard let t = typedIdx, let ks = keys else {
            ctx.prevScreen = word; ctx.prevRun = []; wordIdxHistory = []; lastLayout = nil
            continue
        }
        if lastLayout != nil && lastLayout != t { ctx.prevRun = []; wordIdxHistory = [] }
        lastLayout = t

        var verdict = detector.decide(ks, typed: t, ctx, cyrillicPair: false)
        if case .right = verdict, detector.layouts[t].script == .cyrillic {
            verdict = detector.decide(ks, typed: t, ctx, cyrillicPair: true)
        }
        switch verdict {
        case .wrong(let target, let back):
            let fixed = detector.layouts[target].read(ks)
            tokens[idx].text = fixed
            if back > 0 {
                let n = min(back, min(ctx.prevRun.count, wordIdxHistory.count))
                for k in 0..<n {
                    let prevTokIdx = wordIdxHistory[wordIdxHistory.count - 1 - k]
                    let prevKeys = ctx.prevRun[ctx.prevRun.count - 1 - k]
                    tokens[prevTokIdx].text = detector.layouts[target].read(prevKeys)
                }
            }
            ctx.prevScreen = fixed
            if detector.layouts[target].script == .cyrillic { ctx.lastCyrillic = target }
            ctx.prevRun = []; wordIdxHistory = []; lastLayout = target
        case .unsure:
            ctx.prevScreen = word
            ctx.prevRun.append(ks); wordIdxHistory.append(idx)
        case .right:
            ctx.prevScreen = word
            if detector.layouts[t].script == .cyrillic { ctx.lastCyrillic = t }
            ctx.prevRun = []; wordIdxHistory = []
        }
    }
    let result = tokens.map(\.text).joined()
    print(result, terminator: textParts.isEmpty || textParts == ["-"] ? "" : "\n")
    exit(0)
}

@MainActor private func runExceptions(_ args: [String], usage: String) -> Never {
    guard let sub = args.first else { rtFail(usage) }
    let tail = Array(args.dropFirst())
    var exc = Exceptions()
    switch sub {
    case "list":
        let json = tail == ["--json"]
        guard tail.isEmpty || json else { rtFail(usage) }
        let list = exc.list
        if json { rtJSON(list) }
        for w in list { print(w) }
        exit(0)
    case "add":
        guard !tail.isEmpty else { rtFail(usage) }
        var cur = exc.list
        var added: [String] = []
        for raw in tail {
            let w = Exceptions.norm(raw)
            guard !w.isEmpty else { continue }
            if !cur.map(Exceptions.norm).contains(w) { cur.append(w); added.append(w) }
        }
        exc.save(cur)
        print(added.isEmpty ? "Already in exceptions." : "Added: \(added.joined(separator: ", "))")
        exit(0)
    case "remove":
        guard !tail.isEmpty else { rtFail(usage) }
        let drop = Set(tail.map(Exceptions.norm))
        let before = exc.list
        let after = before.filter { !drop.contains(Exceptions.norm($0)) }
        exc.save(after)
        let n = before.count - after.count
        print(n == 0 ? "None removed." : "Removed \(n) \(n == 1 ? "word" : "words").")
        exit(0)
    default:
        rtFail(usage)
    }
}

@MainActor private func runStatus(_ args: [String], usage: String) -> Never {
    let json = args == ["--json"]
    guard args.isEmpty || json else { rtFail(usage) }
    let version = rtAppBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let running = rtRunning()
    let access = AXIsProcessTrusted()
    let layouts = Core.enabledLayoutIDs()
    let exc = Exceptions().list
    if json {
        rtJSON([
            "version": version,
            "running": running,
            "accessibility": access,
            "layouts": layouts,
            "exceptionsCount": exc.count,
            "exceptionsFile": Exceptions.file.path,
        ])
    }
    print("version: \(version)")
    print("running: \(running ? "yes" : "no")")
    print("accessibility: \(access ? "yes" : "no")")
    print("layouts: \(layouts.joined(separator: ", "))")
    print("exceptions: \(exc.count) (\(Exceptions.file.path))")
    exit(0)
}

@MainActor func runRetyperCLI(_ rawArgs: [String]) -> Bool {
    let exe = rtAppBundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "Retyper"
    let named = URL(fileURLWithPath: rawArgs[0]).lastPathComponent != exe
    let rest = Array(rawArgs.dropFirst())
    let usage = """
    Usage: \(retyperCliName) fix [--from en|ru|uk] [--to en|ru|uk] [TEXT... | -]
           \(retyperCliName) exceptions list [--json]
           \(retyperCliName) exceptions add WORD...
           \(retyperCliName) exceptions remove WORD...
           \(retyperCliName) status [--json]
           \(retyperCliName) --version | --help
    """
    let guiFlags: Set<String> = ["--login", "--background", "--shot", "--exceptions", "--dark", "--light"]
    guard let cmd = rest.first else {
        if named { print(usage); exit(0) }
        return false
    }
    switch cmd {
    case "--help", "-h":
        print(usage); exit(0)
    case "--version", "-V":
        let v = rtAppBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let n = rtAppBundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Retyper"
        print("\(n) \(v)"); exit(0)
    case "fix", "exceptions", "status":
        break
    default:
        if named || (cmd.hasPrefix("--") && !guiFlags.contains(cmd)) { rtFail(usage) }
        return false
    }
    if retyperAnswersForItself() {
        rtFail("\(retyperCliName) runs from a terminal or script, not launched as an app or launchd job.")
    }
    let tail = Array(rest.dropFirst())
    switch cmd {
    case "fix": runFix(tail, usage: usage)
    case "exceptions": runExceptions(tail, usage: usage)
    case "status": runStatus(tail, usage: usage)
    default: rtFail(usage)
    }
}
