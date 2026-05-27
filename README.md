# AppDrop

Native iOS app for browsing and installing vintage IPA files on jailbroken iOS 6+ devices.

Browses a catalog of **157,000 archived iOS apps (2008–2014)** hosted on archive.org, with built-in AI search, multi-language UI, and direct local install via `ipainstaller`.

<p align="center">
<img src="IPAInstaller/Resources/Icon-152.png" width="152" height="152" alt="AppDrop icon">
</p>

## Compatibility

- **iOS 6.0 – 9.3.6** (armv7 / 32-bit)
- iPhone 4S, iPad 2 / 3 / 4 / iPad mini, iPod touch 5
- Requires a **jailbreak** + the Cydia / Sileo package **`IPA Installer Console`** (by autopear) or **`AppInst`**
- iPad 1 (iOS 5.1.1) was supported up to v2.0.21 internal builds, dropped in v1.0 public release because the iOS 5 sandbox blocked auto-install

## Features

- **157k vintage app catalog** — SQLite database bundled in the IPA, opens in under 100 ms
- **AI search** — natural-language queries via [Pollinations](https://pollinations.ai) (free, no API key, multilingual). Tell it « a game where you cut ropes to feed candy to a green creature » and it identifies *Cut the Rope*
- **7 languages** — English, French, Spanish, German, Portuguese (Brazil), Japanese, Simplified Chinese. 138 keys × 7 langs = 966 translations, 100 % coverage
- **Multi-select install** — tap « Select » in the catalog, check apps, install them all in one batch. Selection persists across thousands of scrolled rows
- **Device-aware filter** — hides iPad-only apps on iPhone (they wouldn't run anyway)
- **Cancellable downloads** — swipe to cancel one, or « Cancel all » button
- **Skeuomorphic iOS 6 UI** — linen background, glossy buttons, brushed nav bars
- **Live install progress** in the app detail's Install button (`Téléchargement 42 %` → `Installation…` → `Installé`)
- **No backend** — talks directly to archive.org and pollinations.ai. No analytics, no account, no tracking

## Install

### Option A — Cydia / Sileo (recommended)

1. Open Cydia (or Sileo).
2. Sources → Edit → Add.
3. Enter: `https://AdrienRL1.github.io/adrienrl/`
4. Tap Add Source.
5. Find **AppDrop** under the new source and install.

You get auto-updates whenever a new version ships.

### Option B — Manual .ipa install

1. Make sure **`IPA Installer Console`** (by autopear) is installed from Cydia.
2. Download the latest `AppDrop-v*.ipa` from the [Releases page](https://github.com/AdrienRL1/adrienrl/releases).
3. Transfer to your device (Filza, SSH+scp, AirDrop, etc.).
4. Tap the IPA in Filza, or run on-device: `ipainstaller AppDrop-v*.ipa`.
5. AppDrop appears on the home screen.

## How it works

```
Catalog metadata           : stuffed18.github.io/ipa-archive-updated
   ↓ pre-built SQLite bundled in IPA
AI search keywords          : text.pollinations.ai (anonymous, no key)
   ↓
IPA download               : http://archive.org/download/X/Y.ipa
   ↓ archive.org redirects to CDN
                            : http(s)://dn*.ca.archive.org
   ↓ mbedTLS bundled in app (iOS 6 system TLS can't handshake modern certs)
Local install              : /usr/bin/ipainstaller path/to/Y.ipa
   ↓
App on home screen ✓
```

The app downgrades archive.org requests from `https://` to `http://` to bypass Fastly's JA3-fingerprint blocking on old TLS clients. The CDN node then redirects to HTTPS, and our bundled mbedTLS handles the Let's Encrypt handshake.

## Build from source

Requires [Theos](https://theos.dev) cross-compile toolchain on macOS.

```bash
git clone https://github.com/AdrienRL1/adrienrl.git
cd adrienrl
export THEOS=$HOME/theos

# Build mbedTLS (one-time)
cd deps && bash build-mbedtls.sh && cd ..

# Build + deploy to a jailbroken iPad via SSH
IPAD_IP=192.168.x.x bash build-install.sh
```

The script needs `sshpass` (Homebrew: `brew install hudochenkov/sshpass/sshpass`) and SSH access (root/alpine by default) to a jailbroken iOS 6+ device.

## Architecture

| Layer | Technology |
|---|---|
| UI | Objective-C, UIKit, custom `drawRect:` skeuomorphic widgets |
| Networking | Bundled mbedTLS (TLS 1.2) on raw sockets — iOS 6 system TLS is dead for modern servers |
| Catalog DB | SQLite (libsqlite3 system library) |
| AI | Pollinations.ai (GPT-OSS 20B), prompt expert vintage iOS pre-iOS 7 |
| Install | `posix_spawn` → `/usr/bin/ipainstaller` |
| i18n | NSBundle .lproj × 7 langs |
| Build | Theos (clang armv7) |

## Privacy

AppDrop runs no analytics, has no account system, sends no telemetry. See [PRIVACY.md](PRIVACY.md) for the exhaustive list of third-party services contacted at runtime.

## License

[MIT License](LICENSE). Use it, modify it, sell it, fork it.

## Credits

- **stuffed18** — public IPA catalog metadata at [github.com/stuffed18/ipa-archive-updated](https://github.com/stuffed18/ipa-archive-updated)
- **archive.org** — hosting the actual IPA files
- **Pollinations.ai** — free anonymous LLM endpoint
- **mbedTLS** — Apache-2.0 TLS library that made HTTPS work on iOS 6
- **autopear** — `ipainstaller` (the Cydia helper this app delegates to)

## Disclaimer

AppDrop is a client for publicly-listed archive.org content. The app downloads files that are already available to anyone with a browser. It does not redistribute or host any IPAs itself. Use responsibly — only install software you own or that is freely redistributable (free, archived, homebrew).
