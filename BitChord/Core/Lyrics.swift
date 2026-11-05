import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

struct LyricWord: Hashable, Codable {
    var start: Double
    var end: Double
    var text: String
}

struct LyricLine: Hashable, Codable, Identifiable {
    var start: Double
    var end: Double
    var text: String
    var words: [LyricWord] = []
    var background: [LyricWord] = []
    /// Duet lines sung by the second voice are drawn on the trailing edge.
    var alignEnd = false
    var id: String { "\(start)-\(text)" }
    var isWordSynced: Bool { !words.isEmpty }
}

struct Lyrics: Codable {
    enum Kind: String, Codable { case wordSynced, lineSynced, plain }
    var kind: Kind
    var lines: [LyricLine]
    var source: String

    var plainText: String { lines.map(\.text).joined(separator: "\n") }
}

enum LyricsProvider: String, CaseIterable, Codable, Identifiable {
    case betterLyrics = "BetterLyrics"
    case lrclib = "LRCLIB"
    case youtube = "YouTube Music"
    var id: String { rawValue }
}

/// Fetches lyrics from the same key-less providers BitChord uses, best timing first.
enum LyricsService {
    static let agent = "FYT-iOS (https://github.com/arj88/FYT)"

    static func fetch(for song: Song, duration: Double?, lyricsBrowseId: String?,
                      providers: [LyricsProvider] = LyricsProvider.allCases) async -> Lyrics? {
        let title = cleanTitle(song.title)
        let artist = song.primaryArtist
        let seconds = Int(duration ?? song.durationSeconds ?? 0)
        var plainFallback: Lyrics?
        for provider in providers {
            if Task.isCancelled { return nil }
            var result: Lyrics?
            switch provider {
            case .betterLyrics:
                result = await betterLyrics(title: title, artist: artist, seconds: seconds, album: song.albumName)
            case .lrclib:
                result = await lrclib(title: title, artist: artist, album: song.albumName, seconds: seconds)
            case .youtube:
                result = await youtube(videoId: song.videoId, browseId: lyricsBrowseId)
            }
            if let r = result, !r.lines.isEmpty {
                if r.kind == .plain { if plainFallback == nil { plainFallback = r }; continue }
                return r
            }
        }
        return plainFallback
    }

    static func cleanTitle(_ title: String) -> String {
        var t = title
        for pattern in ["\\s*[\\(\\[](official|lyric|lyrics|audio|video|visualizer|4k|hd|remaster)[^\\)\\]]*[\\)\\]]",
                        "\\s*-\\s*(official|lyric).*$"] {
            t = t.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await InnerTube.shared.session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    // MARK: Providers

    static func betterLyrics(title: String, artist: String, seconds: Int, album: String?) async -> Lyrics? {
        var c = URLComponents(string: "https://lyrics-api.boidu.dev/getLyrics")!
        var q = [URLQueryItem(name: "s", value: title), URLQueryItem(name: "a", value: artist)]
        if seconds > 0 { q.append(URLQueryItem(name: "d", value: String(seconds))) }
        if let album, !album.isEmpty { q.append(URLQueryItem(name: "al", value: album)) }
        c.queryItems = q
        guard let url = c.url, let data = await get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? JObj,
              let ttml = json.s("ttml"), !ttml.isEmpty else { return nil }
        let lines = TTMLParser.parse(ttml)
        guard !lines.isEmpty else { return nil }
        return Lyrics(kind: lines.contains { $0.isWordSynced } ? .wordSynced : .lineSynced, lines: lines, source: "BetterLyrics")
    }

    static func lrclib(title: String, artist: String, album: String?, seconds: Int) async -> Lyrics? {
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        var q = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if let album, !album.isEmpty { q.append(URLQueryItem(name: "album_name", value: album)) }
        if seconds > 0 { q.append(URLQueryItem(name: "duration", value: String(seconds))) }
        c.queryItems = q
        var best: JObj?
        if let url = c.url, let data = await get(url), let json = try? JSONSerialization.jsonObject(with: data) as? JObj {
            best = json
        }
        if best?.s("syncedLyrics") == nil {
            var s = URLComponents(string: "https://lrclib.net/api/search")!
            s.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
            if let url = s.url, let data = await get(url), let list = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                let candidates = list.objects
                let synced = candidates.filter { $0.s("syncedLyrics") != nil }
                let pool = synced.isEmpty ? candidates : synced
                best = pool.min { a, b in
                    abs((a.double("duration") ?? 0) - Double(seconds)) < abs((b.double("duration") ?? 0) - Double(seconds))
                } ?? best
            }
        }
        guard let best else { return nil }
        if let synced = best.s("syncedLyrics") {
            let lines = LRCParser.parse(synced)
            if !lines.isEmpty { return Lyrics(kind: lines.contains { $0.isWordSynced } ? .wordSynced : .lineSynced, lines: lines, source: "LRCLIB") }
        }
        if let plain = best.s("plainLyrics"), !plain.isEmpty {
            return Lyrics(kind: .plain, lines: plainLines(plain), source: "LRCLIB")
        }
        return nil
    }

    static func youtube(videoId: String, browseId: String?) async -> Lyrics? {
        var id = browseId
        if id == nil, let next = try? await InnerTube.shared.next(videoId: videoId, playlistId: nil) {
            id = Parser.watchNext(next).lyricsBrowseId
        }
        guard let id, let json = try? await InnerTube.shared.browse(id),
              let found = Parser.lyrics(json) else { return nil }
        return Lyrics(kind: .plain, lines: plainLines(found.text), source: found.source ?? "YouTube Music")
    }

    static func plainLines(_ text: String) -> [LyricLine] {
        text.components(separatedBy: .newlines).map { LyricLine(start: -1, end: -1, text: $0.trimmingCharacters(in: .whitespaces)) }
    }
}

/// `[mm:ss.xx]` line-synced lyrics, including enhanced `<mm:ss.xx>` word stamps.
enum LRCParser {
    static func time(_ s: Substring) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p.replacingOccurrences(of: ",", with: ".")) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    static func parse(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let stamp = try! NSRegularExpression(pattern: "\\[(\\d{1,3}:\\d{1,2}(?:[.,:]\\d{1,3})?)\\]")
        let wordStamp = try! NSRegularExpression(pattern: "<(\\d{1,3}:\\d{1,2}(?:[.,]\\d{1,3})?)>")
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = stamp.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty, let last = matches.last else { continue }
            var body = ns.substring(from: last.range.location + last.range.length)
            var words: [LyricWord] = []
            let wordMatches = wordStamp.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length))
            if !wordMatches.isEmpty {
                let b = body as NSString
                for (i, m) in wordMatches.enumerated() {
                    let start = time(Substring(b.substring(with: m.range(at: 1)))) ?? 0
                    let textStart = m.range.location + m.range.length
                    let textEnd = i + 1 < wordMatches.count ? wordMatches[i + 1].range.location : b.length
                    let w = b.substring(with: NSRange(location: textStart, length: max(0, textEnd - textStart)))
                    if !w.trimmingCharacters(in: .whitespaces).isEmpty { words.append(LyricWord(start: start, end: start, text: w)) }
                }
                for i in words.indices { words[i].end = i + 1 < words.count ? words[i + 1].start : words[i].start + 0.6 }
                body = wordStamp.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: (body as NSString).length), withTemplate: "")
            }
            for m in matches {
                if let t = time(Substring(ns.substring(with: m.range(at: 1)))) {
                    lines.append(LyricLine(start: t, end: t, text: body.trimmingCharacters(in: .whitespaces), words: words))
                }
            }
        }
        lines.sort { $0.start < $1.start }
        for i in lines.indices {
            lines[i].end = i + 1 < lines.count ? lines[i + 1].start : lines[i].start + 5
        }
        return lines
    }
}

