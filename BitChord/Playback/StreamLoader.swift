import AVFoundation
import Foundation

/// Feeds AVPlayer a googlevideo stream through `AVAssetResourceLoader`, so every
/// byte request carries the headers of the client that minted the URL and is cut
/// into ranges googlevideo serves at full speed (it throttles large ranges for
/// some clients). Chunks are kept in memory and, once the whole file has passed
/// through, written to the audio cache so replays and seeks cost nothing.
final class StreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "bitchord-stream"

    let videoId: String
    private var stream: ResolvedStream?
    private let lock = NSLock()
    private var chunks: [Int64: Data] = [:]
    private var totalLength: Int64?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var refreshed = false
    private var savedToCache = false
    let delegateQueue = DispatchQueue(label: "bitchord.streamloader")

    init(videoId: String, stream: ResolvedStream) {
        self.videoId = videoId
        self.stream = stream
        self.totalLength = stream.contentLength
    }

    var assetURL: URL { URL(string: "\(Self.scheme)://stream/\(videoId).m4a")! }

    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: assetURL)
        asset.resourceLoader.setDelegate(self, queue: delegateQueue)
        return asset
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let key = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self] in
            await self?.serve(loadingRequest)
            self?.removeTask(key)
        }
        lock.lock(); tasks[key] = task; lock.unlock()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(loadingRequest)
        lock.lock(); let task = tasks.removeValue(forKey: key); lock.unlock()
        task?.cancel()
    }

    private func removeTask(_ key: ObjectIdentifier) {
        lock.lock(); tasks[key] = nil; lock.unlock()
    }

    func cancelAll() {
        lock.lock(); let all = tasks.values; tasks.removeAll(); lock.unlock()
        all.forEach { $0.cancel() }
    }

    // MARK: Serving

    private func serve(_ request: AVAssetResourceLoadingRequest) async {
        do {
            let length = try await contentLength()
            if let info = request.contentInformationRequest {
                info.contentType = AVFileType.m4a.rawValue
                info.contentLength = length
                info.isByteRangeAccessSupported = true
            }
            if let dataRequest = request.dataRequest {
                var offset = dataRequest.currentOffset > 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
                let end: Int64 = dataRequest.requestsAllDataToEndOfResource
                    ? length
                    : min(length, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
                while offset < end {
                    try Task.checkCancellation()
                    let chunkSize = stream?.chunkSize ?? 512 * 1024
                    let chunkStart = (offset / chunkSize) * chunkSize
                    let chunk = try await chunk(at: chunkStart, size: chunkSize, total: length)
                    let from = Int(offset - chunkStart)
                    guard from < chunk.count else { break }
                    let to = Int(min(Int64(chunk.count), end - chunkStart))
                    dataRequest.respond(with: chunk.subdata(in: from..<to))
                    offset = chunkStart + Int64(to)
                }
            }
            request.finishLoading()
            saveIfComplete(total: length)
        } catch is CancellationError {
            // AVFoundation cancelled the request; nothing to report.
        } catch {
            if !request.isCancelled { request.finishLoading(with: error) }
        }
    }

    private func contentLength() async throws -> Int64 {
        lock.lock(); let known = totalLength; lock.unlock()
        if let known { return known }
        // No clen in the URL: ask for one byte and read the total off Content-Range.
        let (_, response) = try await fetch(range: 0...0)
        guard let range = response.value(forHTTPHeaderField: "Content-Range"),
              let total = range.split(separator: "/").last.flatMap({ Int64($0) }) else {
            throw StreamError.noAudio
        }
        lock.lock(); totalLength = total; lock.unlock()
        return total
    }

    private func chunk(at start: Int64, size: Int64, total: Int64) async throws -> Data {
        lock.lock(); let cached = chunks[start]; lock.unlock()
        if let cached { return cached }
        let end = min(total, start + size) - 1
        let (data, _) = try await fetch(range: start...end)
        lock.lock(); chunks[start] = data; lock.unlock()
        return data
    }

    private func fetch(range: ClosedRange<Int64>) async throws -> (Data, HTTPURLResponse) {
        guard let stream else { throw StreamError.noAudio }
        var components = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "range" }
        components.queryItems = items
        var request = URLRequest(url: components.url ?? stream.url)
        request.timeoutInterval = 20
        for (k, v) in stream.headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        let (data, response) = try await StreamLoader.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StreamError.noAudio }
        if http.statusCode == 403 || http.statusCode == 410 {
            // The URL expired or was refused; mint a fresh one once and retry.
            if !refreshed {
                refreshed = true
                StreamResolver.shared.invalidate(videoId)
                self.stream = try await StreamResolver.shared.resolve(videoId, forceFresh: true)
                return try await fetch(range: range)
            }
            throw StreamError.unplayable("YouTube refused the stream (HTTP \(http.statusCode))")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw StreamError.unplayable("Stream request failed (HTTP \(http.statusCode))")
        }
        return (data, http)
    }

    private func saveIfComplete(total: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard !savedToCache, let size = stream?.chunkSize else { return }
        let needed = Int((total + size - 1) / size)
        guard chunks.count >= needed else { return }
        var file = Data(capacity: Int(total))
        var offset: Int64 = 0
        while offset < total {
            guard let c = chunks[offset] else { return }
            file.append(c)
            offset += size
        }
        savedToCache = true
        AudioCache.store(file, for: videoId)
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Downloads the whole stream to a file (used by offline downloads).
    static func download(videoId: String, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        var stream = try await StreamResolver.shared.resolve(videoId)
        if stream.isHLS { throw StreamError.unplayable("This track can only be streamed") }
        let loader = StreamLoader(videoId: videoId, stream: stream)
        let total = try await loader.contentLength()
        stream = loader.stream ?? stream
        var data = Data(capacity: Int(total))
        var offset: Int64 = 0
        while offset < total {
            try Task.checkCancellation()
            let piece = try await loader.chunk(at: offset, size: stream.chunkSize, total: total)
            data.append(piece)
            offset += Int64(piece.count)
            progress(Double(offset) / Double(total))
            if piece.isEmpty { break }
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }
}

/// Fully streamed tracks, kept so a replay doesn't touch the network.
enum AudioCache {
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("audio", isDirectory: true)
    }
    static var limitBytes: Int64 = 1024 * 1024 * 1024

    static func url(for videoId: String) -> URL? {
        let u = directory.appendingPathComponent("\(videoId).m4a")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func store(_ data: Data, for videoId: String) {
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("\(videoId).m4a"), options: .atomic)
            trim()
        }
    }

    static func size() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey]
        var files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        var total = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard total > limitBytes else { return }
        files.sort {
            let a = (try? $0.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast
            return a < b
        }
        for f in files where total > limitBytes {
            total -= Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? FileManager.default.removeItem(at: f)
        }
    }
}
