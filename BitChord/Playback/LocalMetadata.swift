import AVFoundation
import Foundation

/// Tags embedded in an imported audio file.
struct LocalMetadata {
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
    var artwork: Data?

    static func read(_ url: URL) async -> LocalMetadata {
        let asset = AVURLAsset(url: url)
        var meta = LocalMetadata()
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite && seconds > 0 { meta.duration = seconds }
        }
        let items = (try? await asset.load(.commonMetadata)) ?? []
        for item in items {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle: meta.title = try? await item.load(.stringValue)
            case .commonKeyArtist: meta.artist = try? await item.load(.stringValue)
            case .commonKeyAlbumName: meta.album = try? await item.load(.stringValue)
            case .commonKeyArtwork: meta.artwork = try? await item.load(.dataValue)
            default: break
            }
        }
        if let art = meta.artwork {
            let artURL = url.deletingPathExtension().appendingPathExtension("artwork.jpg")
            try? art.write(to: artURL)
        }
        return meta
    }

    static func artworkURL(for song: Song) -> URL? {
        guard let name = song.localFile else { return nil }
        let url = LibraryStore.importsDirectory.appendingPathComponent(name).deletingPathExtension().appendingPathExtension("artwork.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
