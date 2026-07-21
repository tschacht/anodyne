# Anodyne

Anodyne is a Hammerspoon window manager with a separate Composition Mode for calculating OBS window crops. Its Lua logic is separated from the Hammerspoon API boundary and covered by an offline unit, characterization, architecture, and coverage suite.

## Using Anodyne

Place the repository at `~/.hammerspoon` and reload the Hammerspoon configuration. The root `init.lua` starts Anodyne and publishes the running instance as `_G.Anodyne`.

Anodyne has two mutually exclusive top-level modes:

| Mode | Default shortcut | Purpose | Exit |
| --- | --- | --- | --- |
| Window Mode | `ctrl+alt+cmd+M` | Move, resize, and restore the focused window. | `escape` exits; the modal also uses `modalDuration` (8 seconds by default). |
| Composition Mode | `ctrl+alt+cmd+C` | Lock the current window frame as an OBS crop guide without moving or resizing it. | `Return` finishes and copies; `Esc` cancels. The active guide has no timeout. |

Only one mode can be active. Entering one cleanly exits or cancels the other.

While Window Mode is open:

- `A` selects an aspect-ratio preset.
- `W` or `H` selects an exact width or height preset.
- `M` opens movement and screen-position actions.
- `R` resizes the selected dimension or dimensions toward the next or previous grid boundary (50 px by default).
- `U` undoes the most recent action for the active window.
- `shift+U` restores the window frame captured when the modal opened.
- `delete` returns to the previous screen; `escape` exits.

The `WI` menu-bar item exposes the same actions and a separate Composition Mode entry. Defaults, including presets, minimum dimensions, step sizes, shortcuts, undo depth, and modal duration, are defined in `Anodyne/config.lua`.

## Composition Mode and OBS

Any positive-size current window frame is a valid Composition Mode baseline; its size and aspect ratio are copied verbatim. Entering Composition Mode never moves or resizes the window and never forces 16:9. If 16:9 is useful, optionally apply Window Mode's existing 16:9 preset first, exit Window Mode, and then enter Composition Mode.

Press `ctrl+alt+cmd+C` with the target window focused. Anodyne locks that window's current frame in absolute screen coordinates, draws a click-through guide with a 1-point border, dims only the area outside the guide, and keeps a click-through Window-Mode-style help/status modal visible for the entire session. Manually enlarge and reposition the same window so it contains the locked guide, then press `Return` to Finish/Copy. The guide closes and the status modal shows the result for `obsCrop.resultDuration` (4 seconds by default). Pressing `Esc` while the guide is active cancels without copying; pressing it during the result linger dismisses the result early and never clears the clipboard.

The clipboard contains exactly one line in this field order and format:

```text
Left: L, Top: T, Right: R, Bottom: B | Result: W x H | Scale: S
```

In OBS, select the macOS Screen Capture source configured for Window Capture, open **Edit Transform**, and enter `L`, `T`, `R`, and `B` into **Crop Left**, **Crop Top**, **Crop Right**, and **Crop Bottom**, respectively. `Result: W x H` is the expected cropped source size. Anodyne does not inspect or modify OBS: there is no OBS IPC, WebSocket integration, source discovery, UI automation, or automatic transform update.

Containment errors identify the locked-guide edge outside the final window, keep Composition Mode active, and copy nothing so the window can be corrected before retrying `Return`. A clipboard write failure likewise keeps the session active and reports the failure in the persistent status modal. A missing/replaced target or a change to the starting screen identity, full frame, or reported scale cancels stale geometry and copies nothing.

### Composition settings and scale calibration

The immutable configuration is built from these defaults in `Anodyne/config.lua`:

| Key | Default | Meaning |
| --- | ---: | --- |
| `compositionHotkey.modifiers` / `compositionHotkey.key` | `{ "ctrl", "alt", "cmd" }` / `"c"` | Composition Mode entry shortcut. |
| `obsCrop.scaleOverride` | `0` | `0` automatically freezes the starting screen's finite positive `screen:currentMode().scale`; a finite positive value overrides it verbatim for the session. |
| `obsCrop.resultDuration` | `4` | Seconds that a successful result remains visible; must be finite and positive. |
| `obsCrop.dimAlpha` | `0.45` | Exterior dim opacity; greater than zero and at most one. |
| `obsCrop.guideStrokeWidth` | `1` | Click-through guide border width in points; must be finite and positive. |

Calibrate once at the native EasyRes display mode. Confirm that Hammerspoon reports `scale=1` (use `screen:currentMode().scale` in the Hammerspoon Console), lock an arbitrary current frame, enlarge/reposition the window, copy the crops, enter all four values in OBS Edit Transform, and verify that all four cropped edges and `Result: W x H` match the locked guide. Repeat with a different baseline aspect ratio. If every crop value and result dimension is uniformly doubled or halved, set the explicit positive `obsCrop.scaleOverride` fallback (`0.5` or `2`, respectively), record the observed native-mode behavior, and repeat the comparison. Do not enable or add OBS IPC or automation for calibration.

Reloading is atomic from the loader's perspective: the current Anodyne instance is stopped before its replacement starts, and `_G.Anodyne` is updated only after replacement succeeds. Cleanup is ordered, retry-safe, and generation-guarded so callbacks from an older instance cannot affect the replacement.

## Architecture

```text
init.lua
  -> Anodyne/init.lua             facade, configuration, lifecycle
       -> Anodyne/config.lua      immutable defaults and metadata
       -> Anodyne/core/*          pure geometry, history, key interpretation, crop math
       -> Anodyne/obs_crop_controller.lua
                                  Composition session state machine
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

`make coverage` writes the line report to `coverage/luacov.report.out` and raw totals to `coverage/summary.json`. Coverage floors use unrounded ratios: config, geometry, history, keymap, and OBS crop math 95%; window actions, controller, and OBS crop controller 90%; view 85%; adapter 75%; and all production code under `Anodyne/` 85%.

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
