// tty.swift: what the line of a terminal in front is waiting for.
// Secure Input keeps keys away from the tap, but only Terminal.app, iTerm2 and Ghostty turn it on at a password prompt.
// Others (Alacritty, Warp, WezTerm, Tabby, VS Code's; Terminal.app itself at `read -s`) hand a password to the tap like
// any text, and a fix at Return would type it changed. A program asking for a password locally clears ECHO and keeps
// ICANON on its terminal (readpassphrase, getpass, `read -s`), which is what Terminal.app looks for too. A shell editing
// its own command line (zsh, bash, fish…) clears both. Anything else in front of a terminal (sudo before its prompt is
// up, ssh or tmux, where a remote password prompt can't be seen, an editor, a REPL) is busy: no fix at Return or Tab.
// Measured 2026-11-13 on 26 (card dev/layout.md, «Terminals»): which terminals turn Secure Input on, that each one's
// shells descend from its process (through login, iTermServer, a pty host), and that a password typed ahead of its
// prompt at 10 ms a key outran a cached answer: hence the fresh look at every Return and Tab in a terminal (core.swift).

import Foundation
import Darwin

enum Line { case none, prompt, password, busy }

enum TTY {
    /// Shells that edit their own command line: a fix at Return there types a command, never a secret.
    static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "tcsh", "csh", "fish", "nu", "pwsh", "xonsh", "elvish", "-zsh", "-bash", "-sh", "-fish"]

    struct Proc { let pid: pid_t, ppid: pid_t, pgid: pid_t, tpgid: pid_t, tdev: dev_t, comm: String }

    static func procs() -> [Proc] {
        // Every process, not only ours: Terminal.app, iTerm2, Alacritty and Ghostty start the shell through
        // /usr/bin/login, which runs as root and would break the chain from the app to its shells (measured 2026-11-13).
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
        size += size / 8
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        return buf.prefix(size / MemoryLayout<kinfo_proc>.stride).map { k in
            var c = k.kp_proc.p_comm
            let comm = withUnsafeBytes(of: &c) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return Proc(pid: k.kp_proc.p_pid, ppid: k.kp_eproc.e_ppid, pgid: k.kp_eproc.e_pgid,
                        tpgid: k.kp_eproc.e_tpgid, tdev: k.kp_eproc.e_tdev, comm: comm)
        }
    }

    /// The device's path. devname() takes about 1 ms a call (measured 2026-11-13, 7 ttys = 7 ms); a pseudo-terminal's
    /// name follows from its minor number, checked by stat, with devname() left for anything else.
    static func path(_ dev: dev_t) -> String? {
        let guess = String(format: "/dev/ttys%03d", Int(dev) & 0xffffff)
        var st = stat()
        if stat(guess, &st) == 0, st.st_rdev == dev { return guess }
        return devname(dev, S_IFCHR).map { "/dev/" + String(cString: $0) }
    }

    /// Terminal flags of a tty device, read without making it ours.
    static func lflag(_ dev: dev_t) -> tcflag_t? {
        guard let path = path(dev) else { return nil }
        let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var t = termios()
        return tcgetattr(fd, &t) == 0 ? t.c_lflag : nil
    }

    /// The ttys whose processes descend from `app`, each with what its line waits for. Empty: not a terminal.
    static func lines(of app: pid_t, _ ps: [Proc]? = nil) -> [(dev: dev_t, fg: String, line: Line)] {
        let ps = ps ?? procs()
        var kids: [pid_t: [Proc]] = [:]
        for p in ps { kids[p.ppid, default: []].append(p) }
        var devs: [dev_t: Proc] = [:]
        var stack = kids[app] ?? []
        while let p = stack.popLast() {
            if p.tdev != -1, p.tdev != 0, devs[p.tdev] == nil { devs[p.tdev] = p }
            stack += kids[p.pid] ?? []
        }
        var byPid: [pid_t: Proc] = [:]
        for p in ps { byPid[p.pid] = p }
        return devs.map { dev, p in
            let fg = byPid[p.tpgid]?.comm ?? ps.first { $0.pgid == p.tpgid }?.comm ?? "?"
            guard let f = lflag(dev) else { return (dev, fg, .none) }
            let echo = f & tcflag_t(ECHO) != 0, canon = f & tcflag_t(ICANON) != 0
            if !echo && canon { return (dev, fg, .password) }
            if !echo && !canon && TTY.shells.contains(fg) { return (dev, fg, .prompt) }
            return (dev, fg, .busy)
        }
    }

    /// The state of the app in front. Which of its ttys has the focus can't be seen, so any of them counts: a password
    /// anywhere wins, then anything busy; .prompt only when every one is a shell at its prompt.
    static func state(of app: pid_t) -> Line {
        let ls = lines(of: app).map { $0.line }
        if ls.contains(.password) { return .password }
        if ls.contains(.busy) { return .busy }
        return ls.isEmpty ? .none : .prompt
    }
}
