# Apple Watch companion — design

Date: 2026-10-15
Status: implemented; on-watch verification pending (2026-10-15)

Builds on `2026-10-14-sync-design.md`; rules R1–R16 apply unchanged. This document adds
R17–R19 and amends the R2 table.

## Goal

Start and stop stints from the wrist, with the phone absent. The watch shows what runs on
the watch face, lets you restart the last stint, and lets you start one of your recent
stints or one of the issues assigned to you. Descriptions are not typed on the watch.

## Decisions already taken

- The watch is a full sync peer: its own SQLite file, the same `SyncEngine`, the same
  CloudKit container and zone. It works wherever the watch has a network and queues
  changes offline (R5).
- The watch never talks to GitHub and holds no token. The assigned-issue list reaches it
  as a synced snapshot written by the Mac or the phone (R18).
- The complication is a WidgetKit accessory widget fed from an App Group store.
- No editing on the wrist beyond delete; no search; no unassigned or closed issues; no
  reports.

## Assumptions

1. watchOS 10 or later; the watch is paired with the iPhone that runs Stint, so the watch
   app installs with the iOS app.
2. The same iCloud account on all three devices (sync spec assumption 1).
3. Background refresh on watchOS is best effort; the wrist is kept current by syncing on
   every foreground and after every tap, not by push.

---

## 1. Rules

### R17 The watch keeps the current month

The watch holds entries of the current calendar month only. After every sync cycle it
prunes finished entries that start before the month, with the same local delete that
bypasses the outbox as the phone's R14. Clients, projects, repos, settings and the
assigned-issue snapshot are never pruned.

### R18 Assigned-issue snapshot

A synced table `assignedIssues` with exactly one row (fixed uuid
`00000000-0000-0000-0000-00000000a551`) and the columns `fetchedAt` (UTC instant) and
`payload` (JSON text). The payload is a list of objects with the keys `repo` (owner/name),
`number`, `title`, `project` (the project uuid or null), ordered by repo then number.

- Written by the Mac and the phone at the end of every issue sync that applied (the
  `AccountSyncOutcome.applied == true` path), through the ordinary stamping helpers, so
  the write lands in the outbox (R5) and merges by R3 (`modifiedAt`), which on this row
  equals `fetchedAt`.
- Read by the watch: when a remote `assignedIssues` row is applied, the watch replaces its
  local issue cache with the payload, resolving `repo` to the local repo row by full name
  (repos sync, so the row exists; a missing repo skips the issue) and marking every issue
  as open and assigned. The watch never writes this row.
- The Mac and the phone ignore incoming snapshots for their own issue cache; they only
  store the row so that the newest `fetchedAt` wins consistently everywhere.

Amendment to the R2 table in the sync spec: `assignedIssues | yes | one row, R18`.
`issueCache` itself remains unsynced.

### R19 Watch sync triggers

The watch syncs at launch and when the app becomes active; immediately after start, stop,
restart and delete (not debounced, so the tap leaves the wrist before the app sleeps); and
in a `WKApplicationRefreshBackgroundTask` scheduled every 30 minutes, which pulls, applies,
prunes (R17) and refreshes the complication, then schedules the next one. Failures appear
only in the Settings status line.

---

## 2. Data model changes (migration 5)

- New table `assignedIssues(id, uuid, modifiedAt, modifiedBy, deletedAt, fetchedAt,
  payload)` with the sync columns of every synced table. It is added to the engine's table
  list and to the record mapper as record type `AssignedIssues`; apply order is after
  `setting` (no parents, no children).
- Window helpers gain `months: 1` for the watch (the existing `windowStart(now:months:calendar:)`
  already takes the count).

## 3. Targets

| target | kind | bundle id | sources |
|---|---|---|---|
| `StintWatch` | watchOS app, watchOS 10+, embedded in `StintMobile` | `io.artnim.stint.ios.watchkitapp` | `Watch/` |
| `StintWatchWidget` | WidgetKit extension of the watch app | `io.artnim.stint.ios.watchkitapp.widget` | `WatchWidget/` |