/// Apple Music-style TTML (word or line timed).
final class TTMLParser: NSObject, XMLParserDelegate {
    private var lines: [LyricLine] = []
    private var current: LyricLine?
    private var spanStack: [(begin: Double?, end: Double?, background: Bool)] = []
    private var text = ""
    private var pendingSpace = false
    private var agents: [String: Int] = [:]

    static func parse(_ ttml: String) -> [LyricLine] {
        guard let data = ttml.data(using: .utf8) else { return [] }
        let delegate = TTMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        _ = parser.parse()
        return delegate.lines.filter { !$0.text.isEmpty || !$0.background.isEmpty }
    }

    static func time(_ value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        var v = value
        if v.hasSuffix("ms") { return Double(v.dropLast(2)).map { $0 / 1000 } }
        if v.hasSuffix("s") { v.removeLast() }
        let parts = v.split(separator: ":")
        var total = 0.0
        for p in parts { guard let d = Double(p) else { return nil }; total = total * 60 + d }
        return total
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        if name == "agent", let id = attributes["xml:id"] {
            agents[id] = agents.count
        } else if name == "p" {
            let begin = Self.time(attributes["begin"]) ?? 0
            let end = Self.time(attributes["end"]) ?? begin
            let agent = attributes["ttm:agent"]
            let alignEnd = agent.map { (agents[$0] ?? 0) % 2 == 1 } ?? false
            current = LyricLine(start: begin, end: end, text: "", alignEnd: alignEnd)
            text = ""
        } else if name == "span", current != nil {
            flushText(inside: spanStack.last)
            let bg = attributes["ttm:role"] == "x-bg" || (spanStack.last?.background ?? false)
            spanStack.append((Self.time(attributes["begin"]), Self.time(attributes["end"]), bg))
        } else if name == "br" {
            text += " "
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard current != nil else { return }
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        if name == "span", current != nil {
            let span = spanStack.popLast()
            flushText(inside: span)
        } else if name == "p", var line = current {
            flushText(inside: nil)
            line.text = line.words.isEmpty ? line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                : line.words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            lines.append(line)
            current = nil
        }
    }

    /// Commits text collected so far to the word list (when inside a timed span) or the plain line text.
    private func flushText(inside span: (begin: Double?, end: Double?, background: Bool)?) {
        guard var line = current else { text = ""; return }
        let raw = text
        text = ""
        if raw.isEmpty { return }
        if let span, let begin = span.begin {
            let leading = raw.first?.isWhitespace == true
            var word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if word.isEmpty { pendingSpace = true; current = line; return }
            let target = span.background ? line.background : line.words
            if (leading || pendingSpace) && !target.isEmpty { word = " " + word }
            if raw.last?.isWhitespace == true { pendingSpace = true } else { pendingSpace = false }
            let w = LyricWord(start: begin, end: span.end ?? begin, text: word)
            if span.background {
                line.background.append(w)
            } else {
                line.words.append(w)
            }
        } else {
            if raw.contains(where: { !$0.isWhitespace }) {
                line.text += raw
            } else if !line.words.isEmpty || !line.text.isEmpty {
                pendingSpace = true
            }
        }
        current = line
    }
}
