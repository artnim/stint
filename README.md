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
