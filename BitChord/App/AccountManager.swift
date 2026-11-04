import Foundation
import Observation
import WebKit

/// The signed-in YouTube Music account: its cookie, profile and library.
@MainActor
@Observable
final class AccountManager {
    static let shared = AccountManager()

    private(set) var account: AccountInfo?
    private(set) var isSyncing = false
    var lastError: String?

    var isSignedIn: Bool { InnerTube.shared.isSignedIn }

    private init() {}

    func restore() async {
        guard let cookie = Keychain.get("ytm_cookie") else { return }
        InnerTube.shared.cookie = cookie
        await refreshProfile()
    }

    /// Called by the login web view once Google has handed back to music.youtube.com.
    func signIn(cookies: [HTTPCookie]) async {
        let relevant = cookies.filter { $0.domain.contains("youtube.com") || $0.domain.contains("google.com") }
        var seen = Set<String>()
        var parts: [String] = []
        // youtube.com cookies win over google.com ones of the same name.
        for c in relevant.sorted(by: { $0.domain.contains("youtube.com") && !$1.domain.contains("youtube.com") }) where seen.insert(c.name).inserted {
            parts.append("\(c.name)=\(c.value)")
        }
        let header = parts.joined(separator: "; ")
        guard header.contains("SAPISID") else {
            lastError = "Sign-in didn't finish — no YouTube session cookie was found."
            return
        }
        InnerTube.shared.cookie = header
        Keychain.set(header, for: "ytm_cookie")
        await refreshProfile()
        await syncLikes()
    }

    func signOut() async {
        InnerTube.shared.cookie = nil
        Keychain.set(nil, for: "ytm_cookie")
        account = nil
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
    }

    func refreshProfile() async {
        do {
            account = try await YTMusic.account()
            if account == nil { lastError = "Signed in, but YouTube Music didn't return a profile." }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Pulls the account's Liked Music into the local likes.
    func syncLikes() async {
        guard isSignedIn, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        if let songs = try? await YTMusic.likedSongs() {
            LibraryStore.shared.mergeLiked(songs)
        }
    }
}
