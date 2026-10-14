# Sync and iPhone companion — design

Date: 2026-10-14
Status: approved (assumptions confirmed, open points decided 2026-10-14)

## Goal

Track time on an iPhone as well as on the Mac, with both devices converging on the same
data without a server of our own. The Mac keeps its role as the place where reports are
rendered and verified; the phone is for starting, stopping and correcting stints on the
move.

## Decisions already taken

- Transport: CloudKit, private database of the user's iCloud account. No third-party
  service, no self-hosted server.
- Each device keeps its own SQLite file as the working copy; sync moves changes, never
  the file.
- Conflicts resolve per row by last-writer-wins. No field-level merging.
- The phone does not render PDFs in the first version.

## Assumptions (confirmed)

1. One iCloud account, your own. Sharing data between accounts is out of scope.
2. GitHub tokens travel through iCloud Keychain (synchronizable items), so both devices
   sync issues themselves; the issue cache is not synced.
3. Settings that sync: user name, report presets. Settings that stay per device: database
   location.
4. Clocks: both devices run Apple's NTP; we trust `modifiedAt` from the device clock and
   accept that a badly skewed clock could let an older edit win.
5. Offline use is normal on the phone; a day without connectivity must not lose anything.

---

## 1. Sync rules

These rules are the contract. Everything in sections 2 to 6 exists to implement them, and
the tests in section 8 check them directly.

### R1 Identity

Every synced row carries a `uuid` (text, unique, generated on insert) and a `modifiedAt`
(UTC instant, set on every local write). The local integer `id` stays for GRDB and
foreign keys inside one device; across devices rows are identified by `uuid` only.

### R2 What syncs

| table | synced | notes |
|---|---|---|
| `client` | yes | whole row |
| `project` | yes | whole row; `clientId` travels as the client's uuid |
| `repo` | yes | whole row; the project mapping travels as the project's uuid |
| `entry` | yes | whole row; `projectId`/`repoId` travel as uuids |
| `setting` | yes, per key | `userName`, `reportPresets`; never `databasePath` |
| `issueCache` | no | derived from GitHub on each device |

### R3 Last-writer-wins per row

When the same row changed on two devices, the version with the later `modifiedAt` wins
whole; on equal timestamps the version whose device id sorts higher wins. Winning is
decided when a remote change is applied: the local row is replaced only if the remote
`modifiedAt` is later than the local one, otherwise the local row stays and is pushed
again, which overwrites the remote.

### R4 Deletion wins

A deleted row is removed in CloudKit (a record deletion, not a flag). Deletions beat
concurrent edits: when a remote deletion arrives, the local row is deleted even if it was
edited after the deletion happened; when a local push hits a record that no longer exists,
the local row is deleted. Locally, a `deletedAt` tombstone marks rows waiting to be pushed
as deletions; tombstones are purged once pushed. Deleting a client or project leaves
dependants in place with a null reference, exactly as today.

### R5 Every local write is logged in the same transaction

Each insert, update or delete of a synced row appends `(table, uuid, op)` to an `outbox`
table inside the same SQLite transaction. A push drains the outbox; an entry is removed
only after CloudKit confirms the record. A crash between write and push loses nothing,
because the outbox is durable.

### R6 Pull before push

A sync cycle is: pull remote changes since the stored change token and apply them (R3,
R4), then push the outbox, then store the new token. Pushing first could overwrite a
remote edit the device has not seen yet.

### R7 One running stint across devices

The invariant "at most one entry without an end" must hold after any merge:

1. Starting a stint on a device stops the locally known running entry first, as today.
2. After applying remote changes, if more than one running entry exists, the one with the
   latest `startUTC` keeps running; every other one is ended at that `startUTC`, or at its
   own start if that is later (a zero-length stint rather than a negative one), and the
   change is logged for push.
3. The menu bar and the phone show whichever entry is running after the merge.

So two devices started offline converge on the later start, and the earlier stint is
booked up to the moment the later one began.

### R8 Apply order and missing parents

Remote changes are applied inside one transaction in the order client → project → repo
→ entry → setting, so parents exist before children. A child whose parent uuid cannot be
found (parent deleted meanwhile) gets a null reference.

### R9 Idempotence

Applying the same remote change twice is a no-op: rows are upserted by uuid, and R3 makes
an equal-or-older copy lose. The change token is advanced only after the batch is
committed, so a crash mid-apply replays the batch.

### R10 Never block the user

Sync runs in the background. Local reads and writes never wait for the network. Failures
(offline, quota, CloudKit unavailable) are retried with backoff; the UI shows a one-line
status (last successful sync, or the current problem) and nothing else changes.

### R11 Account changes

If no iCloud account is signed in, sync is simply off and the app works locally. If the
account changes to a different one, sync stops and the app asks before doing anything,
because merging two people's data is not a situation we design for; the first version
offers "keep local data, stop syncing" only.

### R12 First sync of an existing database

Migration 3 assigns uuids and `modifiedAt = now` to every existing row and puts every row
into the outbox. The first cycle therefore uploads the whole Mac database; a fresh phone
pulls it. Two devices that both had data before sync was enabled are merged by the same
rules, which means duplicates of the same project name may appear; a one-time "merge
projects with the same name" is a manual Settings action, not automatic.

### R13 Schema evolution

CloudKit record fields are only ever added. A device running an older version ignores
fields it does not know and preserves them on push by updating the fetched record rather
than building a new one.

### R14 The phone keeps a window, the Mac keeps everything

