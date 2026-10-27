# DevTools

A native macOS menu-bar app that puts everyday command-line tools behind one icon. Each tool is a
page in the dashboard window and a tab in the menu-bar panel. DevTools wraps the existing CLIs; it
never replaces them, stores their credentials, or talks to a server of its own.

## Tools

- **CSWAP**: saved Claude Code logins, remaining quota and confirmed account switches for
  [`claude-swap`](https://github.com/realiti4/claude-swap) (`cswap`). See [docs/cswap.md](docs/cswap.md).
- **VPN**: status, connect and disconnect for the tunnels of the `darwin-vpn` script, with the
  macOS password prompt instead of a terminal `sudo`. See [docs/vpn.md](docs/vpn.md).

## Build and install

Requires Apple's Command Line Tools (`swiftc`, `codesign`). No packages or network access.

```sh
./test.sh                                   # unit tests, fake commands only
./build.sh                                  # builds build/DevTools.app
./build.sh --install                        # also copies it to /Applications (quit DevTools first)
open -n build/DevTools.app --args --demo    # sample data, no CLI calls, actions disabled
```

Built for macOS 14 or later on the Mac that runs the build, ad-hoc signed and not notarized.
DevTools is a menu-bar accessory app: it does not appear in the Dock or Command-Tab. **Open
dashboard** in the panel brings the window back; closing the window leaves DevTools running.
**Quit DevTools** in the panel or ⌘Q stops it. ⌘R refreshes the tool on screen.

## Adding a tool

1. Create `Sources/Tools/<Name>/` with a store (an `ObservableObject` that runs its CLI through
   `ProcessRunner`, with the runner injectable for tests), a dashboard page and a menu-bar section.
2. Add a `Tool` case in `Sources/App/Shell.swift` (title and SF Symbol), its page in `ShellView` and
   its section in `MenuBarPanel`.
3. Own the store as a `@StateObject` in `Sources/App/DevToolsApp.swift`, pass it as an environment
   object to both scenes, and add its branch to the ⌘R command.
4. Add its non-UI sources to `test.sh` and its tests to `Tests/`, called from `Tests/Main.swift`.
5. Document it in `docs/<name>.md` and list it above.

In views, declare state with `@ViewState`, not `@State`: the macOS 27 SDK makes `@State` a macro
that the Command Line Tools cannot expand (see `Sources/Core/Theme.swift`).

## Layout

- `Sources/App/`: entry point, window shell with the tool rail, menu-bar panel.
- `Sources/Core/`: process runner (argument arrays, no shell, timeouts, pipe draining), theme, error type.
- `Sources/Tools/`: one folder per tool.
- `Tests/`: one suite per tool and the shared test entry point.
- `Scripts/MakeIcon.swift`: draws the app icon and packages the ICNS file.
