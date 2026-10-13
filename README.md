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

Before the first real use, run the parity gate described in `docs/parity.md` for two months.
