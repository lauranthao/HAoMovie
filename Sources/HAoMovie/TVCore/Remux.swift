// Restored from Yingxia (jo32/tvbox-silicon, GPL-3.0) — shared helpers the kept
// files still use. Adapted for HAo Movie where noted (no TMDB, no JavaScript
// runtime, no libass/TVMedia); see the notes on each type.

import Foundation

/// Plays files AVPlayer can't open: MKV and WebM, AVI, FLV, WMV/ASF, RMVB, MPEG program streams.
/// HAo Movie ships no repackager (RemuxSession/TVMedia), so only the format checks below are real:
/// a file that needs repackaging still reports as handled (so it is offered for playback), but
/// there is no `open` — playback of such a file fails with unsupported until a repackager exists.
public enum Remux {
    /// Whether a file starting with these bytes is one the repackager opens and AVPlayer doesn't.
    public static func handles(_ head: Data) -> Bool {
        if DiscImage.handles(head) { return true }
        let bytes = [UInt8](head.prefix(16))
        guard bytes.count >= 4 else { return false }
        func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        if bytes[0..<4].elementsEqual([0x1A, 0x45, 0xDF, 0xA3]) { return true }                       // Matroska, WebM
        if bytes.count >= 12, text(0..<4) == "RIFF", text(8..<12) == "AVI " { return true }
        if text(0..<3) == "FLV" { return true }
        if bytes[0..<4].elementsEqual([0x30, 0x26, 0xB2, 0x75]) { return true }                       // ASF (WMV)
        if text(0..<4) == ".RMF" { return true }                                                      // RealMedia
        if bytes[0..<4].elementsEqual([0x00, 0x00, 0x01, 0xBA]) { return true }                       // MPEG program stream
        return false
    }

    /// Whether a link names such a file, for addresses whose bytes aren't read before playing.
    public static func handles(name: String) -> Bool {
        ["mkv", "webm", "avi", "flv", "f4v", "wmv", "asf", "rm", "rmvb", "mpg", "mpeg", "vob", "divx", "xvid"]
            .contains((name as NSString).pathExtension.lowercased())
    }

    /// Whether repackaging shows a picture AVPlayer can't decode in the file itself, from its sample entries:
    /// HEVC that an MP4 tags `hev1` (`dvhe`) plays inside HLS as it is, and VP9 and ByteVC2 (`bvc2`, Hongguo, #957)
    /// are converted. AV1 isn't, as FFmpeg here has no decoder for it.
    public static func showsPicture(_ codecs: [String]) -> Bool {
        !codecs.isEmpty && codecs.allSatisfy { ["hev1", "dvhe", "vp09", "bvc2"].contains($0) }
    }

    /// A link that answers no byte ranges at all.
    public struct NoByteRanges: LocalizedError {
        public var errorDescription: String? { "no byte ranges" }
    }

    /// The ASS/SSA tracks of a repackaged file: none, without a repackager.
    public static func styledSubtitles(_ url: URL) -> [StyledSubtitleEvents] { [] }
}

/// One file played through the repackager.
public protocol RemuxSource: Sendable {
    var length: Int64 { get }
    /// Up to `count` bytes at `offset` (fewer is fine, none only at the end).
    func read(at offset: Int64, count: Int) async throws -> Data
    /// Bytes received so far and from where, for the player's speed readout; nil for a local file.
    var transfer: (received: Int64, host: String?)? { get }
    /// The file's length in seconds, once the repackager has read its header (#702): a cloud file sizes its read-ahead from it.
    func learned(duration seconds: Double) async
    func close() async
}

extension RemuxSource {
    public func learned(duration seconds: Double) async {}
}

