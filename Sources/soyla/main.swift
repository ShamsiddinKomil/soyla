import Foundation
import SoylaCore

// Single binary: no args → GUI app; subcommands → CLI tools. Each subcommand lives in the module that owns it.
let argv = Array(CommandLine.arguments.dropFirst())

func usage() {
    print("""
    soyla \(Soyla.version)
      (no args)                 launch the menu-bar app
      --onboarding              launch the app and open the Setup Assistant (settings untouched)
      --page <id>               launch the app on one Settings page (permissions|languages (= apiKeys)|dictation|hotkey|pill|privacy|about|developer)
      --appearance light|dark   launch the app in one appearance (docs captures); combines with the two above
      --entry <step>            launch the app and open setup at one step from the app (languages|permissions|connect)
      --snapshot <file.png>     launch the app and render its front window into a PNG after 3 s (docs captures)
      --tall                    with --snapshot: render the window 1100 pt tall (pages taller than 768)
      --preview <state>         docs captures: the Languages page with made-up state (en|uz-missing|uz-mac|uz-connected), saved nowhere
      --pill-demo               launch the app and drive the pill through recording, transcribing and a failure card (nothing sent)
      replay <audio> [opts]     re-send a recording to one or more models
                                (--provider openrouter|google|custom --models a,b --formats wav,flac,m4a,ogg --cleanup
                                 --language uz --phrase N --prewarm --no-prewarm --no-log)
      models [--refresh]        list OpenRouter transcription models + pricing
      report [--phrase N] [--csv] [--source live|replay|all] [--since YYYY-MM-DD] [--file path] [--home dir]
      rec-test [sec] [--warm] [--builtin]  record from the mic (device, pre-roll, first-buffer latency, verdict), encode in every format
      hotkey-test [choice] [--sec N] [--sim]  print hotkey gestures → reducer actions (default 20 s; --sim: offline table replay)
      paste-test "text" [--app label] [--expect pasted|copied] [--wait sec] [--delay ms] [--unicode]
                                paste into the frontmost app after --wait s (default 3), restore clipboard
      paste-test --keycodes     print the ⌘V keycode for the current and every installed layout
      live-test <wav> [--language uz]  stream a recording to Gemini Live at real-time pace, print interim text
      docs-shots <dir> [name…]  render the docs pictures off-screen from a demo profile (use scripts/docs_shots.sh)
      update-check [owner/repo] ask GitHub for the latest release (default \(UpdateCheck.repo))
    """)
}

func runCLI() async -> Int32 {
    do {
        switch argv.first {
        case nil: AppMain.run(); return 0
        case "replay": try await ReplayCLI.run(args: Array(argv.dropFirst()))
        case "update-check":
            let r = await UpdateCheck.fetchLatest(repo: argv.count > 1 ? argv[1] : UpdateCheck.repo)
            switch r { case .success(let rel): print("latest \(rel.tag) \(rel.url.absoluteString) newer=\(UpdateCheck.isNewer(tag: rel.tag, current: Soyla.version))"); case .failure(let f): print("failed: \(f)") }
        case "models": try await ModelsCLI.run(args: Array(argv.dropFirst()))
        case "report": try await ReportCLI.run(args: Array(argv.dropFirst()))
        case "rec-test": try await AudioCLI.recTest(args: Array(argv.dropFirst()))
        case "hotkey-test": try await HotkeyCLI.hotkeyTest(args: Array(argv.dropFirst()))
        case "paste-test": try await HotkeyCLI.pasteTest(args: Array(argv.dropFirst()))
        case "live-test": try await LiveCLI.run(args: Array(argv.dropFirst()))
        case "-h", "--help", "help": usage()
        default: usage(); return 2
        }
        return 0
    } catch {
        FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
        return 1
    }
}

/// GUI launch flags only: `--onboarding`, `--pill-demo`, `--page <id>`, `--appearance light|dark`, `--entry <step>`,
/// `--snapshot <file>`, `--fn-usage <n>`, in any combination.
func isGUILaunch(_ a: [String]) -> Bool {
    var i = 0
    while i < a.count {
        switch a[i] {
        case "--onboarding", "--pill-demo", "--tall": i += 1
        case "--page", "--appearance", "--entry", "--snapshot", "--preview", "--fn-usage": guard i + 1 < a.count else { return false }; i += 2
        default: return false
        }
    }
    return true
}

if argv.first == "docs-shots" {
    // AppKit needs the real main thread, which `dispatchMain()` below would retire.
    do { try MainActor.assumeIsolated { try DocsShots.run(args: Array(argv.dropFirst())) }; exit(0) } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); exit(1)
    }
} else if isGUILaunch(argv) {
    AppMain.run()          // GUI owns the main run loop (`--onboarding` opens the Setup Assistant, see AppDelegate)
} else {
    // Keep the main queue free (no semaphore): keyboard-layout calls must run on it (PasteKeycode.onMain).
    Task { exit(await runCLI()) }
    dispatchMain()
}
