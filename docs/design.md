# Design notes

Stint is a single-user, local-first macOS menu bar time tracker. This note records the
decisions that shape the code; the README covers usage.

## Goals and non-goals

- One user, one machine, no server, no account. Data is a plain SQLite file the user owns.
- Timer-based tracking; hours are authoritative. GitHub supplies context (issues, pull
  requests, repositories), never hours. Nothing is ever written to GitHub.
- The client-facing PDF is produced by the app itself and must be reproducible from the
  raw data.
- Out of scope: teams, sync, idle detection, reminders, multiple concurrent timers, other
  issue trackers, a web or iOS client.

## Architecture

- **TimeCore** (Swift package, no UI): database access and migrations, the rounding and
  snapping rules, the report model, the PDF renderer, the CSV importer, and the GitHub
  client. Everything here is unit-tested from the command line.
- **App** (SwiftUI): a `MenuBarExtra` popover, an Entries window, a Reports window and
  Settings. It calls TimeCore's public API only and never imports the database library.

Storage is SQLite through GRDB: a portable file, explicit migrations, and observation for
SwiftUI. The GitHub tokens live in the Keychain, one per resource owner.

## Data model

| table | purpose |
|---|---|
| `client`, `project` | a project belongs to at most one client |
| `repo` | a GitHub repository, mapped to at most one project; the mapping routes issues to projects |
| `entry` | start and end as UTC instants, description, optional repo and issue number, tags; an entry without an end is the running timer (at most one, enforced by a partial unique index) |
| `issueCache` | open issues and pull requests of tracked repositories, plus those recently closed, with an "assigned to me" flag |
| `setting` | user name, report presets |

Duration is never stored; it is always end minus start. Reporting never modifies raw
data.

## Reporting rules

The report pipeline, in order: optional duration rounding to the grid; snapping of the
displayed start time to the grid; nudging a snapped start forward when snapping alone
would make consecutive entries overlap (real overlaps stay visible unless durations were
rounded, in which case they are artifacts); data-smell warnings on the raw entries; grouping
by day with subtotals. The displayed end is always snapped start plus duration, so the
report total is the sum of the (rounded) durations and nothing else.

Rounding defaults: a 15-minute grid, start snapped to the nearest step, durations
unrounded. The shipped "Monthly timesheet" preset rounds durations up and snaps starts up,
the convention for a German Leistungsnachweis.

Time zones: all instants are UTC; the report converts to a calendar with an explicit time
zone, so an entry across a DST change keeps its real length.

## GitHub integration

A fine-grained personal access token covers exactly one resource owner, so Settings keeps
a labelled list of tokens. A sync fetches the issues assigned to the user with every
token, plus every open issue (and those closed in the last 30 days) of each tracked
repository, trying the tokens in order until one can read it. Cached issues missing from
the merged result are marked closed only when every fetch succeeded, so a failing token
never hides another organisation's issues. The popover shows assigned issues by default
and searches the whole cache when a query is typed.

## Import

Settings → Import reads a solidtime "detailed" CSV export. Local timestamps are converted
with the current time zone; the HH:MM:SS duration column, which is exact and unaffected
by DST, takes precedence over the parsed end time. A hash of each row keeps re-imports
idempotent. See `docs/parity.md` for how the report output was verified against a
reference implementation.

## Error handling

Migrations run at launch; if one fails the app shows the error and quits rather than run
on a half-migrated file. GitHub failures never block tracking: the timer and the cache
work offline, a rejected token shows a banner naming it, other network errors stay
silent. Export errors are shown in the Reports window; the preview stays.
