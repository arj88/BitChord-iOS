# BitChord for iOS

A native SwiftUI port of [BitChord](https://github.com/kushagrasinghx/BitChord), the aesthetic YouTube Music client.
It reuses BitChord's design (Apple Music look: dark theme, frosted bars, artwork-coloured player)
and ports its YouTube Music (InnerTube) client, parser, stream resolver and lyrics providers to Swift.

> BitChord is not affiliated with, endorsed by, or connected to YouTube or Google.

## What's in it

| Area | Features |
|---|---|
| Browse | Home feed with mood chips and infinite scroll, Quick picks grid, Explore (new releases, charts, trending, moods & genres), shelf "More" pages |
| Search | Live suggestions, recent searches, filters (All / Songs / Videos / Albums / Artists / Playlists / Podcasts), top result |
| Pages | Albums, singles, playlists (paged), artists (top songs, releases, videos, about), podcasts |
| Playback | Background audio, lock screen and Control Center controls, AirPlay, gapless hand-off, **crossfade 0–12 s**, volume normalisation, speed 0.5–2×, sleep timer / stop after track, shuffle, repeat, radio autoplay, queue editing (drag, swipe, play next/last), queue restored on launch |
| Lyrics | Word-synced (BetterLyrics, Apple Music TTML, with duet and background vocals), line-synced (LRCLIB), plain (YouTube Music); Apple-style animated view, tap a line to seek |
| Library | Liked songs, local playlists, saved albums/playlists/artists, history, **offline downloads**, imported audio files (MP3/M4A/FLAC/WAV/ALAC), audio cache |
| Accounts | Google sign-in (personal Home, YouTube library, liked-songs sync, likes and subscriptions written back), Last.fm and ListenBrainz scrobbling, Discord Rich Presence |
| Look | Animated mesh-gradient background from artwork colours (iOS 18), stats for nerds, light/dark/system theme |

Android-only features that iOS doesn't allow or that need native code from the Android app
(USB bit-perfect output, system equalizer, Automix beat-matching models, Android Auto, Wear OS,
SMB/WebDAV sources, Listen Together server, Spotify canvas) aren't included.

## Build the .ipa without a Mac (GitHub Actions)

iPhone apps can only be compiled on macOS, so this project includes a workflow that builds on
GitHub's free Mac machines.

1. Create a new repository on GitHub (it can be private).
2. Upload **the contents of this folder** to it, including the hidden `.github` folder.
   The easiest way on Windows is GitHub Desktop: *File → Add local repository* → choose this
   folder → *Publish repository*. (Dragging files into the GitHub website can skip `.github`.)
3. On GitHub, open the **Actions** tab. The *Build iOS app* workflow starts on every push
   (or click *Run workflow*). It takes about 5–10 minutes.
4. When it finishes, open the run and download the **BitChord-ipa** artifact. Unzip it to get
   `BitChord.ipa`.

If the build fails, open the failed step called *Show compiler errors* and copy the errors.

## Install on your iPhone from Windows

The .ipa is unsigned, so it needs to be signed with your Apple ID when you install it.

**Sideloadly (simplest):**
1. Install iTunes (the version from apple.com, not the Microsoft Store one) and
   [Sideloadly](https://sideloadly.io).
2. Connect the iPhone by USB and tap *Trust This Computer*.
3. Drag `BitChord.ipa` into Sideloadly, enter your Apple ID, click *Start*.
4. On the iPhone: *Settings → General → VPN & Device Management* → trust your Apple ID.
5. On iOS 16 and later, also turn on *Settings → Privacy & Security → Developer Mode*.

With a free Apple ID the app must be re-signed every 7 days (just run Sideloadly again;
your library is kept). AltStore can refresh it automatically over Wi-Fi.

## Build on a Mac instead

```bash
brew install xcodegen
xcodegen generate
open BitChord.xcodeproj
```

Pick your team under *Signing & Capabilities*, connect the iPhone, and press Run.
Requires Xcode 16 or newer; the app runs on iOS 17 and later.

## Project layout

```
BitChord/
  Core/       YouTube Music client, parser, stream resolver, lyrics, scrobbling (Foundation only)
  Playback/   AVPlayer engine, chunked stream loader, audio cache, local file tags
  App/        App entry, settings, library store, account
  UI/         SwiftUI screens
project.yml   XcodeGen project definition
```
