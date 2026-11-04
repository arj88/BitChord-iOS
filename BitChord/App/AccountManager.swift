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
        if account != nil { await syncLikes() }
    }

    /// Called by the login web view once Google has handed back to music.youtube.com.
    func signIn(cookies: [HTTPCookie]) async {
        // Only what a browser would send to music.youtube.com: cookies set for
        // youtube.com or music.youtube.com, never Google's own accounts cookies.
        let host = "music.youtube.com"
        let applicable = cookies.filter { c in
            let domain = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            return host == domain || host.hasSuffix("." + domain)
        }
        var seen = Set<String>()
        var parts: [String] = []
        // The most specific domain wins when a name is set twice.
        for c in applicable.sorted(by: { $0.domain.count > $1.domain.count }) where seen.insert(c.name).inserted {
            parts.append("\(c.name)=\(c.value)")
        }
        let header = parts.joined(separator: "; ")
        guard InnerTube.sapisid(from: header) != nil else {
            lastError = "Sign-in didn't finish — no YouTube session cookie was found. Try again."
            return
        }
        lastError = nil
        InnerTube.shared.cookie = header
        Keychain.set(header, for: "ytm_cookie")
        await refreshProfile()
        if account != nil { await syncLikes() }
    }

    func signOut() async {
        InnerTube.shared.cookie = nil
        Keychain.set(nil, for: "ytm_cookie")
        account = nil
        lastError = nil
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
    }

    func refreshProfile() async {
        guard isSignedIn else { return }
        let scope = await InnerTube.shared.ensureSessionScope(force: true)
        if scope?.loggedIn == false {
            account = nil
            lastError = "YouTube didn't accept this sign-in. Sign out and sign in again."
            return
        }
        do {
            account = try await YTMusic.account()
            lastError = account == nil ? "Signed in, but YouTube Music didn't return a profile. Sign out and sign in again." : nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    @ObservationIgnored private var lastLikeSync = Date.distantPast

    /// Pulls the account's Liked Music so likes made on other devices show up here.
    /// - Parameter force: skip the five-minute throttle (pull-to-refresh, the sync button).
    func syncLikes(force: Bool = true) async {
        guard isSignedIn, !isSyncing else { return }
        if !force && Date().timeIntervalSince(lastLikeSync) < 300 { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let songs = try await YTMusic.likedSongs()
            let key = "likesSynced:" + (account?.handle ?? account?.name ?? "account")
            let first = !UserDefaults.standard.bool(forKey: key)
            LibraryStore.shared.syncLiked(from: songs, firstSync: first)
            UserDefaults.standard.set(true, forKey: key)
            lastLikeSync = Date()
        } catch {
            lastError = "Couldn't sync liked songs: \(error.localizedDescription)"
        }
    }
}
