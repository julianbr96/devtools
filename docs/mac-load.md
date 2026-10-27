# Mac load

Shows whether this Mac has room for heavy local work, and what is using it.

## What it reads

While its page or menu-bar tab is on screen it reads every 10 seconds (and on **Refresh** / ⌘R):

- **Memory free**: the `System-wide memory free percentage` from `/usr/bin/memory_pressure`, with a verdict:
  under 20% **Wait before heavy runs**, 20–24% **One heavy run at a time**, 25% and up **Fine to push**
  (the thresholds are `LoadVerdict.waitBelow` / `pushFrom`).
- **Swap used** (`vm.swapusage`), **disk free** on `/` (the capacity macOS reports for important use), RAM.
- **Heaviest apps**: `ps -axo pid=,rss=,%cpu=,comm=` grouped by app, so an app's helper processes count
  with the outermost `.app` and other processes by executable name. Resident memory overstates shared
  pages, so read it as a ranking, not an exact footprint.
- **Local servers**: `lsof -nP -iTCP -sTCP:LISTEN` without sudo lists only your own processes. macOS
  services (`/System`, `/usr/libexec`, `/usr/sbin`, `/usr/bin`, `/bin`, `/sbin`) and anything inside an
  `.app` bundle are left out, so the list is the dev servers, databases and tools you started.

## Stopping a server

**Stop** asks for a second click, re-reads the PID's command (a PID reused since the last refresh is never
signalled), then sends SIGTERM. If the process is still listening `MachineStore.forceAfter` seconds later,
**Force stop** sends SIGKILL. A process a launchd service keeps alive (e.g. `brew services`) comes back;
stop that one with its own command.

## Demo

`--demo` shows sample readings and two sample servers; nothing is read or signalled.

## Source map

All under `Sources/Tools/Machine/`:

- `Machine.swift`: verdict thresholds, `memory_pressure` / `ps` / `lsof` parsing, app grouping, system reading.
- `MachineStore.swift`: polling while visible, refresh, stop / force stop.
- `MachineViews.swift`: menu-bar section and dashboard page.
- `Tests/MachineTests.swift`: parsing against real output shapes, verdict boundaries, stop flows against a fake signal.
