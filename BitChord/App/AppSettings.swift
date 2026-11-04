import Foundation
import Observation
import Security
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System", dark = "Dark", light = "Light"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

enum RepeatMode: String, Codable { case off, all, one }

/// User preferences, persisted in UserDefaults (secrets in the Keychain).
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    var appearance: AppearanceMode { didSet { d.set(appearance.rawValue, forKey: "appearance") } }
    var quality: AudioQuality { didSet { d.set(quality.rawValue, forKey: "quality"); StreamResolver.shared.quality = quality } }
    var downloadQuality: AudioQuality { didSet { d.set(downloadQuality.rawValue, forKey: "downloadQuality") } }
    var automix: Bool { didSet { d.set(automix, forKey: "automix") } }
    var automixBeats: Int { didSet { d.set(automixBeats, forKey: "automixBeats") } }
    var crossfade: Double { didSet { d.set(crossfade, forKey: "crossfade") } }
    var normalize: Bool { didSet { d.set(normalize, forKey: "normalize") } }
    var autoplay: Bool { didSet { d.set(autoplay, forKey: "autoplay") } }
    var preferAudioVersions: Bool { didSet { d.set(preferAudioVersions, forKey: "preferAudio") } }
    var dynamicColors: Bool { didSet { d.set(dynamicColors, forKey: "dynamicColors") } }
    var animatedBackground: Bool { didSet { d.set(animatedBackground, forKey: "animatedBackground") } }
    var lyricsProviders: [LyricsProvider] { didSet { d.set(lyricsProviders.map(\.rawValue), forKey: "lyricsProviders") } }
    var lyricsFontScale: Double { didSet { d.set(lyricsFontScale, forKey: "lyricsFontScale") } }
    var cacheLimitMB: Int { didSet { d.set(cacheLimitMB, forKey: "cacheLimitMB"); AudioCache.limitBytes = Int64(cacheLimitMB) * 1024 * 1024 } }
    var showNerdStats: Bool { didSet { d.set(showNerdStats, forKey: "nerdStats") } }
    var contentRegion: String { didSet { d.set(contentRegion, forKey: "region"); InnerTube.shared.region = contentRegion } }
    var pauseHistory: Bool { didSet { d.set(pauseHistory, forKey: "pauseHistory") } }

    var listenBrainzToken: String? { didSet { Keychain.set(listenBrainzToken, for: "listenbrainz") } }
    var listenBrainzUser: String? { didSet { d.set(listenBrainzUser, forKey: "lbUser") } }
    var lastFM: LastFM.Config? {
        didSet {
            Keychain.set(lastFM.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }, for: "lastfm")
        }
    }
    var discordToken: String? { didSet { Keychain.set(discordToken, for: "discord") } }
    var discordEnabled: Bool { didSet { d.set(discordEnabled, forKey: "discordEnabled") } }

    private init() {
        appearance = AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .dark
        quality = AudioQuality(rawValue: d.string(forKey: "quality") ?? "") ?? .high
        downloadQuality = AudioQuality(rawValue: d.string(forKey: "downloadQuality") ?? "") ?? .opus
        automix = d.bool(forKey: "automix")
        automixBeats = d.object(forKey: "automixBeats") as? Int ?? 16
        crossfade = d.object(forKey: "crossfade") as? Double ?? 0
        normalize = d.object(forKey: "normalize") as? Bool ?? true
        autoplay = d.object(forKey: "autoplay") as? Bool ?? true
        preferAudioVersions = d.object(forKey: "preferAudio") as? Bool ?? true
        dynamicColors = d.object(forKey: "dynamicColors") as? Bool ?? true
        animatedBackground = d.object(forKey: "animatedBackground") as? Bool ?? true
        let providers = (d.stringArray(forKey: "lyricsProviders") ?? []).compactMap(LyricsProvider.init(rawValue:))
        lyricsProviders = providers.isEmpty ? LyricsProvider.allCases : providers
        lyricsFontScale = d.object(forKey: "lyricsFontScale") as? Double ?? 1
        cacheLimitMB = d.object(forKey: "cacheLimitMB") as? Int ?? 1024
        showNerdStats = d.bool(forKey: "nerdStats")
        contentRegion = d.string(forKey: "region") ?? InnerTube.shared.region
        pauseHistory = d.bool(forKey: "pauseHistory")
        listenBrainzToken = Keychain.get("listenbrainz")
        listenBrainzUser = d.string(forKey: "lbUser")
        lastFM = Keychain.get("lastfm").flatMap { try? JSONDecoder().decode(LastFM.Config.self, from: Data($0.utf8)) }
        discordToken = Keychain.get("discord")
        discordEnabled = d.bool(forKey: "discordEnabled")

        StreamResolver.shared.quality = quality
        AudioCache.limitBytes = Int64(cacheLimitMB) * 1024 * 1024
        InnerTube.shared.region = contentRegion
    }
}

/// Minimal Keychain wrapper for tokens and cookies.
enum Keychain {
    static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "bitchord",
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "bitchord",
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
