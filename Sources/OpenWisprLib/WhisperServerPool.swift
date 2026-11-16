import Darwin
import Foundation

/// Persistent whisper-server process (#6b) — model stays resident between dictations.
public final class WhisperServerPool: STTEngine {
    public var name: String { "whisper-server (\(modelSize))" }
    public var modelName: String? { modelSize }
    public let executionRoute = STTExecutionRoute.localLoopback
    public let isPersistent = true
    public let modelSize: String
    private let language: String
    private var initialPrompt: String?
    private var process: Process?
    private let port: Int
    private let queue = DispatchQueue(label: "local-flow.whisper-server")
    private var isWarmed = false

    public init(modelSize: String, language: String, port: Int? = nil, initialPrompt: String? = nil) {
        self.modelSize = modelSize
        self.language = language
        self.port = port ?? Self.availableLoopbackPort()
        self.initialPrompt = initialPrompt
    }

    public func updateInitialPrompt(_ prompt: String?) {
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if normalized == initialPrompt { return }
        initialPrompt = normalized
        stop()
    }

    public func isAvailable() -> Bool {
        guard Transcriber.findWhisperBinary() != nil,
              Transcriber.findModel(modelSize: modelSize) != nil else { return false }
        return true
    }

    public func warmup() throws {
        try ensureRunning()
        guard !isWarmed else { return }
        if let url = try? makeSilentWAV() {
            defer { try? FileManager.default.removeItem(at: url) }
            _ = try? transcribe(audioURL: url)
            isWarmed = true
        }
    }

    public func ensureRunning() throws {
        if process?.isRunning == true, ping() { return }
        stop()
        WhisperServerOrphanCleaner.terminateOrphans()
        guard let serverPath = Self.findServerBinary(),
              let modelPath = Transcriber.findModel(modelSize: modelSize) else {
            throw WhisperServerError.notConfigured
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: serverPath)
        proc.arguments = {
            var args = [
                "-m", modelPath,
                "-l", language == "auto" ? "en" : language,
                "--host", "127.0.0.1",
                "--port", String(port),
                "--suppress-nst",
                "-nt",
            ]
            if let prompt = initialPrompt, !prompt.isEmpty {
                args += ["--prompt", prompt]
            }
            return args
        }()
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        process = proc

        for _ in 0..<40 {
            if !proc.isRunning { break }
            if ping() {
                Thread.sleep(forTimeInterval: 0.05)
                if proc.isRunning, ping() { return }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        stop()
        throw WhisperServerError.startTimeout
    }

    /// One in-flight /inference at a time so a stuck streaming chunk cannot
    /// starve the full-file finalize that recovers a locked take.
    private let inferenceQueue = DispatchQueue(label: "local-flow.whisper-server.inference")

    public func transcribe(audioURL: URL) throws -> String {
        try inferenceQueue.sync {
            try transcribeSerialized(audioURL: audioURL)
        }
    }

    private func transcribeSerialized(audioURL: URL) throws -> String {
        try ensureRunning()
        let boundary = "LocalVoice-\(UUID().uuidString)"
        var body = Data()
        let fileData = try Data(contentsOf: audioURL)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let httpTimeout = InferenceTimeout.httpSeconds(forAudioURL: audioURL)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = httpTimeout

        let sem = DispatchSemaphore(value: 0)
        var statusCode: Int?
        var responseData: Data?
        var transportError: Error?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            statusCode = (response as? HTTPURLResponse)?.statusCode
            responseData = data
            transportError = error
            sem.signal()
        }
        task.resume()
        let waitSeconds = InferenceTimeout.processWaitSeconds(httpSeconds: httpTimeout)
        if sem.wait(timeout: .now() + waitSeconds) == .timedOut {
            task.cancel()
            throw WhisperServerError.timeout
        }
        if let transportError, (statusCode ?? 200) == 200 {
            throw transportError
        }
        return try Self.parseInferenceResponse(statusCode: statusCode, data: responseData)
    }

    static func parseInferenceResponse(statusCode: Int?, data: Data?) throws -> String {
        if let statusCode, statusCode != 200 {
            throw WhisperServerError.httpError(statusCode)
        }
        guard let data, !data.isEmpty else {
            throw WhisperServerError.emptyResponse
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] {
                let message = error as? String ?? String(describing: error)
                throw WhisperServerError.serverError(message)
            }
            guard let text = json["text"] as? String else {
                throw WhisperServerError.serverError("response missing \"text\"")
            }
            return Transcriber.stripWhisperMarkers(text)
        }
        let plain = String(data: data, encoding: .utf8) ?? ""
        return Transcriber.stripWhisperMarkers(plain)
    }

    public func stop() {
        if let process {
            let pid = process.processIdentifier
            process.terminate()
            for _ in 0..<20 {
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                Darwin.kill(pid, SIGKILL)
                for _ in 0..<10 {
                    if !process.isRunning { break }
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        }
        process = nil
        isWarmed = false
    }

    public func shutdown() {
        stop()
    }

    deinit {
        stop()
    }

    private func ping() -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 0.5
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse { ok = http.statusCode < 500 }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 1)
        return ok
    }

    private static func findServerBinary() -> String? {
        for path in ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private static func availableLoopbackPort() -> Int {
        let descriptor = Darwin.socket(
            AF_INET,
            SOCK_STREAM,
            0
        )
        guard descriptor >= 0 else {
            return Int.random(in: 49152...65535)
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            return Int.random(in: 49152...65535)
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            return Int.random(in: 49152...65535)
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func makeSilentWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("warm-\(UUID().uuidString).wav")
        let sampleRate = 16000
        let frameCount = 4000
        let header = WAVHeader(sampleRate: sampleRate, dataSize: frameCount * 2)
        var data = header.data
        data.append(Data(count: frameCount * 2))
        try data.write(to: url)
        return url
    }
}

enum WhisperServerError: LocalizedError {
    case notConfigured
    case startTimeout
    case timeout
    case httpError(Int)
    case serverError(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "whisper-server or model not found"
        case .startTimeout: return "whisper-server failed to start"
        case .timeout: return "whisper-server inference timed out"
        case .httpError(let c): return "whisper-server HTTP \(c)"
        case .serverError(let message): return "whisper-server error: \(message)"
        case .emptyResponse: return "whisper-server returned empty response"
        }
    }
}

private struct WAVHeader {
    let sampleRate: Int
    let dataSize: Int

    var data: Data {
        var d = Data()
        d.append(contentsOf: "RIFF".utf8)
        d.append(UInt32(36 + dataSize).leData)
        d.append(contentsOf: "WAVE".utf8)
        d.append(contentsOf: "fmt ".utf8)
        d.append(UInt32(16).leData)
        d.append(UInt16(1).leData)
        d.append(UInt16(1).leData)
        d.append(UInt32(sampleRate).leData)
        d.append(UInt32(sampleRate * 2).leData)
        d.append(UInt16(2).leData)
        d.append(UInt16(16).leData)
        d.append(contentsOf: "data".utf8)
        d.append(UInt32(dataSize).leData)
        return d
    }
}

private extension UInt32 {
    var leData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
}
private extension UInt16 {
    var leData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
}
