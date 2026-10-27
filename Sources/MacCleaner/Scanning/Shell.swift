import Foundation

/// Runs command-line tools (docker, xcrun). Apps opened from Finder get a bare
/// PATH, so tools are located by checking their usual install spots.
enum Shell {
    struct Result {
        let status: Int32
        let output: String
        var succeeded: Bool { status == 0 }
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static func locate(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            DiskUtils.home.appendingPathComponent(".docker/bin/\(name)").path,
            "/Applications/Docker.app/Contents/Resources/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
