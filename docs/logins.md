# Logins

Shows who your command-line tools are signed in as, and logs in the ones that are not: AWS SSO
profiles, GitHub (`gh`) and Google Cloud (`gcloud`).

## AWS

The tool reads `~/.aws/config` (or `$AWS_CONFIG_FILE`) for section names and the non-secret SSO keys
only. Profiles are grouped by their `sso_session`: one `aws sso login` signs in every profile on a
session. A profile on a session of its own gets its own row and its own **Log in**, so it is signed in
separately; profiles that share a session show as one card with one **Log in**. A legacy profile with
its own `sso_start_url` is a session of one. Profiles without SSO are not listed.

To log in to accounts separately, give each profile its own `[sso-session <name>]` (same
`sso_start_url`, `sso_region` and `sso_registration_scopes`) and point its `sso_session` at it.

For each profile it runs `aws sts get-caller-identity --profile <name> --output json`, all at once,
when the page or tab opens (if the last check is over 5 minutes old) and on **Check all** / ⌘R:

- an identity → **Signed in**, with the account and the permission set from the assumed-role ARN;
- an SSO token error (expired, missing, refresh failed) → **Signed out**;
- anything else (network, permissions) → the CLI's first error line, never a false sign-out.

**Log in** runs `aws sso login --sso-session <name>` (`--profile <name>` for a legacy profile), which
opens the browser for approval, waits up to 5 minutes, then re-checks that session's profiles. While it
waits, **Cancel** stops the CLI (SIGTERM, then SIGKILL after 3 seconds) and re-checks nothing.

Every aws call drops `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`,
`AWS_CREDENTIAL_EXPIRATION`, `AWS_PROFILE` and `AWS_DEFAULT_PROFILE` from its environment, so credentials
exported by the shell that launched DevTools never override `--profile`. Commands that use `--profile`
or `AWS_PROFILE` pick up a new login right away; a shell that exported credentials into its environment
keeps the old ones until it exports again.

## Command-line tools

| Tool         | Signed in when                                                               | Log in runs                                 |
| ------------ | ---------------------------------------------------------------------------- | ------------------------------------------- |
| GitHub       | `gh auth status --hostname github.com` exits 0 (the account is shown)        | `gh auth login --web --hostname github.com` |
| Google Cloud | `gcloud auth list` has an active account **and** it can mint an access token | `gcloud auth login`                         |

The gcloud token check runs `/bin/sh -c "'<gcloud>' auth print-access-token --quiet >/dev/null"`, so
the token is discarded inside the shell and never reaches the app. Status checks drop `GH_TOKEN`,
`GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN`, `GITHUB_ENTERPRISE_TOKEN`, `CLOUDSDK_AUTH_ACCESS_TOKEN_FILE` and
`CLOUDSDK_CORE_ACCOUNT`, so they report the stored login, not a token from the launching shell.

These logins ask questions, so **Log in** writes `DevTools-login-<tool>.command` (mode 700) to the temp
directory and opens it, which runs it in Terminal. Only the CLI's plain path and fixed arguments go into
that script. The next time the tab or page opens, DevTools re-checks instead of using the cached status. Both CLIs
are also checked at launch and every 30 minutes, for the menu-bar icon.

A CLI found at none of `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` or `~/google-cloud-sdk/bin`
shows as not installed and runs nothing.

## Demo

`--demo` shows sample AWS sessions and CLI logins; nothing is run or opened.

## Source map

All under `Sources/Tools/Logins/`:

- `AWS.swift`: config parsing into sessions, caller-identity and error classification, role names.
- `AWSStore.swift`: concurrent checks, browser login, the credential variables every aws call drops.
- `CLILogins.swift`: GitHub and Google Cloud status parsing, the Terminal login script, `CLILoginStore`.
- `LoginsViews.swift`: menu-bar section and dashboard page for both.
- `Tests/AWSTests.swift`, `Tests/CLILoginTests.swift`: parsing, store flows against fake CLIs, env scrubbing.
