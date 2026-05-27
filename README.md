# AppDrop

> Browse 157,000 archived iOS apps from 2008–2014 and install them on your jailbroken device, with built-in AI search.

<p align="center">
  <img src="IPAInstaller/Resources/Icon-152.png" width="120" height="120" alt="AppDrop icon">
</p>

<p align="center">
  <img src="screenshots/screenshot-11.png" width="600" alt="AppDrop catalog grid on iPad">
</p>

---

## Compatibility

- **iOS 6.0 – 9.3.6** (armv7 / 32-bit)
- iPhone 4S, iPad 2 / 3 / 4 / iPad mini, iPod touch 5
- Requires a **jailbreak** with one of these helper packages installed from Cydia / Sileo:
  - `IPA Installer Console` (by autopear) — most common
  - `appinst` (`ai.akemi.appinst`) — newer variant

> 💡 If you can already install `.ipa` files on your device (manually or via Filza), you have everything you need.

## Features

- **157k vintage app catalog** bundled in the IPA — works offline once installed
- **AI search** — describe an app in any language, the LLM finds it for you
- **7 languages** — EN / FR / ES / DE / PT‑BR / JA / ZH‑Hans, auto-detected from your device
- **Multi-select install** — queue up dozens of apps in one batch
- **Cancellable downloads** with live progress
- **Skeuomorphic iOS 6 UI** — fits naturally into your jailbroken device
- **No backend, no account, no tracking** — talks directly to archive.org and pollinations.ai

## Install

### Quick path (5 minutes)

1. **Verify the helper is installed.** Open **Cydia**, search for `IPA Installer Console`. If it doesn't say *Installed*, tap **Install**.

2. **Download the IPA.** Grab the latest `AppDrop-v*.ipa` from the [Releases page](https://github.com/AdrienRL1/adrienrl/releases) on your computer.

3. **Transfer it to your device.** Easiest way: AirDrop the `.ipa` from your Mac to the iPad / iPhone. Alternative: SSH+`scp`, iCloud Drive, or any cloud storage app.

4. **Install it.** Tap the file in your file manager (iFile / Filza) → choose **Installer** / *Install*. Or via SSH:
   ```bash
   ssh root@<device-ip>
   ipainstaller /var/mobile/Documents/AppDrop-v1.0.ipa
   ```

5. **Done.** AppDrop appears on the home screen with rounded corners and the iOS 6 gloss reflection.

### Troubleshooting

| Symptom | Fix |
|---|---|
| Icon not visible after install | SSH in and run `su mobile -c uicache && killall -9 SpringBoard`, or just reboot the device. |
| `ipainstaller: command not found` | Install `IPA Installer Console` from Cydia first (step 1). |
| `Echec install : Operation not permitted` | Your jailbreak's sandbox blocks `posix_spawn` — known on some iOS 5 jailbreaks. iOS 6+ is fine. |
| App crashes on launch | Make sure your iOS is **6.0 or newer**. Older iOS isn't supported. |

## Using AppDrop

### The catalog

<img src="screenshots/screenshot-11.png" width="500" alt="Catalog grid">

Browse all 157,000 archived apps. Tap *Filters* to narrow by iOS version, device, or sort order. Tap *Select* to enter multi-pick mode for batch installs.

### AI search

<img src="screenshots/screenshot-12.png" width="380" alt="AI chat finding racing games">

Tap the *AI Chat* tab and describe an app in plain language — any of the 7 supported languages works. The LLM identifies vintage titles (Real Racing 3, Asphalt 6, NFS, etc.) and shows them as tappable install cards.

### App details

<img src="screenshots/screenshot-13.png" width="400" alt="App detail showing Angry Birds with Install button">

Tap any app to see its bundle ID, version, minimum iOS, platform, file size, and the actual archive.org URL. The big blue **Install** button shows live download progress (`Téléchargement 42 %` → `Installation…` → `Installé`).

### Filters

<img src="screenshots/screenshot-14.png" width="380" alt="Filters screen">

Narrow the catalog by minimum / maximum iOS version, device class (iPhone, iPad, both), uniqueness (one row per bundle ID), and sort order. Tap a sort row again to flip ascending / descending.

## How it works

```
Catalog metadata          : stuffed18.github.io/ipa-archive-updated
   ↓ pre-built SQLite bundled in the IPA
AI search                 : text.pollinations.ai (anonymous, no key)
   ↓ returns app titles + keywords
IPA download              : http://archive.org/download/X/Y.ipa
   ↓ archive.org → CDN redirect → mbedTLS-bundled HTTPS
Local install             : /usr/bin/ipainstaller path/to/Y.ipa
   ↓
App on home screen ✓
```

AppDrop downgrades archive.org requests from `https://` to `http://` to bypass Fastly's JA3-fingerprint blocking on old TLS clients. The CDN node then redirects to HTTPS, and the bundled mbedTLS handles the Let's Encrypt handshake on iOS 6 where the system TLS stack is too old.

## Build from source

Requires the [Theos](https://theos.dev) cross-compile toolchain on macOS.

```bash
git clone https://github.com/AdrienRL1/adrienrl.git
cd adrienrl
export THEOS=$HOME/theos

# One-time: build mbedTLS for armv7 (or use the prebuilt libs in deps/build/)
cd deps && bash build-mbedtls-ios.sh && cd ..

# Build the .ipa and deploy directly to a jailbroken device via SSH
IPAD_IP=192.168.x.x bash build-install.sh
```

The build script needs `sshpass` (Homebrew: `brew install hudochenkov/sshpass/sshpass`) and SSH access (root / alpine by default) to a jailbroken iOS 6+ device.

## Architecture

| Layer | Technology |
|---|---|
| UI | Objective-C, UIKit, custom `drawRect:` skeuomorphic widgets |
| Networking | Bundled mbedTLS (TLS 1.2) on raw sockets — iOS 6 system TLS can't handshake modern servers |
| Catalog DB | SQLite (system `libsqlite3`) |
| AI | Pollinations.ai (GPT-OSS 20B) with a vintage-iOS expert system prompt |
| Install | `posix_spawn` → `/usr/bin/ipainstaller` |
| i18n | NSBundle `.lproj` × 7 langs |
| Build | Theos (clang armv7) |

## Privacy

AppDrop runs no analytics, has no account system, sends no telemetry. See [PRIVACY.md](PRIVACY.md) for the full list of third-party services contacted at runtime.

## License

[MIT License](LICENSE) — use it, modify it, fork it.

## Credits

- **stuffed18** — public IPA catalog metadata at [github.com/stuffed18/ipa-archive-updated](https://github.com/stuffed18/ipa-archive-updated)
- **archive.org** — hosting the actual IPA files
- **Pollinations.ai** — free anonymous LLM endpoint
- **mbedTLS** — Apache-2.0 TLS library that made HTTPS work on iOS 6
- **autopear** — `ipainstaller`, the helper AppDrop delegates to

## Disclaimer

AppDrop is a client for publicly-listed archive.org content. The app downloads files that are already available to anyone with a browser. It does not redistribute or host any IPAs itself. Use responsibly — only install software you own or that is freely redistributable (free, archived, homebrew).
