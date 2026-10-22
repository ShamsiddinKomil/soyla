import Foundation

/// `soyla report [--phrase N] [--csv] [--file path] ...` : thin wrapper that execs python3 scripts/report.py.
public enum ReportCLI {
    public static func run(args: [String]) async throws {
        // The data root (App Support) has no scripts/; look in SOYLA_HOME, then the current directory (repo checkout).
        let candidates = [SoylaPaths.root, URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
            .map { $0.appendingPathComponent("scripts/report.py") }
        guard let script = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw SoylaError.decode("report.py not found (looked in \(candidates.map(\.path).joined(separator: ", "))); run from the repo or set SOYLA_HOME")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // A user-supplied --file later in args overrides the default (argparse keeps the last).
        p.arguments = ["python3", script.path, "--file", SoylaPaths.runsLog.path] + args
        p.standardOutput = FileHandle.standardOutput
        p.standardError = FileHandle.standardError
        p.standardInput = FileHandle.nullDevice
        let keyNames = Set(KeyProvider.allCases.map(\.envName))   // the child never sees any provider key (R1)
        p.environment = ProcessInfo.processInfo.environment.filter { !keyNames.contains($0.key) }
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw SoylaError.decode("report.py exited \(p.terminationStatus)") }
    }
}
