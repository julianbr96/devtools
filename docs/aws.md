# AWS sessions

Shows which AWS SSO profiles are signed in and logs in the ones that are not.

## Profiles

The tool reads `~/.aws/config` (or `$AWS_CONFIG_FILE`) for section names and the non-secret SSO keys
only. Profiles with `sso_session` are grouped under that `[sso-session …]`; one login signs in all of them.
A legacy profile with its own `sso_start_url` is a group of one. Profiles without SSO are not listed.

## Status

For each profile it runs `aws sts get-caller-identity --profile <name> --output json`, all at once,
when the page or tab opens (if the last check is over 5 minutes old) and on **Check all** / ⌘R:

- an identity → **Signed in**, with the account and the permission set from the assumed-role ARN;
- an SSO token error (expired, missing, refresh failed) → **Signed out**;
- anything else (network, permissions) → the CLI's first error line, never a false sign-out.

The check is read-only: it never assumes a role for use, writes credentials or reads the SSO token cache.

## Log in

**Log in** runs `aws sso login --sso-session <name>` (`--profile <name>` for a legacy profile), which opens
the browser for approval, waits up to 5 minutes, then re-checks that session's profiles. The CLI caches
the SSO token itself.

Every aws call drops `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`,
`AWS_CREDENTIAL_EXPIRATION`, `AWS_PROFILE` and `AWS_DEFAULT_PROFILE` from its environment, so credentials
exported by the shell that launched DevTools never override `--profile`. The other direction holds too:
commands that use `--profile` or `AWS_PROFILE` pick up a new login right away, but a shell that exported
credentials into its environment keeps the old ones until it exports again.

The CLI is looked up at `/opt/homebrew/bin/aws`, `/usr/local/bin/aws` and `~/.local/bin/aws`.

## Demo

`--demo` shows two sample sessions; nothing is run.

## Source map

All under `Sources/Tools/AWS/`:

- `AWS.swift`: config parsing into sessions, caller-identity and error classification, role names.
- `AWSStore.swift`: concurrent checks, login, the credential variables every call drops.
- `AWSViews.swift`: menu-bar section and dashboard page.
- `Tests/AWSTests.swift`: config shapes, status classification, store flows against a fake CLI, env scrubbing.
