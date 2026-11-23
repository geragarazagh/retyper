# AGENTS.md — Retyper

Offline macOS keyboard-layout fixer (`ghbdtn` → `привет`, `en`/`ru`/`uk`) in plain Swift + AppKit + Carbon TIS. No Xcode project; `./build` compiles directly with `swiftc`.

## Architecture

- `main.swift` — entry point, session `CGEventTap`, input-source observers, calls `runRetyperCLI`.
- `cli.swift` — `retyper-cli` (`fix`, `exceptions list|add|remove`, `status`, `--version`, `--help`) with `answersForItself()` guard.
- `detect.swift` — 100k-word frequency + character n-gram `Detector`, `Layout` (`UCKeyTranslate`), structural code/URL/flag guards, back-sweep.
- `core.swift` — keystroke ring buffer (80 keys in RAM only), auto-fix replacement via `CGEventTapPostEvent`, `Exceptions` file (`~/Library/Application Support/Retyper/Exceptions.txt`, auto-reloaded on mtime change).
- `manual.swift`, `cycle.swift` — forced Retype key (`⌥⌥`) and 3-language cycle (`en → ru → uk → en`), AX selection fallback.
- `tty.swift` — terminal password-prompt (`ECHO` off + `ICANON` on) and busy-tty guard across macOS terminals.
- `exceptions.swift`, `keyrow.swift`, `window.swift` — Settings & Exceptions UI.
- `data/{en,ru,uk}.{words,ngram}` — language models packed with LZFSE into `Contents/Resources/data/`.

## Build & Test

- `./build` — builds ad-hoc signed `Retyper.app` (`-target arm64-apple-macos13.0`). Works with Xcode Command Line Tools alone (falls back to `iconutil`). Full Xcode is used for `Assets.car` (required when `SIGN_ID` is set).
- `TRACE=1 ./build` — diagnostic build logging decisions to stderr (never signed with Developer ID).

## Invariants

- **Privacy**: never logs keystrokes or writes anything outside `Exceptions.txt`; skips Secure Input and terminal password prompts.
- **Bundle ID**: stays `com.geragaraza.sourcekey` (historical name) so macOS preserves Accessibility grants across updates.
- **Customizing locally**: edit source, run `./build`, replace `/Applications/Retyper.app`. Ad-hoc re-signing requires re-granting Accessibility.
