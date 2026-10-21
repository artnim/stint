# Product roadmap

Status: agreed 2026-10-15; business model revised 2026-10-21. Each phase gets its own spec
and plan before work starts.

## Goal

Make Stint useful to other freelancers who bill by the hour against tickets, and make it
pay: a free, open macOS app, a paid iPhone and Watch app, and paid integrations beyond
GitHub and GitLab. Stint stays local-first: no account, no server.

## Business model

- **Licence.** The core stays MIT and public. Paid integrations (Jira, Linear, later ones)
  live in a private Swift package that only App Store builds link. The public repo builds a
  complete free app without it.
- **Distribution.** One App Store record for macOS, iOS and watchOS (universal purchase).
  Free download everywhere. One-time (non-consumable) in-app purchases:
  - **"Stint for iPhone & Watch"** unlocks the iPhone and Watch apps. An optional free trial
    uses a price-tier-0 non-consumable named "XX-day Trial" (App Review Guideline 3.1.1).
  - **One purchase per extra integration** (Jira, Linear, …), usable on Mac and iPhone alike:
    universal purchase shares in-app purchases across the platforms of one record.
- **The free DMG** from GitHub releases stays available, built from the open repo. It has
  GitHub and GitLab only: in-app purchases need the App Store build, and Guideline 3.1.1
  forbids licence keys there.
- **Rejected:** a paid-upfront iPhone app (in a universal record the Mac app would be paid
  too; in a separate record integrations would have to be bought twice), licence keys
  (Paddle, Lemon Squeezy), iCloud-synced entitlements, a subscription.
- **Synced data is never locked.** An entry booked against a Jira issue on the Mac shows on a
  phone without the Jira purchase; the phone only cannot browse Jira issues.

### Free vs. paid

| Free (open, every platform where the app is unlocked) | Paid, one-time |
|---|---|
| Menu bar timer, entries, reports window | iPhone and Watch apps, including PDF reports on the iPhone |
| GitHub and GitLab issues | Jira (own purchase) |
| Monthly timesheet PDF, English and German | Linear (own purchase) |
| Branding: logo, address blocks, footer, colour, more languages | Each later integration (own purchase) |
| Hourly rates and amounts on reports | |
| iCloud sync, solidtime import | |

GitLab is free because it is open source and popular with the people likely to contribute.
Branding and rates are free because they make the Mac app worth recommending.

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

**Spike 2 result (2026-10-16): done, kept.** `TextStyle.attributed` builds its font and
paragraph style with Core Text instead of `NSFont`/`NSParagraphStyle`, and the PDF renderer
is no longer macOS-only. Mac output is pixel-identical to before; the iOS simulator renders
the same text, pages and fonts, differing only in glyph anti-aliasing.

### Phase 1: Monetization basics

- One App Store record for all three platforms; the "Stint for iPhone & Watch" in-app
  purchase (trial or not decided in the phase spec).
- `Entitlements` service in TimeCore: StoreKit 2 on App Store builds (iOS, watchOS, macOS),
  nothing purchasable in the open build. It already models one entitlement per integration.
- Private package boundary in `project.yml`: the open build compiles without it.
- iPhone and Watch apps behind the unlock; what they show before it is decided in the phase
  spec.
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

### Phase 3: iPhone PDF reports (part of the iPhone unlock)

Reports screen on the phone: month or preset, preview, share or save. The shared renderer
already runs on iOS (Phase 0, spike 2); the work is the screen and the presets.

### Phase 4: Jira and Linear (one purchase each, App Store builds only)

Jira Cloud with email plus API token; Linear with a personal API key. Neither needs OAuth,
so still no server or redirect host. OAuth only if customers ask for it.

### Phase 5: Branding and templates (free)

Logo, sender and recipient address blocks, footer text, accent colour, extra report
languages, stored per client. A user-editable layout language is deferred until users ask
for it.

### Phase 6: Rates and amounts (free)

Hourly rate per client or project, currency, amounts and totals on the report. Not a full
invoicing workflow.

## Order rationale

Monetization comes before GitLab because the iPhone and Watch apps already exist, so gating
them is the fastest path to revenue, and every user gained before that is a free one. The
tracker abstraction can wait because no paid integration depends on it until Phase 4.

## Out of scope

Teams, accounts, a server, web dashboards, export to Toggl or Harvest.
