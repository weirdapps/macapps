<p align="center">
  <img src="docs/icons.png" width="720" alt="Fifty app icons">
</p>

<h1 align="center">Small Mac Apps</h1>

<p align="center">
  Fifty native menu bar apps for macOS.<br>
  Each does one thing, stays out of the way, and looks like it belongs on a Mac.
</p>

<p align="center">
  <a href="https://weirdapps.github.io/macapps/"><b>Website</b></a> ·
  <a href="https://github.com/weirdapps/macapps/releases/latest"><b>Download</b></a> ·
  <a href="#build-from-source"><b>Build from source</b></a>
</p>

<p align="center">
  <img src="docs/screenshots/Jot.png" width="250" alt="Jot">
  <img src="docs/screenshots/Swatch.png" width="250" alt="Swatch">
  <img src="docs/screenshots/Pulse.png" width="250" alt="Pulse">
</p>

## Why

- **Native.** AppKit and SwiftUI, no web views, no Electron. Each app is a few hundred kilobytes and idles at zero CPU.
- **Private.** No accounts, no analytics, no telemetry. Data stays in `~/Library/Application Support/<App>`.
- **No scary permissions.** No Accessibility, Screen Recording or Automation. Global shortcuts use Carbon hot keys. Bin is the one exception: reading the Trash needs Full Disk Access, and it tells you how to grant it.
- **Out of the way.** No Dock icons, no windows, no onboarding. Click the icon in the menu bar, or press its shortcut.

## The apps

### Write and organise

