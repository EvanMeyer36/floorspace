import CFloorspace
import Foundation

/// The shared Rust engine (core/), reached through its C interface (ffi/). The same engine runs
/// the Windows and Linux desktop app. Requests are a method name plus JSON arguments; replies
/// decode straight into the types in EngineTypes.swift.
///
/// Calls that scan or remove block until done, so make them off the main thread.
enum Engine {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Reply<T: Decodable>: Decodable {
        let value: T

        enum CodingKeys: String, CodingKey { case ok, error }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let message = try container.decodeIfPresent(String.self, forKey: .error) {
                throw Failure(message: message)
            }
            value = try container.decode(T.self, forKey: .ok)
        }
    }

    private static let decoder = JSONDecoder()

    static func call<T: Decodable>(_ method: String, _ args: [String: Any] = [:], as type: T.Type = T.self) throws -> T {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        guard let raw = floorspace_call(method, json) else { throw Failure(message: "The engine didn't reply to \(method).") }
        defer { floorspace_free(raw) }
        let data = Data(bytes: raw, count: strlen(raw))
        do {
            return try decoder.decode(Reply<T>.self, from: data).value
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(message: "Couldn't read the engine's reply to \(method): \(error)")
        }
    }

    /// For calls whose reply has no value.
    static func send(_ method: String, _ args: [String: Any] = [:]) {
        _ = try? call(method, args, as: Ignored?.self)
    }

    private struct Ignored: Decodable {}

    /// Runs a blocking engine call off the main thread.
    static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    // MARK: - Typed helpers

    static func progress(_ kind: String) -> ProgressSnapshot? {
        (try? call("progress", ["kind": kind], as: ProgressSnapshot?.self)) ?? nil
    }

    static func cancel(_ kind: String) {
        send("cancel", ["kind": kind])
    }
}
