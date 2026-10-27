# CSWAP

The CSWAP tool is a native, local-only dashboard for an existing `claude-swap` installation.
It started as the standalone CSWAP Desktop app (0.3.0) and runs unchanged inside DevTools.

## Open

Pick **CSWAP** in the DevTools window's tool rail, or in the menu-bar panel's tabs, then click
**Connect to CSWAP**. Nothing calls the real CLI until you connect. The first quota lookup may ask for
Keychain access through CSWAP. It never switches an account automatically.

DevTools and the standalone CSWAP.app share account names, colors and switch history (the
local data file below), so either app shows changes made in the other.

## Features

- Menu-bar quick access: active login, cached quota, manual refresh, confirmed
  quick switches, and a button to reopen the dashboard. Opening the panel never
  invokes CSWAP or checks quota.
- On-demand **Use best account**: check quota, review the recommendation, then
  explicitly confirm a switch. No background account rotation.
- Local account names and seven color choices. Click the pencil beside an account
  name to customize it; blank name + default color restores the original display.
  Names/colors appear in the dashboard, menu panel, and switch reviews. CLI
  aliases and logins are not changed.
- Local switch history from the sidebar or menu panel's **History** button:
  time, previous/next account, and manual vs best-account action. Keeps the latest
  100 confirmed changes made through this app; clearing history asks first and
  leaves account appearances and credentials alone.
- All saved accounts, aliases, organizations, and the active login.
- Five-hour, weekly, and reported per-model quota, expressed as **remaining**.
- Reset countdowns, measurement age, stale-data labels, and error states.
- Confirmed switching via `cswap switch SLOT --json`; no forced switches.
- Guided account addition using Claude Code `/login`, then `cswap add`.
- Automatic refreshing is **off by default on every launch**. Settings can opt
  into one-minute refreshing while DevTools is running (including with the dashboard
  closed); manual refresh with **⌘R** remains available. A single shared poller
  pauses during account reviews.
- Executable selection in Settings for installations outside the default paths.

## Local appearance and history details

Appearance follows the email + organization UUID, not a mutable slot or CLI alias.
The app hashes that identity for the appearance lookup key. Resetting appearance
does not change a CSWAP alias. The same email in different organizations stays
separate.

History starts with this version; older activity is not reconstructed. Only a
successful schema-v1 `switched: true` response creates a record. Refresh, Cancel,
failed/uncertain responses, and no-op switches do not. Changes made in Terminal or
other apps are not monitored. Names and slots in history are snapshots from the
time of the switch, so later renaming does not rewrite old entries. An unknown or
unmanaged previous login is labeled as such.

Local file updates use a nonblocking lock, read-before-mutate and atomic
replacement to avoid partial writes or overwriting another instance's changes.
Corrupt/newer files are left untouched with a visible warning. If the CLI switch
succeeds but history saving fails, the app reports that distinction, retains a
bounded in-memory pending record, and offers **Retry local save**. Pending entries
are lost on Quit unless a later save succeeds.

## How “Use best account” works

1. Clicking the button runs `cswap list --json` to obtain a current snapshot.
2. The app compares the **smaller remaining percentage** of each account's
   five-hour and weekly limits. For example, 90% / 20% scores 20%, not 55%.
3. It excludes disabled alternatives and accounts lacking both usable, recent
   windows. Measurements older than five minutes, passed resets, last-good
   fallbacks, API keys, and unavailable quota do not qualify. The current account
   also needs comparable quota; otherwise no automatic recommendation is made.
4. Ties keep the active login. Among equally better alternatives, the earliest
   slot wins. If data is incomplete, the UI identifies the excluded accounts.
5. **Confirm switch** reads the list again and verifies the current identity,
   target identity, and winning recommendation have not changed. Only then does
   it invoke `cswap switch SLOT --json` for the exact account you approved.
   Cancel and no-improvement results do not switch anything.