`TimeCore` gains `.watchOS(.v10)`; the PDF files stay fenced to macOS. `Shared/KeychainStore.swift`
is not compiled into the watch. Both watch targets use automatic signing with the team.
Entitlements: watch app gets the iCloud container `iCloud.io.artnim.stint`, CloudKit, the
production container environment (like the phone) and the App Group
`group.io.artnim.stint`; the widget gets the App Group only.

## 4. Watch app

`WatchState` (`@Observable @MainActor`) mirrors `MobileState` without GitHub: opens the
database, builds transport and engine, exposes `running`, `recents`, `issueRows`,
`todayEntries`, `syncStatus`, and the actions `start(_:)`, `startIssue(_:)`, `restartLast()`,
`stop()`, `delete(_:)`, `syncNow(reason:)`. After every write and every sync it writes the
complication store (section 5) and asks WidgetKit to reload.

Screens, a vertical page stack:

- **Stint**: running entry with description, project and a live elapsed timer
  (`Text(startDate, style: .timer)`), a Stop button; or "Nothing running" and "Restart
  last" (the most recent finished entry's description, project, repo and issue). Below:
  "Recent" (ten) and the assigned issues grouped by project, one tap starts. Haptic on
  start and stop.
- **Today**: today's entries newest first with duration, the running one marked; swipe to
  delete with a confirmation dialog.
- **Settings**: sync status line and "Sync now".

## 5. Complication

WidgetKit accessory families `accessoryRectangular`, `accessoryCircular`, `accessoryInline`.
The store is `UserDefaults(suiteName: "group.io.artnim.stint")` holding one JSON value under
the key `complication` with the fields `description` (String?) and `start` (Date?), written by
the watch app only and only when it changed.
Rectangular: description (one line) over a live timer; circular: the Stint ring icon with
elapsed minutes below; inline: "Stint · h:mm" or "Stint · —". With nothing running every
family shows the ring and "—". The timeline has a single entry; the timer text ticks on
its own, and the app reloads the timeline after each change. Tapping opens the app.

## 6. Signing and distribution

- Portal: App IDs `io.artnim.stint.ios.watchkitapp` (iCloud with the Stint container, App
  Group) and `io.artnim.stint.ios.watchkitapp.widget` (App Group); the App Group
  `group.io.artnim.stint` is created once. The iOS App ID is unchanged.
- The watch ships inside the iOS app through Xcode or TestFlight. The Mac release is not
  affected; `MARKETING_VERSION` becomes 0.3.0 for the Mac, phone, watch and widget.
- CloudKit: the `AssignedIssues` record type appears in Development after the first Mac
  sync with the new build and must be deployed to Production before the watch (which uses
  Production) is first run.

## 7. Error handling

Transport errors never alert; they show in the Settings status line. A failed apply rolls
back and keeps the token (R9). A snapshot whose payload does not parse is stored (so LWW
stays consistent) but not applied to the cache, and the previous cache stays.

## 8. Testing

TimeCore unit tests with the fake server:

- R18 writer: a merged issue list produces the expected ordered JSON and one outbox row.
- R18 reader: applying a snapshot replaces the issue cache, maps repos by full name, skips
  an unknown repo, leaves entries untouched, and a malformed payload leaves the cache as it
  was.
- R18 LWW: two devices write snapshots; the newer `fetchedAt` wins on a third database.
- R17: a one-month window prunes last month's finished entries and keeps the running one,
  with no outbox rows.
- R7 across three peers: a stint started on the "watch" database while the "Mac" database
  runs one converges on the later start everywhere.

No watch UI tests; the complication and background refresh are checked on hardware.

## 9. Build order

1. Migration 5, `assignedIssues` in engine and mapper, writer in `AccountSync`, reader;
   tests.
2. TimeCore watchOS platform; `WatchState` and the three screens; watch target in
   `project.yml`.
3. Complication store and widget extension.
4. Background refresh task; portal, schema deployment, version 0.3.0.