final class RangeConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let configuration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        // A plugin's proxy first asks its drive for a download address: seconds before the first byte.
        configuration.timeoutIntervalForRequest = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return configuration
    }()
    /// About two seconds of a drive's speed ahead, and what FFmpeg may jump back over: at most 16 MB each.
    static let ahead = 8 << 20
    static let behind: Int64 = 4 << 20

    let first: Int64
    /// The response's last byte and the file's length, from its Content-Range.
    private(set) var last: Int64 = 0
    private(set) var length: Int64 = 0
    private let counter: CloudCounter
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var opening: CheckedContinuation<Void, Error>?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// The file offset of `buffer`'s first byte, and the furthest offset handed out.
    private var base: Int64
    private var position: Int64
    private var buffer = Data()
    private var finished = false
    private var paused = false

    private init(first: Int64, counter: CloudCounter) {
        self.first = first; self.counter = counter
        base = first; position = first
    }

    /// The response to `Range: bytes=<from>-<through>`, once its headers say which bytes follow.
    static func open(_ url: URL, headers: [String: String], from first: Int64, through last: Int64? = nil,
                     configuration: URLSessionConfiguration, counter: CloudCounter) async throws -> RangeConnection {
        let connection = RangeConnection(first: first, counter: counter)
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=\(first)-\(last.map(String.init) ?? "")", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let session = URLSession(configuration: configuration, delegate: connection, delegateQueue: nil)
                let task = session.dataTask(with: request)
                let cancelled = connection.lock.withLock {
                    if connection.finished { return true }
                    connection.opening = continuation; connection.session = session; connection.task = task
                    return false
                }
                if cancelled { session.invalidateAndCancel(); continuation.resume(throwing: CancellationError()) }
                else { task.resume() }
            }
        } onCancel: { connection.close() }
        return connection
    }

    /// Up to `count` bytes at `offset`, waiting for them while they are on their way (within `readThrough`
    /// of what arrived). Nil when this response can't supply them: the caller opens another.
    func read(at offset: Int64, count: Int, readThrough: Int64) async throws -> Data? {
        enum Step { case data(Data), elsewhere, wait }
        while true {
            try Task.checkCancellation()
            var resume: URLSessionDataTask?
            let step: Step = lock.withLock {
                let end = base + Int64(buffer.count)
                guard offset >= base, offset <= last, offset <= max(end, position) + readThrough else { return .elsewhere }
                if offset < end {
                    let start = buffer.startIndex + Int(offset - base)
                    let data = Data(buffer[start..<min(buffer.endIndex, start + count)])
                    position = max(position, offset + Int64(data.count))
                    // Drop what lies well behind the reader, keeping `behind` for jumps back.
                    let keep = position - Self.behind
                    if keep - base > Self.behind {
                        buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + Int(keep - base))
                        base = keep
                    }
                    if paused, base + Int64(buffer.count) - position < Int64(Self.ahead / 2) { paused = false; resume = task }
                    return .data(data)
                }
                if finished { return .elsewhere }
                // The reader skips ahead to `offset`: what arrives before it no longer counts as read-ahead.
                position = max(position, offset)
                if paused { paused = false; resume = task }
                return .wait
            }
            resume?.resume()
            switch step {
            case .data(let data): return data
            case .elsewhere: return nil
            case .wait: await arrival(beyond: offset)
            }
        }
    }

    /// Returns once bytes past `offset` arrived, the response ended, or the read was cancelled.
    private func arrival(beyond offset: Int64) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = lock.withLock {
                    if finished || base + Int64(buffer.count) > offset || Task.isCancelled { return true }
                    waiters[id] = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.resume()
        }
    }

    func close() {
        let session = lock.withLock {
            finished = true
            return self.session
        }
        session?.invalidateAndCancel()
        end(CancellationError())
    }

    private func end(_ error: Error?) {
        let (opening, waiters): (CheckedContinuation<Void, Error>?, [CheckedContinuation<Void, Never>]) = lock.withLock {
            finished = true
            defer { self.opening = nil; self.waiters = [:] }
            return (self.opening, Array(self.waiters.values))
        }
        opening?.resume(throwing: error ?? TVError.unsupported("no response"))
        waiters.forEach { $0.resume() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")
        guard status == 206, let match = range?.firstMatch(of: /^bytes (\d+)-(\d+)\/(\d+)$/), Int64(match.1) == first,
              let end = Int64(match.2), let total = Int64(match.3), end < total else {
            completionHandler(.cancel)
            self.end(status >= 400 ? TVError.http(status) : Remux.NoByteRanges())
            return
        }
        let opening = lock.withLock {
            last = end; length = total
            defer { self.opening = nil }
            return self.opening
        }
        completionHandler(.allow)
        opening?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        counter.add(data.count)
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            buffer.append(data)
            if !paused, base + Int64(buffer.count) - position > Int64(Self.ahead) { paused = true; dataTask.suspend() }
            defer { self.waiters = [:] }
            return Array(self.waiters.values)
        }
        waiters.forEach { $0.resume() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        end(error)
        session.finishTasksAndInvalidate()
    }
}

struct CloudRemuxSource: RemuxSource {
    let stream: CloudByteStream
    let length: Int64
    init(stream: CloudByteStream) {
        self.stream = stream
        length = Int64(stream.sourceLength)
    }
    func read(at offset: Int64, count: Int) async throws -> Data { try await stream.read(at: Int(offset), count: count) }
    var transfer: (received: Int64, host: String?)? { (stream.counter.value, stream.host) }
    func learned(duration seconds: Double) async { await stream.setDuration(seconds) }
    func close() async { await stream.clear() }
}
