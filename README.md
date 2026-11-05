# FYT

A native SwiftUI YouTube Music client for iPhone, with an Apple Music look: dark theme,
frosted bars and an artwork-coloured player.

Created by **Lucky Raj**.

> FYT is not affiliated with, endorsed by, or connected to YouTube or Google.

## Features

| Area | Features |
|---|---|
| Browse | Home feed with mood chips and infinite scroll, Quick picks, Explore (new releases, charts, trending, moods & genres) |
| Search | Live suggestions, recent searches, filters (Songs / Videos / Albums / Artists / Playlists / Podcasts), top result |
| Pages | Albums, singles, playlists, artists (top songs, releases, videos, about), podcasts |
| Playback | Background audio, lock screen and Control Center controls, gapless playback, crossfade, **Automix beat-matching**, volume normalisation, speed 0.5–2×, sleep timer, shuffle, repeat, radio autoplay, queue editing, queue restored on launch |
| Audio quality | Opus ~160 kbps, AAC 128 kbps, AAC 256 kbps (YouTube Music Premium); separate download quality |
| Output | AirPlay & Bluetooth, **Google Cast** to Android TV / Google TV / Chromecast |
| Listen Together | Shared listening parties with invite links, synced playback and a shared queue |
| Lyrics | Word-synced, line-synced and plain lyrics with an animated view; tap a line to seek |
| Library | Liked songs, playlists, saved albums/artists, history, **offline downloads** (one tap for a whole playlist), imported audio files, audio cache |
| YouTube account | Google sign-in: personal Home, your playlists (create, rename, reorder, edit), liked-songs sync, listening history |
| Scrobbling | Last.fm, ListenBrainz, Discord Rich Presence |
| Look | Animated mesh-gradient background, light/dark/system theme, accent colour (presets or any hex code), 7 app icons, stats for nerds |

## Build the .ipa without a Mac (GitHub Actions)

iPhone apps can only be compiled on macOS, so the included workflow builds on GitHub's Mac machines.

1. Push this repository to GitHub (including the hidden `.github` folder).
2. The **Build iOS app** workflow runs on every push (or use *Run workflow* in the Actions tab).
3. When it finishes, `FYT.ipa` is attached to a new release under **Releases**, and also
   available as the **FYT-ipa** artifact on the run.

If a build fails, open the step called *Show compiler errors*.

## Install on your iPhone

The .ipa is unsigned, so it has to be signed when you install it, for example with
[Sideloadly](https://sideloadly.io) from Windows or a signing service such as Signulous.

**Sideloadly:**
1. Install iTunes (from apple.com, not the Microsoft Store) and Sideloadly.
2. Connect the iPhone by USB and tap *Trust This Computer*.
3. Drag `FYT.ipa` into Sideloadly, enter your Apple ID and click *Start*.
4. On the iPhone: *Settings → General → VPN & Device Management* → trust your Apple ID.
5. On iOS 16 and later, also turn on *Settings → Privacy & Security → Developer Mode*.

With a free Apple ID the app must be re-signed every 7 days; your library is kept.

## Build on a Mac

```bash
brew install xcodegen
xcodegen generate
open *.xcodeproj
```

Choose your team under *Signing & Capabilities*, connect the iPhone and press Run.
Requires Xcode 16 or newer; the app runs on iOS 17 and later.

## Project layout

```
Core/        YouTube Music client, parser, stream resolver, lyrics, beat analysis, Listen Together
Playback/    Audio engine, stream loader, cache, Automix, Google Cast
App/         App entry, settings, library, account
UI/          SwiftUI screens
AltIcons/    Alternate app icons
project.yml  XcodeGen project definition
```

## Credits & licence

FYT is an iOS port based on an open-source Android YouTube Music client by
[kushagrasinghx](https://github.com/kushagrasinghx), and is released under the same
licence, the GNU General Public License v3.0. See [LICENSE](LICENSE).
