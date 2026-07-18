# Anodyne

Anodyne is a Hammerspoon window manager for moving and resizing the focused macOS window. Its Lua logic is separated from the Hammerspoon API boundary and covered by an offline unit, characterization, architecture, and coverage suite.

## Using Anodyne

Place the repository at `~/.hammerspoon` and reload the Hammerspoon configuration. The root `init.lua` starts Anodyne and publishes the running instance as `_G.Anodyne`.

The default entry shortcut is `ctrl+alt+cmd+M`. While the modal is open:

- `A` selects an aspect-ratio preset.
- `W` or `H` selects an exact width or height preset.
- `M` opens movement and screen-position actions.
- `R` opens incremental resize actions.
- `U` undoes the most recent action for the active window.
- `shift+U` restores the window frame captured when the modal opened.
- `delete` returns to the previous screen; `escape` exits.

The `WI` menu-bar item exposes the same actions. Defaults, including presets, minimum dimensions, step sizes, shortcut, undo depth, and modal duration, are defined in `Anodyne/config.lua`.

Reloading is atomic from the loader's perspective: the current Anodyne instance is stopped before its replacement starts, and `_G.Anodyne` is updated only after replacement succeeds. Cleanup is ordered, retry-safe, and generation-guarded so callbacks from an older instance cannot affect the replacement.

## Architecture

```text
init.lua
  -> Anodyne/init.lua             facade, configuration, lifecycle
       -> Anodyne/config.lua      immutable defaults and metadata
       -> Anodyne/core/*          pure geometry, history, key interpretation
       -> Anodyne/adapter/hammerspoon.lua
            -> window_actions.lua
            -> controller.lua
            -> view.lua
            -> hs.*               native API boundary
```

The adapter owns menus, canvases, window filters, hotkeys, event taps, timers, window and screen ports, callbacks, and native-resource cleanup. Production modules do not access globals, and only the adapter may use native `hs` APIs. `make architecture` enforces these boundaries, checks dependency cycles, and verifies that every production source is included in coverage.

## Development toolchain

The repository uses a project-local toolchain; no global Lua ecosystem installation is required. It pins Lua 5.4.7, LuaRocks 3.13.0, Busted 2.3.0-1, LuaCov 0.17.0-1, and StyLua 2.5.2. Tool and LuaRock artifacts are checksum-pinned in `tools/versions.env` and `tools/luarocks-artifacts.env`, while `luarocks.lock` pins resolved rock versions.

Bootstrap and validate the toolchain from the repository root:

```sh
make bootstrap
make toolchain-check
```

The first bootstrap may download pinned artifacts. Later runs validate or restore `.lua/` and `.tools/` from the verified cache. If `.lua/` is reported as partial, stale, or associated with another checkout, move it aside and run `make bootstrap` again.

Dependency updates are intentionally separate from normal setup. `make deps-update` prints the required workflow because changing dependencies requires coordinated updates to versions, checksums, and the lock file.

## Tests and coverage

Run the complete offline validation gate with:

```sh
make verify
```

This checks the toolchain and formatting, runs the complete Busted suite, verifies raw LuaCov floors, and enforces the architecture. It neither starts nor contacts Hammerspoon.

Focused targets are available for development:

```sh
make test-core
make test-actions
make test-controller
make test-adapter
make test-facade
make test-characterization
make test-architecture
make test
make coverage
make format-check
make architecture
```

`make coverage` writes the line report to `coverage/luacov.report.out` and raw totals to `coverage/summary.json`. Coverage floors use unrounded ratios: config and geometry 95%; history and keymap 95%; window actions and controller 90%; view 85%; adapter 75%; and all production code under `Anodyne/` 85%.

## Native smoke test

The native smoke test exercises replacement, reload, cleanup, and exact restoration of the prior Anodyne lifecycle state against an already-running Hammerspoon process:

```sh
make smoke
```

The command requires Hammerspoon's bundled IPC module to be active. It can be enabled temporarily by entering this in the Hammerspoon Console:

```lua
require("hs.ipc")
```

You can verify the terminal connection before running the smoke test:

```sh
hs -c 'return "IPC OK"'
```

The smoke wrapper has a four-second bound. It proceeds only when its dedicated safety flag is present, the `cmd+alt+ctrl+shift+F20` chord is free, and the prior lifecycle state can be proven and restored. Its fixture registers only an `ANODYNE-SMOKE` menu and hotkey; it does not move, focus, or resize windows.

The machine-readable result is written to `coverage/smoke-status.json`:

- `PASS` means replacement, reload, cleanup, and prior-state restoration succeeded.
- `FAIL` means execution crossed the mutation boundary but cleanup or restoration could not be proved.
- `DEFERRED-ENVIRONMENT` means a precondition was unavailable before mutation.
