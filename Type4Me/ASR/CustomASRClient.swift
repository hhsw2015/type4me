import Foundation
import os

/// Custom streaming ASR over a self-hosted WebSocket gateway (typeless2api `/stream`).
///
/// Lets you point Type4Me at your own gateway (八哥/doubao/typeless pool) and get
/// true streaming latency instead of the batch OpenAI path. Configure the `.custom`
/// provider with `Endpoint URL` = `ws://127.0.0.1:8790/stream` (API Key optional).
///
/// Gateway protocol (typeless2api internal/stream):
///   1. text config frame: {"backend","operation","source_lang","target_lang",
///                          "sample_rate","partials","authorization"}
///   2. binary PCM16LE 16k mono frames, fed live as captured
///   3. text {"type":"end"} on stop
///   -> server streams {"partial":"..."} then a final {"text":"..."}
///
/// Audio is forwarded frame-by-frame with no client-side buffering, so post-stop
/// latency is the gateway/backend floor (~0.4-0.9s for 八哥), i.e. the theoretical max.
actor CustomASRClient: SpeechRecognizer {
    private let logger = Logger(subsystem: "com.type4me.asr", category: "CustomASRClient")
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var stream: AsyncStream<RecognitionEvent>?
    private var didEnd = false

    var events: AsyncStream<RecognitionEvent> {
        if let stream { return stream }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.stream = stream
        eventContinuation = continuation
        return stream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions = ASRRequestOptions()) async throws {
        guard let config = config as? CustomASRConfig else {
            throw CustomASRError.invalidConfig
        }
        let raw = config.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" else {
            throw CustomASRError.invalidEndpoint
        }

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.stream = stream
        eventContinuation = continuation
        didEnd = false

        let task = URLSession(configuration: options.urlSessionConfiguration).webSocketTask(with: url)
        webSocketTask = task
        task.resume()

        // 1. config frame — one utterance per connection.
        let frame: [String: Any] = [
            "backend": "auto",
            "operation": "POLISH",
            "source_lang": "AUTO",
            "target_lang": NSNull(),
            "sample_rate": 16000,
            "partials": true,
            "authorization": config.apiKey ?? "",
        ]
        let frameData = try JSONSerialization.data(withJSONObject: frame)
        try await task.send(.string(String(decoding: frameData, as: UTF8.self)))

        startReceiveLoop()
        logger.info("Custom /stream WebSocket connected: \(url.absoluteString, privacy: .private(mask: .hash))")
    }

    func sendAudio(_ data: Data) async throws {
        guard let webSocketTask, !data.isEmpty else { return }
        try await webSocketTask.send(.data(data))
    }

    func endAudio() async throws {
        guard let webSocketTask, !didEnd else { return }
        didEnd = true
        try await webSocketTask.send(.string(#"{"type":"end"}"#))
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        stream = nil
        didEnd = false
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = await self.webSocketTask else { break }
                    let message = try await task.receive()
                    await self.handle(message)
                } catch {
                    if !Task.isCancelled {
                        await self.emit(.error(error))
                        await self.emit(.completed)
                    }
                    break
                }
            }
        }
    }

    private func emit(_ event: RecognitionEvent) {
        eventContinuation?.yield(event)
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: return
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        if let err = obj["error"] as? String {
            let detail = obj["detail"] as? String ?? ""
            emit(.error(CustomASRError.server(err, detail)))
            emit(.completed)
            eventContinuation?.finish()   // let the session's event drain return immediately
            return
        }
        if let partial = obj["partial"] as? String {
            emit(.transcript(RecognitionTranscript(
                confirmedSegments: [], partialText: partial,
                authoritativeText: partial, isFinal: false)))
            return
        }
        if let text = obj["text"] as? String {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            emit(.transcript(RecognitionTranscript(
                confirmedSegments: clean.isEmpty ? [] : [clean], partialText: "",
                authoritativeText: clean, isFinal: true)))
            emit(.completed)
            eventContinuation?.finish()   // final delivered → end the stream so teardown is instant
        }
    }
}

enum CustomASRError: LocalizedError {
    case invalidConfig
    case invalidEndpoint
    case server(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig:
            return L("自定义识别配置无效", "Invalid custom ASR config")
        case .invalidEndpoint:
            return L("端点 URL 无效，需以 ws:// 或 wss:// 开头", "Invalid endpoint URL (must start with ws:// or wss://)")
        case .server(let code, let detail):
            return L("网关错误：\(code) \(detail)", "Gateway error: \(code) \(detail)")
        }
    }
}
