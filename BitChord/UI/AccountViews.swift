import SwiftUI
import WebKit

/// A WKWebView that reports each finished navigation, used for the Google and Discord sign-ins.
struct WebLogin: UIViewRepresentable {
    let url: URL
    var onFinish: (WKWebView, URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        // A plain Safari identity; Google refuses sign-ins from agents that look embedded.
        view.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onFinish: (WKWebView, URL?) -> Void
        init(onFinish: @escaping (WKWebView, URL?) -> Void) { self.onFinish = onFinish }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinish(webView, webView.url)
        }
    }
}

struct YouTubeLoginView: View {
    @Environment(AccountManager.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    static let loginURL = URL(string: "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&prompt=select_account&continue=https%3A%2F%2Fmusic.youtube.com%2F")!

    var body: some View {
        NavigationStack {
            ZStack {
                WebLogin(url: Self.loginURL) { webView, url in
                    guard let host = url?.host, host == "music.youtube.com", !working else { return }
                    working = true
                    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                        Task { @MainActor in
                            await account.signIn(cookies: cookies)
                            if account.isSignedIn { dismiss() } else { working = false }
                        }
                    }
                }
                if working { ProgressView("Signing in…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
            }
            .navigationTitle("Sign in to YouTube Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct DiscordLoginView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var timer: Timer?

    private static let tokenScript = """
    (function () {
      try {
        var frame = document.createElement('iframe');
        document.body.appendChild(frame);
        var token = frame.contentWindow.localStorage.token;
        document.body.removeChild(frame);
        return token ? token.slice(1, -1) : '';
      } catch (e) { return ''; }
    })()
    """

    var body: some View {
        NavigationStack {
            WebLogin(url: URL(string: "https://discord.com/login")!) { webView, url in
                guard let path = url?.path, !path.contains("login"), !path.contains("register") else { return }
                poll(webView)
            }
            .navigationTitle("Log in to Discord")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onDisappear { timer?.invalidate() }
        }
    }

    private final class Counter { var value = 0 }

    private func poll(_ webView: WKWebView) {
        timer?.invalidate()
        let attempts = Counter()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            MainActor.assumeIsolated {
                attempts.value += 1
                if attempts.value > 20 { t.invalidate(); return }
                webView.evaluateJavaScript(Self.tokenScript) { result, _ in
                    guard let token = result as? String, token.count > 20 else { return }
                    t.invalidate()
                    Task { @MainActor in save(token) }
                }
            }
        }
    }

    @MainActor
    private func save(_ token: String) {
        settings.discordToken = token
        settings.discordEnabled = true
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let discord = records.filter { $0.displayName.contains("discord") }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: discord) {}
        }
        dismiss()
    }
}

struct LastFMLoginView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var secret = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("API key", text: $apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Shared secret", text: $secret)
                } header: { Text("API account") } footer: {
                    Text("Create a free API account at last.fm/api/account/create and paste its key and secret here.")
                }
                Section("Your Last.fm account") {
                    TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button {
                    working = true
                    Task {
                        do {
                            settings.lastFM = try await LastFM.login(apiKey: apiKey, secret: secret, username: username, password: password)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                        working = false
                    }
                } label: {
                    if working { ProgressView() } else { Text("Connect") }
                }
                .disabled(apiKey.isEmpty || secret.isEmpty || username.isEmpty || password.isEmpty || working)
            }
            .navigationTitle("Last.fm")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct ListenBrainzLoginView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("User token", text: $token)
                } footer: {
                    Text("Find your token at listenbrainz.org/settings.")
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button {
                    working = true
                    Task {
                        if let user = await ListenBrainz.validate(token: token) {
                            settings.listenBrainzToken = token
                            settings.listenBrainzUser = user
                            dismiss()
                        } else {
                            error = "That token wasn't accepted."
                        }
                        working = false
                    }
                } label: {
                    if working { ProgressView() } else { Text("Connect") }
                }
                .disabled(token.isEmpty || working)
            }
            .navigationTitle("ListenBrainz")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
