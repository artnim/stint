# Product roadmap

Status: agreed 2026-10-15. Each phase gets its own spec and plan before work starts.

## Goal

Make Stint useful to other freelancers who bill by the hour against tickets, and make it
pay: an open, free macOS app, with paid features on the Mac and paid iPhone and Watch apps.
Stint stays local-first: no account, no server.

## Business model

- **Licence.** The core stays MIT and public. Pro features live in a private Swift package
  that only release builds link. The public repo builds a complete free app without it.
- **Distribution.** One App Store record for macOS, iOS and watchOS (universal purchase).
  Free download everywhere; a single non-consumable or yearly in-app purchase "Stint Pro"
  unlocks Pro on every platform. An upfront paid app is ruled out because it would make the
  Mac app paid too.
- **The free DMG** from GitHub releases stays available, built from the open repo, without Pro.
- Licence keys (Paddle, Lemon Squeezy) and iCloud-synced entitlements were considered and
  rejected: two billing systems, or a fragile setup close to App Store rule 3.1.1.

### Free vs. Pro

| Free (open) | Pro |
|---|---|
| Menu bar timer, entries, reports window | iPhone and Watch apps |
| GitHub and GitLab issues | Jira and Linear |
| Monthly timesheet PDF, English and German | Branding: logo, address blocks, footer, colour, more languages |
| iCloud sync between Macs | PDF reports on the iPhone |
| solidtime import | Hourly rates and amounts on reports |

GitLab is free because it is open source and popular with the people likely to contribute.

## Phases

### Phase 0: Spikes (throwaway)

1. **Mac sandbox.** Build a sandboxed variant (today `com.apple.security.app-sandbox` is
   `false`). Check: GitHub network access, Keychain tokens, CloudKit sync, the database in
   Application Support (container migration of the existing file), CSV import via open
   panel, PDF export via save panel. Output: a list of what breaks and what the fix costs.
2. **iPhone PDF.** Replace `NSFont` in `TimeCore/Sources/TimeCore/PDF/PDFStyles.swift` with
   `CTFont` (or a platform wrapper), render one month on the iOS simulator, compare with the
   Mac output.

Phase 1 depends on spike 1 succeeding at a reasonable cost.

**Spike 1 result (2026-10-16): go.** A sandboxed Debug build with only
`network.client` and `files.user-selected.read-write` added ran without kernel sandbox
denials. GitHub (Keychain token plus network), CloudKit sync (Development environment),
the save panel (PDF export outside the container) and the open panel all worked. Findings:

- `container-migration.plist` works but **moves** the source folder (Apple's docs say
  "copy"). After migration, a DMG copy on the same Mac finds its database gone and refills
  it from iCloud: the App Store build replaces the DMG on a Mac, and the docs must say so.
- The migration runs only when `~/Library/Containers/io.artnim.stint` does not exist; delete
  it before every migration test.
- A custom database folder (`databasePath`, a plain path) fails after relaunch with
  "Operation not permitted": needs a security-scoped bookmark.
- Fixed on main: the app crashed instead of showing its "cannot open database" alert; the
  Timetracker migration is removed.
- Not tested: Mac App Store signing (no Apple Distribution certificate or Mac App Store
  provisioning profile yet) and end-to-end delivery of CloudKit pushes to the sandboxed app.

### Phase 1: Monetization basics

- One App Store record for all three platforms; "Stint Pro" in-app purchase (one-time vs.
  yearly decided in the phase spec).
- `Entitlements` service in TimeCore: StoreKit 2 on App Store builds, always free in the open
  build.
- Private package boundary in `project.yml`: the open build compiles without it.
- iPhone and Watch apps gated behind Pro; the free behaviour (read-only or a trial) is decided
  in the phase spec.
- Sandboxed Mac App Store build: App Store configuration with sandbox entitlements,
  `container-migration.plist` for `${ApplicationSupport}/Stint`, security-scoped bookmark
  for a custom database folder, Apple Distribution certificate and provisioning profile.
- Ship: privacy policy, landing page, App Store listing.

### Phase 2: Tracker abstraction and GitLab (free)

- Schema migration: replace `repo`, `entry.repoId/issueNumber/issueTitle` and `issueCache`
  with a provider-neutral reference: provider, workspace, key, title, url. Existing entries
  migrate in place; CloudKit sync must keep working while devices run mixed versions.
- `TrackerProvider` protocol (assigned items, search, credentials); GitHub refactored onto it.
- GitLab: gitlab.com and self-hosted via base URL, personal access token, issues and merge
  requests.

### Phase 3: iPhone PDF reports (Pro)

Reports screen on the phone: month or preset, preview, share or save. Reuses the shared
renderer and rounding presets from Phase 0, spike 2.

### Phase 4: Jira and Linear (Pro)

Jira Cloud with email plus API token; Linear with a personal API key. Neither needs OAuth,
so still no server or redirect host. OAuth only if customers ask for it.

### Phase 5: Branding and templates (Pro)

Logo, sender and recipient address blocks, footer text, accent colour, extra report
languages, stored per client. A user-editable layout language is deferred until users ask
for it.

### Phase 6: Rates and amounts (Pro)

Hourly rate per client or project, currency, amounts and totals on the report. Not a full
invoicing workflow.

## Order rationale

Monetization comes before GitLab because the iPhone and Watch apps already exist, so gating
them is the fastest path to revenue, and every user gained before that is a free one. The
tracker abstraction can wait because no Pro feature depends on it until Phase 4.

## Out of scope

Teams, accounts, a server, web dashboards, export to Toggl or Harvest.
