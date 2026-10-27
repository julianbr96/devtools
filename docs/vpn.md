# VPN

The VPN tool shows and switches the tunnels of `darwin-vpn`, a local script (not part of this
repo) that runs one WireGuard tunnel per environment side by side with Homebrew's `wg-quick`.
The tool only calls that script. It never reads WireGuard configs or keys, and it knows the
environments only from what `darwin-vpn status` prints.

## Status

`darwin-vpn status` needs no password. DevTools runs it at launch, every 30 seconds, when the
menu-bar panel or the VPN page opens (if the last check is over 10 seconds old), and on
**Refresh** / ⌘R. Each `<env> <message>` line becomes a tunnel:

| `darwin-vpn status` says             | Shown as                        | Button     |
| ------------------------------------ | ------------------------------- | ---------- |
| `connected (utunN)`                  | Connected · utunN               | Disconnect |
| `NOT WORKING: …`                     | Up, but the VPN does not answer | Reconnect  |
| `disconnected; … DNS rules behind …` | Disconnected · old DNS rules    | Connect    |
| `disconnected`                       | Disconnected                    | Connect    |
| `connected through another VPN …`    | Connected through another VPN   | none       |
| `not set up; …`                      | Not set up                      | none       |
| anything else                        | Unrecognized status             | none       |

The status exits 1 whenever a tunnel is down, so the printed lines are the result, not the exit
code. If it prints no tunnel lines, its stderr is shown as the error.

## Connect and disconnect

`darwin-vpn up|down <env|all>` calls `sudo`, which needs a terminal. DevTools runs it through
`/usr/bin/osascript` with `do shell script … with administrator privileges` instead: macOS shows its
own password dialog every time, then the command runs as root with `PATH` set to Homebrew first,
then the system directories. Closing the dialog changes nothing and shows no error. The script's
output appears as a notice, its failure message as an error, and the status is read again either
way.

The executable path is interpolated into that root command, so Settings only accepts plain path
characters (letters, digits, `.`, `_`, `-`, `/`). Only choose a trusted `darwin-vpn`.

`darwin-vpn setup <env>` stays in Terminal: it reads the client config, private key included,
from the clipboard.

## Demo

`--demo` shows a connected `dev` and a disconnected `prod`, runs nothing and disables the buttons.

## Source map

All under `Sources/Tools/VPN/`:

- `VPN.swift`: status parsing, tunnel states and their actions, the administrator command and its outcome.
- `VPNStore.swift`: polling, refresh, connect/disconnect workflow and error messages.
- `VPNViews.swift`: menu-bar section, dashboard page and settings.
- `Tests/VPNTests.swift`: parsing, command safety, outcome handling and store workflows against fake commands.