The phone holds entries of the current month and the two months before it. After every
sync cycle it prunes finished entries that start before that window. Pruning is a local
delete that bypasses the outbox (R5 does not apply), so it never reaches CloudKit or the
Mac. CloudKit itself keeps the whole history; the Mac applies every change. Clients,
projects, repos and settings are never pruned. A pruned entry that is edited on the Mac
comes back to the phone with that edit and is pruned again at the next cycle, which is
harmless.

### R15 Month total on the phone

The phone's Stint screen shows the current month's total: the sum of the raw durations of
finished entries in the window plus the running stint's elapsed time. It is unrounded and
says so ("exact; the report rounds"), because rounding is a report-time decision.

---

## 2. Data model changes (migration 3)

- `client`, `project`, `repo`, `entry`: add `uuid TEXT NOT NULL UNIQUE`, `modifiedAt
  DATETIME NOT NULL`, `deletedAt DATETIME NULL`. Existing rows get fresh uuids and the
  migration time.
- `setting`: add `modifiedAt`.
- New table `outbox(id, tableName, uuid, op, createdAt)`; `op` is `upsert` or `delete`.
- New settings keys, per device, not synced: `syncZoneToken`, `deviceId` (a uuid created
  on first launch, used as the R3 tie-breaker).
- Queries that list rows exclude tombstones (`deletedAt IS NULL`).

## 3. CloudKit mapping

- Container `iCloud.io.artnim.stint`, private database, one custom zone `stint` (custom
  zones are required for change tokens and atomic batches).
- Record types `Client`, `Project`, `Repo`, `Entry`, `Setting`; `recordName` is the row's
  uuid. Fields mirror the columns; references are plain uuid strings, not `CKReference`,
  so deletions never cascade on the server.
- Dates are `Date` fields; tags are a string list; `modifiedAt` is our own field, not the
  system modification date.
- One `CKDatabaseSubscription` on the zone so the other device is notified of changes;
  notifications only trigger a pull, they carry no data.

## 4. Sync engine (TimeCore)

- `SyncTransport` protocol: `fetchChanges(since token) -> (changes, deletions, newToken)`,
  `save(records) -> results`, `delete(recordNames) -> results`. One implementation on
  CloudKit, one in-memory fake that simulates the server for tests.
- `SyncEngine`: owns the cycle (R6): `pull()`, `applyRemote(batch)` (R3, R4, R7, R8),
  `push()` (drains the outbox, handles "record not found" per R4 and conflicts by
  re-fetching), `resolveRunningStints()` (R7). Everything is synchronous SQLite work plus
  async transport calls; the engine is an actor.
- `ChangeLog`: the only place that writes to `outbox`; all record writes go through
  `AppDatabase` helpers that call it inside the transaction (R5). The existing helpers
  (`insert`, `update`, `delete`, `start`, `stopRunning`, importer, `assignRepo`) gain
  that one call.
- Triggers: launch, app becomes active, 2 s after any local write (debounced), on a
  CloudKit notification, and every 5 minutes while the app runs.

## 5. Apps

- Mac: a status line in Settings → General (last sync, problems), the iCloud entitlement,
  a provisioning profile for Developer ID distribution with iCloud, and a "Sync now"
  button for debugging.
- iPhone: SwiftUI, sharing TimeCore. Screens: Stint (running entry, Stop, the month total
  per R15, Recent, assigned issues with search), Entries (the three-month window by day,
  edit, delete with confirmation), Settings (name, GitHub accounts, sync status). No
  reports, no CSV import. Starting from an issue, the search, and the data rules are the
  same code as on the Mac.
- Keychain: GitHub account items become synchronizable so the phone gets the tokens.

## 6. Signing and distribution

- Both targets get `com.apple.developer.icloud-container-identifiers` and
  `com.apple.developer.icloud-services: CloudKit`.
- Mac Developer ID builds need an embedded provisioning profile for iCloud; the release
  script and the CI workflow add it (one more secret).
- The iPhone app ships to your device through TestFlight or Xcode; App Store release is
  a later decision.
- The CloudKit schema is deployed from development to production with the CloudKit
  Console before the first release that syncs.

## 7. Error handling

- Transport errors never surface as alerts; they appear as the sync status line.
- A failed apply rolls back the whole batch and keeps the old token (R9).
- CloudKit quota or account problems disable sync with a status message; local use
  continues.

## 8. Testing

- Unit tests with the in-memory transport and two `AppDatabase` instances standing in for
  two devices. Each rule gets a test: identity on insert (R1), per-row LWW including the
  tie-break (R3), delete beats edit both ways (R4), outbox atomicity (R5), pull-then-push
  ordering (R6), two offline starts converge on the later one (R7), parent ordering and
  null references (R8), replaying a batch (R9), first sync of a populated database (R12),
  pruning outside the window without producing outbox entries (R14), month total with a
  running stint (R15).
- A convergence test: random interleaved edits on both devices with random sync points
  end with identical tables on both.
- No iOS UI tests. The Mac parity gate is unaffected because reporting code does not
  change.

## 9. Build order

1. Migration 3 and the outbox with the `AppDatabase` helpers writing to it; tests.
2. `SyncEngine` with the fake transport; the rule tests above.
3. Running-stint resolution (R7) and the convergence test.
4. CloudKit transport, entitlements, Mac status line; manual test with two Macs or a
   second user account.
5. iPhone app.
6. Release plumbing (profile, CI secret, CloudKit production schema).

## Decided

- The phone keeps the current month plus two (R14); the Mac and CloudKit keep everything.
- The phone shows the month's running total, unrounded (R15).
