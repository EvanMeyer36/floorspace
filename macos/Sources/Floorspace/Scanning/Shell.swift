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
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        // Collect output as it arrives rather than waiting for the pipe to close: a tool that
        // leaves a background process holding the pipe open (Docker can) would otherwise hang
        // the read. The process exiting is what we wait on, with a timeout.
        let output = OutputBuffer()
        let readDone = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                readDone.signal()
            } else {
                output.append(chunk)
            }
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 5)
        }
        if readDone.wait(timeout: .now() + 2) == .timedOut {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        return Result(status: process.isRunning ? -1 : process.terminationStatus, output: output.text)
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
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
