import Foundation

// MARK: - Dates

enum ISODate {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parses RFC 3339 timestamps, including Python-style microsecond fractions.
    static func parse(_ string: String) -> Date? {
        if let date = fractional.date(from: string) ?? whole.date(from: string) {
            return date
        }
        // ISO8601DateFormatter can reject more than 3 fractional digits; keep the milliseconds.
        guard let range = string.range(of: #"\.\d+"#, options: .regularExpression) else { return nil }
        let digits = string[range].dropFirst()
        let millis = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        return fractional.date(from: string.replacingCharacters(in: range, with: "." + millis))
    }
}

// MARK: - Loose JSON access

/// The usage endpoints are undocumented, so values are read defensively instead of via Codable.
enum JSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badResponse("not a JSON object")
        }
        return object
    }

    static func double(_ value: Any?) -> Double? {
        let result: Double?
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            result = number.doubleValue
        case let string as String: result = Double(string)
        default: return nil
        }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }

    /// Accepts epoch seconds, epoch milliseconds or an ISO 8601 string.
    static func date(_ value: Any?) -> Date? {
        if let string = value as? String {
            return ISODate.parse(string) ?? double(string).map(epoch)
        }
        return double(value).map(epoch)
    }

    private static func epoch(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }
}

// MARK: - Subprocesses

public enum Shell {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data
    }

    public enum Failure: Error {
        case launch(String)
        case timedOut
    }

    private final class Buffer: @unchecked Sendable {
        var data = Data()
    }

    /// Runs a program synchronously with a timeout. Call off the main thread.
    public static func run(
        _ path: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 10
    ) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw Failure.launch(error.localizedDescription)
        }

        let out = Buffer()
        let err = Buffer()
        let group = DispatchGroup()
        for (pipe, buffer) in [(outPipe, out), (errPipe, err)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                buffer.data = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
            throw Failure.timedOut
        }
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: out.data, stderr: err.data)
    }

    /// PATH for child processes: GUI apps don't inherit the login shell's PATH.
    static var toolPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "\(home)/.bun/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ].joined(separator: ":")
    }

    /// Finds an executable by name on `toolPath`.
    static func locate(_ name: String) -> String? {
        toolPath.split(separator: ":")
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - HTTP

enum HTTP {
    static let userAgent = "UsageBattery/1.0 (macOS)"

    /// This app has no inference API. Even accidental future callers cannot send
    /// prompts or credentials to a generation endpoint through this transport.
    static func request(_ url: URL, headers: [String: String]) throws -> URLRequest {
        guard url == ClaudeSource.endpoint || url == CodexSource.endpoint else {
            throw UsageError.badResponse("only read-only usage checks are allowed")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    static func get(_ url: URL, headers: [String: String], session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let request = try request(url, headers: headers)
        do {
            let (data, response) = try await session.data(for: request, delegate: NoUsageRedirects.shared)
            guard let http = response as? HTTPURLResponse else {
                throw UsageError.badResponse("no HTTP response")
            }
            return (data, http)
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
    }

    /// Maps non-2xx statuses to UsageError. `authMessage` is shown for 401/403.
    static func check(_ response: HTTPURLResponse, authMessage: String) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw UsageError.unauthorized(authMessage)
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap { retryDelay($0) }
            throw UsageError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageError.badResponse("HTTP \(response.statusCode)")
        }
    }

    static func retryDelay(_ value: String, now: Date = Date()) -> TimeInterval? {
        if let seconds = Double(value), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}

/// A usage request cannot redirect its credentials or become another request type.
private final class NoUsageRedirects: NSObject, URLSessionTaskDelegate {
    static let shared = NoUsageRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
