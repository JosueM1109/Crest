# Josue's Crest build

This checkout builds the Crest at `/Applications/Crest.app`. It is the maintainer's code plus Josue's commits, packaged with the maintainer's published Chromium engine and signed with Josue's Apple Development certificate.

## Branches and remotes
- `upstream` points to github.com/pauljoda/Crest. It is fetch-only in practice. Never push to it.
- `origin` is Josue's fork, if one exists. Push `josue` there as a backup.
- `josue` is Josue's working branch: an upstream release tag plus Josue's commits.

## Everyday commands
| Do this | Run |
|---|---|
| Update to the maintainer's latest stable release | `Local/update.sh` |
| Update to a specific release | `Local/update.sh v0.8.60` |
| Use the maintainer's newest code (nightly-grade) | `Local/update.sh upstream/main` |
| Rebuild after changing code | commit, then `Local/update.sh --rebuild` |
| Roll back the app | quit Crest, then `mv ~/Library/Caches/Crest-local/Crest.previous.app /Applications/Crest.app` (move the current one aside first) |

A build compiles only the Swift UI and C# core, which takes minutes. The Chromium engine is downloaded once per engine version into `~/Library/Caches/Crest-local/engines`.

## How this build differs from the official one
- **No iCloud sync, no Crest Passwords, no system passkey sheet.** Those features need the maintainer's Apple team. Bitwarden covers passwords and passkeys.
- **Updates come from `Local/update.sh`, not Sparkle.** The app's update key is replaced, so it can't install official builds over this one. "Check for Updates" inside Crest will fail, and that is expected.
- **The bundle ID stays `com.pauldavis.crest`** because the engine names its keychain item after it. Don't install the official Crest on this Mac too, because both would share one ID.

## Changing the engine, or if the maintainer stops publishing
Swift, C#, and packaging changes reuse the published engine. Changes to Chromium patches, `Overlay/`, `source.lock.json`, or the control-plane scripts give a new engine key that has no published engine. In that case, build Chromium yourself by following `CrestEngines/Chromium/README.md`. The build needs `ninja`, `go`, 50+ GB free and several hours, and its performance preset needs the macOS 26.5 SDK. Then rerun with `CREST_CHROMIUM_APP=/path/to/Chromium.app Local/update.sh --rebuild`.

## Sending fixes upstream
Make a branch from `upstream/main` that does not include `Local/`, follow `AGENTS.md` and the `crest-contribution` skill, and open the PR from the fork. Once it merges, git usually drops your copy from `josue` on the next update (if the maintainer edited it, you get a conflict to resolve instead).
