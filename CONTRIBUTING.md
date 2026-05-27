# Contributing to AppDrop

Thanks for your interest! AppDrop is a small native iOS 6+ jailbreak app — contributions are welcome but please read this first so we're on the same page.

## How I work on this project

AppDrop is a personal project I maintain in my spare time. I'm not a professional Objective-C / iOS developer — I built it with extensive AI assistance and a lot of testing on a real iPad 4. That means:

- **I read every PR carefully** before merging. AI-assisted review included.
- **I won't merge things I don't understand.** If you submit something complex, please explain *what* it does and *why* in the PR description.
- **Response time is on a hobby schedule.** Days, sometimes a week. Sorry, that's the deal.

## What I'm happy to receive

| Type | Effort | Risk to merge |
|---|---|---|
| **Translation fixes** | small, text only | ⭐ very safe — native speakers welcome to clean up the 7 `.lproj/Localizable.strings` files |
| **Bug reports** (Issues) | none | ⭐ ideal — even just a clear "X is broken on iOS 9, here's what I see" |
| **Documentation** (README, comments, typos) | small | ⭐ very safe |
| **iOS 10 testing & fixes** | medium | ⭐ valuable — I don't have an iOS 10 device |
| **Small bug fixes with clear scope** | small | ⭐ usually fine if the diff is short and the fix is obvious |
| **New features** | varies | ⚠️ please open an Issue first to discuss before writing code |
| **Large refactors** | high | ❌ very unlikely to merge without prior discussion |
| **Architectural changes** | high | ❌ same — please discuss in an Issue first |

## Workflow

1. **Open an Issue first** if your change is non-trivial. Describe what you want to do and why. We can agree on the approach before you spend time on code.
2. **Fork the repo**, create a feature branch (`fix-such-and-such` or `add-such-and-such`).
3. **Match the existing code style**: 4-space indentation, descriptive variable names, `// comments explaining intent, not just what the code says`. Look at `HTTPSClient.m` or `MachOInspector.m` for examples.
4. **Test on a real iOS 6.0 – 9.3.6 device** if you can. iOS 10 testing is also welcome.
5. **Open a PR** with a clear description: what changed, why, and how you tested.
6. **Be patient with review.** I'll ask questions if something is unclear. No hostility intended — I just want to understand what I'm merging.

## Code style notes

- **Objective-C 2.0** (`@()`, `@{}`, `dict[@"key"]` are fine — iOS 5 was dropped in v2.0.22).
- **No external dependencies** unless absolutely necessary. The only bundled libs are `mbedTLS` and system `libsqlite3` + `libz`.
- **No analytics / telemetry / phone-home.** This is a strict policy. AppDrop talks to archive.org, pollinations.ai, and api.github.com — that's it. PRs adding tracking will be closed.
- **Translations:** if you add a user-visible string, add the key to all 7 `.lproj/Localizable.strings` files. The audit will catch missing keys.
- **iOS 6 compat:** the SDK is iOS 6.1, deployment target 6.0. Don't use APIs introduced after iOS 6 without a runtime check. UI widgets must work on the iPad 4's 1024×768 screen.

## What I won't accept

- Code that adds tracking / analytics / remote configuration / phone-home of any kind.
- Code that pulls in large external dependencies.
- PRs that touch many unrelated files at once. One change per PR.
- PRs with no description.
- PRs that disable the FairPlay check (it exists for a reason).

## Reporting security issues

If you find a security issue (e.g., a malicious .ipa pattern that bypasses the FairPlay check, or a code path that could be tricked into installing arbitrary URLs), please **don't open a public Issue** — email me through GitHub instead. I'll address it before disclosure.

## License

By submitting a PR, you agree your contribution will be licensed under the [MIT License](LICENSE) like the rest of the project.

---

Thanks for taking the time to read this. AppDrop is small but I want it to stay clean and trustworthy — your patience with the review process is what makes that possible.