This is the best **eligible account among available recent measurements**, not a
guarantee of live capacity. CSWAP controls caching/backoff. **Model-specific quotas
are not ranked**; inspect those in the dashboard for the model you intend to use.
No `switch --strategy best` command is issued before or after confirmation:
that command could immediately choose a different, unreviewed account.

## Important limits and privacy

This app has no server, analytics, hosted services, or app-owned credential store.
It reads only CSWAP's non-secret JSON output, not credential files or Keychain
tokens. Live account/quota snapshots exist only in memory. Account appearances and switch
history persist in `~/Library/Application Support/CSWAP/local-data.json` using a
private (0600) file and a newly created private (0700) app directory. This file
contains local display names/colors and, for recorded switches, account
names/emails/organizations, slots, timestamps and method—**no tokens, raw CLI
responses, or quota snapshots**. It is ordinary local JSON, not an encrypted vault.
The selected executable path is saved using macOS UserDefaults. CSWAP retains its own normal cache,
logging, and credential behavior. Its errors are redacted before display.

**Local-only is not offline:** CSWAP may call Anthropic, refresh OAuth tokens, and
update its own files/Keychain when listing usage. CSWAP's cache/backoff controls
freshness; repeated Refresh clicks cannot force new data or bypass rate limits.
Missing quota is never interpreted as 100% available. API-key accounts have no
subscription quota. Expired reset timestamps remain last-known, not automatically
replenished. Quota measurements over five minutes old are visually de-emphasized;
CSWAP's stronger unavailable / last-good status is always respected.

Switches affect the **global Claude login**, not isolated `cswap run` sessions.
Existing sessions can cache the old login; restart Claude Code for immediate use.
The app checks that a selected slot still represents the same email/organization
before switching. A concurrent external slot edit between that check and CSWAP's
switch remains possible: avoid editing slot assignments in another surface during
a switch. CLI credential locking and safety checks remain intact.

To add another account, save the current login first, then use `/login` in Claude
Code to sign in to the new one, and save again. Do **not** `/logout` first; it can
revoke a saved refresh token. Browser authentication stays in Claude Code—not in
this app. Removal, automatic rotation configuration, token entry, and export are
intentionally left to CSWAP.

Only choose a trusted CSWAP executable. It runs with the user's ordinary OS
permissions. The wrapper uses process argument arrays, never shell interpolation.
It does not silently approve interactive prompts. On timeout/failure, verify the
active login before retrying, since a write may already have completed.

## Demo and tests

Building and installing are in the [README](../README.md). For a safe visual preview with sample
data and all account writes disabled, run `open -n build/DevTools.app --args --demo`.

Demo does not invoke CSWAP or read/write real appearance/history files. It shows
one explicitly labeled sample history entry; appearance edits remain in memory. Sample dates are shifted to today while preserving
relative ages and reset offsets; live data is never adjusted. Quit it and relaunch normally to connect real accounts.
Tests use temporary fake executables and never touch real account state.

Integration target: installed `claude-swap` **0.26.0**, JSON schema **1**. Unknown
schemas fail closed. Upstream: <https://github.com/realiti4/claude-swap>.

## Source map

All under `Sources/Tools/CSWAP/`:

- `Dashboard.swift`: dashboard page, settings and add-account UI.
- `MenuSection.swift`: menu-bar quick access and cached quota.
- `Review.swift`: shared recommendation / switch confirmation UI.
- `Store.swift`: shared workflows, local metadata integration, preflight and opt-in polling.
- `LocalData.swift`: identity keys, appearance/history models and private atomic storage.
- `LocalViews.swift`: appearance editor, switch history and local-save warnings.
- `CLI.swift`: cswap's error envelope and messages over the shared process runner (`Sources/Core/ProcessRunner.swift`).
- `Models.swift`: JSON decoding, conservative best-account ranking, quota semantics, dates, redaction.
- `Tests/CSWAPTests.swift`: model, ranking, injected workflow, polling and subprocess checks.

## Validation boundary

The native app and process adapter are checked with fixtures. Actual account
switching and addition must be tested by the user: development deliberately does
not change existing accounts or credentials.
