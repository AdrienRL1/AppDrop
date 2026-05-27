# Privacy Policy — AppDrop

Last updated: 2026-05-26

## TL;DR

AppDrop collects nothing about you locally. It does not track you, does not analyze your usage, does not require an account, does not store any personal information.

It contacts a small number of public third-party services to function: the catalog index, the IPA file host, the AI search endpoint, and the image CDN. Each is contacted only when you trigger an action that requires it.

## What AppDrop stores locally

The app saves the following data on your device only, in standard iOS containers:

- **Filter preferences** (NSUserDefaults) — the iOS-version min/max, sort order, device-class filter, "hide suspicious files" toggle, language override.
- **Onboarding flag** (NSUserDefaults) — a single boolean tracking whether you've seen the « IPA Installer Console required » alert.
- **Install job history** (Caches directory, plist) — names + URLs + states of the last 24 hours of install attempts. Auto-purged after 24 h.
- **Icon cache** (in-memory only) — cleared on Home button or via Settings.
- **Catalog database** (read-only, bundled in the app's resources) — SQLite snapshot of the public stuffed18 catalog.

None of the above leaves your device.

## What AppDrop sends to third parties

| When you... | AppDrop contacts | What gets sent | Why |
|---|---|---|---|
| Open the AI chat tab and type a question | `text.pollinations.ai` | Your prompt text + the system instructions defining the assistant | Get keyword translation + reply from a free anonymous LLM |
| Tap « Install » on an app | `archive.org` (then their CDN nodes `dn*.ca.archive.org` or `ia*.us.archive.org`) | HTTP GET request for the .ipa file at the public URL | Download the IPA file |
| Scroll the catalog | `stuffed18.github.io` | HTTP GET request for each visible icon thumbnail | Display the app icon |
| Run the « Test HTTPS » diagnostic in Settings | `archive.org` | Empty HEAD request | Verify HTTPS connectivity |

Each of these third parties has its own privacy policy:

- **Pollinations.ai** — https://pollinations.ai (free anonymous endpoint, no account)
- **archive.org** — https://archive.org/about/terms.php
- **GitHub Pages** (hosting stuffed18.github.io) — https://docs.github.com/en/site-policy/privacy-policies/github-privacy-statement

AppDrop sends no API key, no device ID, no IDFA, no email, no IP-tracking cookie. The only thing those servers see is the public network metadata of your HTTPS / HTTP request (your IP, the request path).

## What AppDrop does NOT do

- No analytics (no Firebase, no Sentry, no Mixpanel, no Apple AppAnalytics)
- No advertising
- No social-network SDKs
- No fingerprinting
- No location services
- No microphone, camera, contacts, photos access
- No push notifications
- No background fetch
- No iCloud sync
- No keychain access
- No payment / IAP

## Data retention

- Locally: install job history auto-expires after 24 hours. Everything else persists until you delete the app.
- Third parties: their own retention policies apply. We have no control over what archive.org or Pollinations log on their side.

## Your rights

Since AppDrop stores nothing about you remotely, there's nothing to export, modify, or delete on our side. To erase the local data, uninstall AppDrop — iOS removes the app's container, including all stored preferences and caches.

## Source code

AppDrop is open source under the MIT license. You can audit every network call by reading the source — there's no obfuscation, no closed-source binary blob (except the bundled mbedTLS library, which is Apache-2.0 and whose source is also public).

- GitHub repository: see the project's main page

## Contact

For privacy questions, open an issue on the GitHub repository.

## Changes to this policy

Material changes will be announced in the release notes of new versions. The current version of this document applies to **AppDrop v2.0.0 (build 55)** and later.
