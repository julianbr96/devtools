# Mac load

Shows whether this Mac has room for heavy local work and what is using it, and stops what you no
longer need.

## What it reads

While its page or menu-bar tab is on screen it reads every 10 seconds (and on **Refresh** / ⌘R). With
every view closed, only memory is read, every 30 seconds, for the menu-bar icon.

- **Memory free**: the `System-wide memory free percentage` from `/usr/bin/memory_pressure`, with a verdict:
  under 20% **Wait before heavy runs**, 20–24% **One heavy run at a time**, 25% and up **Fine to push**
  (the thresholds are `LoadVerdict.waitBelow` / `pushFrom`).
- **Swap used** (`vm.swapusage`), **disk free** on `/` (the capacity macOS reports for important use), RAM.
- **Processes**: `ps -axo pid=,ppid=,uid=,rss=,%cpu=,args=`, with each process's real executable from
  `proc_pidpath` (a process can rename itself in its command line).
- **Listening ports**: `lsof -nP -iTCP -sTCP:LISTEN`, which without sudo lists only your own processes.

## Who owns a process

A process belongs to the app it runs from (an app's helpers count with the outermost `.app`), or to the
app that launched it before any shell did: walking up its parents, an app reached before a shell (`zsh`,
`bash`, `login`, `tmux`, …) owns it, so Raycast's node backend belongs to Raycast. A process started
from a terminal reaches the shell first and belongs to no app; its group is named by the command it was
started as (`claude`, `node`), not by a versioned binary.

- **Local servers** are your own listeners that belong to no app and are not macOS services: the dev
  servers, databases and tools you started. Stop them when you are done to free memory.
- **Heaviest apps & processes** are the top groups by resident memory (it overstates shared pages, so
  read it as a ranking). Apps have **Quit**; a command-line tool expands into its processes, each with
  **Stop**. Groups made only of macOS processes are tagged **macOS** and have no actions.

## Quitting and stopping

Every action asks for a second click.

- **Quit** asks the app to close the way ⌘Q does (`NSRunningApplication.terminate`), so it can save or
  ask first. Still running `MachineStore.forceAfter` seconds later, **Force quit** ends it.
- **Stop** re-reads the PID's command line (a PID reused since the last refresh is never signalled), then
  sends SIGTERM. Still running after the same grace period, **Force stop** sends SIGKILL.
- Only your own processes outside the system paths (`/System`, `/usr/libexec`, `/usr/sbin`, `/usr/bin`,
  `/bin`, `/sbin`, `/Library/Apple`, `/private/var`) can be stopped, never one whose executable is
  unknown, and never DevTools itself. Apps under `/System` cannot be quit.
- Stopping a `claude` process ends that Claude Code session. A process a launchd service keeps alive
  (e.g. `brew services`) comes back; stop that one with its own command.

## Demo

`--demo` shows sample readings, servers and apps; nothing is read, stopped or quit.

## Source map

All under `Sources/Tools/Machine/`:

- `Machine.swift`: verdict thresholds, parsing, ownership and grouping, what may be signalled or quit.
- `MachineStore.swift`: polling while visible, refresh, stop / force stop, quit / force quit.
- `MachineViews.swift`: menu-bar section and dashboard page.
- `Tests/MachineTests.swift`: parsing against real output shapes, ownership, stop and quit flows against fakes.
