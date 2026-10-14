# Timetracker

Native macOS menu bar time tracker. Entries are linked to GitHub issues, stored in a
local SQLite file, and rendered to a client-facing timesheet PDF by the app itself.

Design: `docs/superpowers/specs/2026-10-13-timetracker-design.md`.

## Build

    brew install xcodegen
    xcodegen generate
    xcodebuild -scheme Timetracker -configuration Debug build

## Tests

    cd TimeCore && swift test

## Monthly run

1. Open Reports… from the menu bar, pick the month, preset "Monthly timesheet".
2. Check the warnings panel; fix entries in Entries… if needed.
3. Export PDF… → `Timesheet_YYYY-MM.pdf`.

Durations are rounded up to 15 minutes at report time; the database keeps the exact times.

If you place the database on a synced folder (iCloud Drive, Dropbox), keep the app running on one machine only; SQLite files do not merge.

Before the first real use, run the parity gate described in `docs/parity.md` for two months.

## Release build

`scripts/release.sh` builds a Release configuration signed with the Developer ID
Application certificate (hardened runtime, secure timestamp), notarizes it with
`notarytool`, staples the ticket and writes `dist/Timetracker-<version>.zip`.
Debug builds stay ad-hoc signed, so contributors need no certificate.

One-time setup for notarization (an app-specific password stored in the login keychain):

    xcrun notarytool store-credentials timetracker-notary --apple-id <apple-id> --team-id 76C3CLR3D5

`scripts/release.sh --no-notarize` builds and signs without Apple credentials.
The version comes from `MARKETING_VERSION` in `project.yml`; the build number is the commit count.