| | App | What it does | Shortcut |
|---|---|---|---|
| <img src="docs/icons/Jot.png" width="40" alt=""> | [**Jot**](https://weirdapps.github.io/macapps/#jot) | A scratchpad in your menu bar | ⌥⌘J |
| <img src="docs/icons/Stash.png" width="40" alt=""> | [**Stash**](https://weirdapps.github.io/macapps/#stash) | Text snippets one click away | ⌥⌘S |
| <img src="docs/icons/Ticks.png" width="40" alt=""> | [**Ticks**](https://weirdapps.github.io/macapps/#ticks) | A quick checklist in your menu bar |  |
| <img src="docs/icons/Tally.png" width="40" alt=""> | [**Tally**](https://weirdapps.github.io/macapps/#tally) | Counters for anything, in your menu bar |  |
| <img src="docs/icons/Until.png" width="40" alt=""> | [**Until**](https://weirdapps.github.io/macapps/#until) | Countdowns to the days that matter |  |
| <img src="docs/icons/Decide.png" width="40" alt=""> | [**Decide**](https://weirdapps.github.io/macapps/#decide) | Coin flips, dice and picks for when you cannot choose |  |
| <img src="docs/icons/Measure.png" width="40" alt=""> | [**Measure**](https://weirdapps.github.io/macapps/#measure) | Word counts and reading time for copied text |  |

### Clipboard and text

| | App | What it does | Shortcut |
|---|---|---|---|
| <img src="docs/icons/Plain.png" width="40" alt=""> | [**Plain**](https://weirdapps.github.io/macapps/#plain) | Clean clipboard text and links |  |
| <img src="docs/icons/Case.png" width="40" alt=""> | [**Case**](https://weirdapps.github.io/macapps/#case) | Change the case of copied text |  |
| <img src="docs/icons/Lorem.png" width="40" alt=""> | [**Lorem**](https://weirdapps.github.io/macapps/#lorem) | Placeholder text and fake data on tap |  |
| <img src="docs/icons/Glyphs.png" width="40" alt=""> | [**Glyphs**](https://weirdapps.github.io/macapps/#glyphs) | Special characters a click away | ⌥⌘G |
| <img src="docs/icons/Tabula.png" width="40" alt=""> | [**Tabula**](https://weirdapps.github.io/macapps/#tabula) | Turn copied CSV into Markdown tables and back |  |
| <img src="docs/icons/Keymaker.png" width="40" alt=""> | [**Keymaker**](https://weirdapps.github.io/macapps/#keymaker) | Strong passwords and passphrases on demand |  |

### Time and focus

| | App | What it does | Shortcut |
|---|---|---|---|
| <img src="docs/icons/Meridian.png" width="40" alt=""> | [**Meridian**](https://weirdapps.github.io/macapps/#meridian) | World clocks in your menu bar |  |
| <img src="docs/icons/Tempo.png" width="40" alt=""> | [**Tempo**](https://weirdapps.github.io/macapps/#tempo) | A focus timer in your menu bar | ⌥⌘T |
| <img src="docs/icons/Month.png" width="40" alt=""> | [**Month**](https://weirdapps.github.io/macapps/#month) | A calendar with week numbers in your menu bar |  |
| <img src="docs/icons/Lap.png" width="40" alt=""> | [**Lap**](https://weirdapps.github.io/macapps/#lap) | A stopwatch with laps in your menu bar |  |
| <img src="docs/icons/Nudge.png" width="40" alt=""> | [**Nudge**](https://weirdapps.github.io/macapps/#nudge) | Quick reminders from your menu bar | ⌥⌘R |
| <img src="docs/icons/Daylight.png" width="40" alt=""> | [**Daylight**](https://weirdapps.github.io/macapps/#daylight) | Sunrise, sunset and golden hour in your menu bar |  |
| <img src="docs/icons/Luna.png" width="40" alt=""> | [**Luna**](https://weirdapps.github.io/macapps/#luna) | The moon phase in your menu bar |  |

### Wellbeing

| | App | What it does | Shortcut |
|---|---|---|---|
| <img src="docs/icons/Sip.png" width="40" alt=""> | [**Sip**](https://weirdapps.github.io/macapps/#sip) | Hydration tracking in your menu bar |  |
| <img src="docs/icons/Blink.png" width="40" alt=""> | [**Blink**](https://weirdapps.github.io/macapps/#blink) | Eye breaks, the 20-20-20 way |  |
| <img src="docs/icons/Hush.png" width="40" alt=""> | [**Hush**](https://weirdapps.github.io/macapps/#hush) | Mute your microphone from anywhere | ⌥⌘M |

### System

| | App | What it does | Shortcut |
|---|---|---|---|
| <img src="docs/icons/Pulse.png" width="40" alt=""> | [**Pulse**](https://weirdapps.github.io/macapps/#pulse) | CPU and memory at a glance |  |
| <img src="docs/icons/Charge.png" width="40" alt=""> | [**Charge**](https://weirdapps.github.io/macapps/#charge) | Your battery, in detail |  |
| <img src="docs/icons/Room.png" width="40" alt=""> | [**Room**](https://weirdapps.github.io/macapps/#room) | Disk space for every volume |  |
| <img src="docs/icons/Flow.png" width="40" alt=""> | [**Flow**](https://weirdapps.github.io/macapps/#flow) | Network speed in your menu bar |  |
| <img src="docs/icons/Awake.png" width="40" alt=""> | [**Awake**](https://weirdapps.github.io/macapps/#awake) | Keep your Mac awake | ⌥⌘A |
| <img src="docs/icons/Hogs.png" width="40" alt=""> | [**Hogs**](https://weirdapps.github.io/macapps/#hogs) | What is eating your CPU and memory |  |
| <img src="docs/icons/Bin.png" width="40" alt=""> | [**Bin**](https://weirdapps.github.io/macapps/#bin) | How full is the Trash |  |
| <img src="docs/icons/Eject.png" width="40" alt=""> | [**Eject**](https://weirdapps.github.io/macapps/#eject) | Eject every disk in one go | ⌥⌘E |
| <img src="docs/icons/Since.png" width="40" alt=""> | [**Since**](https://weirdapps.github.io/macapps/#since) | Uptime, sleep and wake, at a glance |  |

### Network

| | App | What it does | Shortcut |
|---|---|---|---|
| <img src="docs/icons/Reach.png" width="40" alt=""> | [**Reach**](https://weirdapps.github.io/macapps/#reach) | Is the internet up, and how fast |  |
| <img src="docs/icons/Address.png" width="40" alt=""> | [**Address**](https://weirdapps.github.io/macapps/#address) | Every IP address, one click to copy |  |
| <img src="docs/icons/Ports.png" width="40" alt=""> | [**Ports**](https://weirdapps.github.io/macapps/#ports) | Who is listening on which port |  |

### Colour and design

| | App | What it does | Shortcut |
|---|---|---|---|
| <img src="docs/icons/Swatch.png" width="40" alt=""> | [**Swatch**](https://weirdapps.github.io/macapps/#swatch) | A colour picker in your menu bar | ⌥⌘C |
| <img src="docs/icons/Contrast.png" width="40" alt=""> | [**Contrast**](https://weirdapps.github.io/macapps/#contrast) | A WCAG contrast checker in your menu bar |  |
| <img src="docs/icons/Palette.png" width="40" alt=""> | [**Palette**](https://weirdapps.github.io/macapps/#palette) | Colour palettes from one colour, in your menu bar |  |
| <img src="docs/icons/Convert.png" width="40" alt=""> | [**Convert**](https://weirdapps.github.io/macapps/#convert) | A unit converter in your menu bar |  |

### Developer tools

| | App | What it does | Shortcut |
|---|---|---|---|
| <img src="docs/icons/Codec.png" width="40" alt=""> | [**Codec**](https://weirdapps.github.io/macapps/#codec) | Encode and decode text in your menu bar |  |
| <img src="docs/icons/Pretty.png" width="40" alt=""> | [**Pretty**](https://weirdapps.github.io/macapps/#pretty) | Format and validate JSON from your menu bar | ⌥⌘F |
| <img src="docs/icons/Ident.png" width="40" alt=""> | [**Ident**](https://weirdapps.github.io/macapps/#ident) | Generate UUIDs, ULIDs and random IDs |  |
| <img src="docs/icons/Hash.png" width="40" alt=""> | [**Hash**](https://weirdapps.github.io/macapps/#hash) | Hash text and files, and check them |  |
| <img src="docs/icons/Epoch.png" width="40" alt=""> | [**Epoch**](https://weirdapps.github.io/macapps/#epoch) | Convert Unix timestamps and dates |  |
| <img src="docs/icons/Regex.png" width="40" alt=""> | [**Regex**](https://weirdapps.github.io/macapps/#regex) | Test regular expressions live |  |
| <img src="docs/icons/Square.png" width="40" alt=""> | [**Square**](https://weirdapps.github.io/macapps/#square) | Make and read QR codes |  |
| <img src="docs/icons/Cron.png" width="40" alt=""> | [**Cron**](https://weirdapps.github.io/macapps/#cron) | Explain cron schedules and their next runs |  |
| <img src="docs/icons/Token.png" width="40" alt=""> | [**Token**](https://weirdapps.github.io/macapps/#token) | Decode and verify JSON Web Tokens |  |
| <img src="docs/icons/Compare.png" width="40" alt=""> | [**Compare**](https://weirdapps.github.io/macapps/#compare) | Compare two texts line by line |  |
| <img src="docs/icons/Sum.png" width="40" alt=""> | [**Sum**](https://weirdapps.github.io/macapps/#sum) | A calculator in your menu bar | ⌥⌘K |

## Good to know

Every app has launch at login in its gear menu. Global shortcuts use Carbon hot keys, so none of them needs Accessibility permission. Only Reach (a HEAD request every 10 s to a URL you choose) and Address (your public IP, fetched when you open it) use the network.

## Install

1. Download `SmallMacApps.zip` (all fifty) or a single app's zip from the [latest release](https://github.com/weirdapps/macapps/releases/latest).
2. Unzip and drag the apps you want to `/Applications`.
3. The apps are signed ad hoc, not notarized, so macOS blocks them on first launch. Clear the quarantine flag once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Jot.app   # or each app you installed
   ```

   Or open the app, then click **Open Anyway** in System Settings › Privacy & Security.

Requires macOS 14 Sonoma or later on Apple silicon.

## Build from source

Needs Xcode 16 or later (Swift 5.10 tools). Built and tested with Xcode 27.2 on macOS 27.

```bash
# HTTPS (no SSH key required):
git clone https://github.com/weirdapps/macapps.git
# or, with SSH:
git clone git@github.com:weirdapps/macapps.git
cd macapps
scripts/build.sh                 # every app as a signed bundle in build/
scripts/build.sh --install       # and copies them to /Applications
scripts/build.sh --install Jot   # one app
swift test                       # Kit tests
scripts/release.sh               # release zips, website icons and screenshots
```

## How it is built

| Path | What is there |
|---|---|
| `Sources/Kit/` | Shared code: menu bar popover with a hidden Edit menu, global hot keys, HUD overlay, launch at login, panel footer, JSON storage, link cleaner |
| `Sources/<App>/` | One app: model, SwiftUI views and `appIcon()`, drawn in Core Graphics with no image assets |
| `Apps/<App>/Info.plist` | Bundle metadata (`LSUIElement`, so no Dock icon) |
| `scripts/build.sh` | Builds, wraps each binary in an `.app`, makes the `.icns`, signs, installs |
| `scripts/release.sh` | Zips every bundle for a release and refreshes `docs/` |
| `docs/` | The [website](https://weirdapps.github.io/macapps/), served by GitHub Pages |

`<App> --snapshot out.png` renders an app's panel to a PNG with fixed demo data, and `<App> --icon out.png` renders its icon. To add an app, read [docs/APP_GUIDE.md](docs/APP_GUIDE.md).

## License

MIT © 2026 Dimitrios Plessas
