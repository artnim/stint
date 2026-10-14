# Stint

A native macOS menu bar time tracker for people who bill by the hour and work out of
GitHub issues. Your data lives in one SQLite file on your Mac, the app talks to GitHub
read-only, and the monthly timesheet PDF comes out of the app itself. No account, no
server, no subscription.

Requires macOS 14 or newer.

## What it does

- **Timer in the menu bar.** Click the clock, click an issue, work, click Stop. The menu
  bar shows the elapsed time and the issue number while a timer runs. Only one timer runs
  at a time; starting another stops the current one.
- **GitHub issues as the picker.** The popover lists the open issues and pull requests
  assigned to you, grouped by project. Typing in the search field searches every open
  issue of your tracked repositories, plus those closed in the last 30 days, so you can
  book time on something a colleague owns or you just closed. One fine-grained token per
  GitHub organisation, read-only, stored in the Keychain.
- **Projects and clients.** A repository maps to a project, a project to a client. The
  first time an issue from an unmapped repository shows up you assign it with one click,
  and every entry you have already tracked on that repo gets the project too.
- **Entries window.** Edit start, end, project, description and tags of any entry, add
  entries by hand, delete with confirmation. Times you edit are truncated to the minute,
  so what you see is what gets rounded.
- **Reports window.** Pick a month or a date range, a client or project, the language
  (English or German), the rounding rules and the columns; see the PDF live; export it.
  Named presets remember a configuration; the built-in "Monthly timesheet" rounds every
  entry up to 15 minutes and snaps start times to the quarter hour. A warnings panel lists
  data smells in the raw entries: overlaps, duplicates, off-grid durations, empty
  descriptions.
- **Exact data, rounded report.** The database stores start and end as UTC instants and
  never a duration. Rounding and snapping happen only when a report is built, and the
  report total is always the sum of the (rounded) raw durations.
- **Import from solidtime.** Settings → Import reads a solidtime "detailed" CSV export,
  creating clients and projects from the file. Re-importing the same file adds nothing.

## Install

Download `Stint-<version>.zip` from the latest release, unzip, and move
`Stint.app` to Applications. The app is signed and notarized; macOS opens it
without a warning. It has no Dock icon; look for the clock in the menu bar.

To build it yourself:

    brew install xcodegen
    xcodegen generate
    xcodebuild -scheme Stint -configuration Debug -derivedDataPath build build
    open build/Build/Products/Debug/Stint.app

Debug builds are ad-hoc signed and need no certificate. `xcodegen generate` also writes
`Stint.xcodeproj` if you prefer Xcode.

## First run

1. **Settings → General**: your name, as it should appear on reports.
2. **Settings → GitHub**: add one fine-grained personal access token per resource owner
   (your own account counts as one, each organisation as another). Give each token read
   access to *Issues* and *Pull requests* (plus *Metadata*, added automatically) on the
   repositories you track, nothing else. The Add button tests the token before saving it.
3. **Open the popover.** Your assigned issues appear under "Unmapped". Use *Assign* to put
   each repository into a project, or create the project right there.
4. **Settings → Projects** to attach projects to clients, rename, or track a repository by
   `owner/name` before anything is assigned to you.

## Monthly run

1. Open *Reports…* from the popover, pick the month, keep the "Monthly timesheet" preset
   or your own.
2. Read the warnings panel; fix entries in *Entries…* if needed. The preview updates on
   every change.
3. *Export PDF…* writes `Timesheet_YYYY-MM.pdf` (or `Leistungsnachweis_YYYY-MM.pdf` in
   German).

## Where the data is

`~/Library/Application Support/Stint/stint.sqlite`, a plain SQLite file you
can open with any SQLite client and back up by copying. Settings → General can move it;
the app copies the current database to the new place. If you put it on a synced folder
(iCloud Drive, Dropbox), run the app on one machine only: SQLite files do not merge.

The GitHub tokens are in the login Keychain, never in the database.

## Development

The logic lives in the Swift package `TimeCore` (storage, rounding, report model, PDF
rendering, CSV import, GitHub client); `App/` is a thin SwiftUI layer on top. Tests:

    cd TimeCore && swift test

One test is environment-gated: `docs/parity.md` describes how the report was verified
against an independent reference implementation. Design notes are in `docs/design.md`.

### Release build

`scripts/release.sh` builds a Release configuration signed with the Developer ID
Application certificate (hardened runtime, secure timestamp), notarizes it with
`notarytool`, staples the ticket and writes `dist/Stint-<version>.zip`. It always
builds from scratch in `build-release/`.

One-time setup for local notarization (an app-specific password stored in the login
keychain):

    xcrun notarytool store-credentials stint-notary --apple-id <apple-id> --team-id <team-id>

`scripts/release.sh --no-notarize` builds and signs without Apple credentials. The version
comes from `MARKETING_VERSION` in `project.yml`; the build number is the commit count.

### Release via GitHub Actions

Pushing a tag `vX.Y.Z` that matches `MARKETING_VERSION` runs `.github/workflows/release.yml`:
tests, a signed and notarized build via `scripts/release.sh`, and a GitHub release with
the zip. It needs five repository secrets: `MACOS_CERT_P12_BASE64` and
`MACOS_CERT_PASSWORD` (the Developer ID Application identity exported from Keychain
Access), and `APP_STORE_CONNECT_KEY_P8`, `APP_STORE_CONNECT_KEY_ID`,
`APP_STORE_CONNECT_ISSUER_ID` (an App Store Connect API key with the Developer role,
used by `notarytool`).

    git tag v0.1.0 && git push origin v0.1.0

## Credits

Stint was designed and built by Martin Hans together with Claude, Anthropic's coding
assistant: the design discussion, the implementation plan, the code and its reviews were
done in Claude Code sessions, and every commit carries a `Claude-Session` link to the
session it came from. Besides being the tool Martin tracks his own time with, the project
is how he is learning Swift, so expect the code to be read and reworked as that goes on.
The report layout and rounding rules follow a Python tool Martin used before; the numbers
were verified against it.

## License

MIT, see `LICENSE`.
