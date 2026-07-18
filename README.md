# Anodyne

Anodyne is a Hammerspoon window-management configuration with its behavior separated from the native API boundary. The repository carries a fully project-local Lua test toolchain; no global Lua, LuaRocks, Busted, LuaCov, or StyLua installation is used.

## Local toolchain

The immutable pins are Lua 5.4.7, LuaRocks 3.13.0, Busted 2.3.0-1, LuaCov 0.17.0-1, and StyLua 2.5.2. The tool versions and every fetched LuaRock artifact are checksum-pinned in `tools/versions.env` and `tools/luarocks-artifacts.env`; `luarocks.lock` pins the resolved LuaRock versions.

From the repository root:

```sh
make bootstrap
make toolchain-check
```

The first bootstrap may download the pinned artifacts. An ordinary rerun restores or validates `.lua/` and `.tools/` from the verified cache and existing lock without rewriting the lock. If `.lua/` is reported partial, stale, or from another checkout, move that directory aside and rerun `make bootstrap`; the script deliberately will not reuse an unprovable environment.

Dependency changes are intentionally outside the normal workflow. `make deps-update` exits with instructions because updating pins, artifact hashes, and the lock requires a separate authorized network task. The one-time `tools/bootstrap --initialize-lock` mode refuses to run when `luarocks.lock` already exists.

## Architecture

The root `init.lua` is the only global migration boundary. It captures the previous `Anodyne` and transitional `WindowManager` values, asks the facade to replace them, publishes the new `_G.Anodyne` only after replacement succeeds, and clears `_G.WindowManager`.

```text
init.lua
  -> Anodyne/init.lua             facade, configuration, lifecycle
       -> Anodyne/config.lua      immutable config and metadata
       -> Anodyne/core/*          pure geometry, history, key interpretation
       -> Anodyne/adapter/hammerspoon.lua
            -> window_actions.lua
            -> controller.lua
            -> view.lua
            -> hs.*               sole native API boundary
```

The adapter owns native menus, canvases, filters, hotkeys, event taps, timers, window/screen ports, callbacks, and ordered retry-safe cleanup. `make architecture` enforces this boundary, rejects global access inside production modules, checks core dependencies, detects require cycles, and verifies the expected production sources remain covered by the LuaCov configuration.

## Tests and coverage

The final offline gate is:

```sh
make verify
```

It validates the pinned toolchain, formatting, the full Busted suite, raw coverage floors, and architecture. It does not start or contact Hammerspoon and does not read the smoke result.

Focused targets are available for faster iteration:

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

`make coverage` runs with milestone 7 by default. `coverage/luacov.report.out` is the human-readable line report and `coverage/summary.json` records raw hit, missed, and ratio values. Floors are compared using the unrounded ratios: config and geometry 95%, history and keymap 95%, window actions and controller 90%, view 85%, adapter 75%, and all `Anodyne/**` production code 85%. High coverage supplements the characterization and failure-path tests; it does not replace them.

## Reloading and native smoke

Reload through Hammerspoon in the usual way after placing this repository at `~/.hammerspoon`. A successful load exposes only `_G.Anodyne`; the former `_G.WindowManager` compatibility alias is removed. Reload first tears down prior modern and transitional resources. If teardown or replacement fails, the loader does not publish a partially started replacement or clear the previous globals.

The bounded native check is separate from offline verification:

```sh
make smoke
```

The wrapper never launches Hammerspoon. It contacts an already-running `hs` CLI endpoint for at most four seconds and the in-process script proceeds only when the dedicated `ANODYNE_SMOKE_SAFE=1` fixture flag is present, the `cmd+alt+ctrl+shift+F20` chord is free, and prior lifecycle state can be proved and restored. It registers only an `ANODYNE-SMOKE` menu/hotkey fixture and does not move, focus, or resize windows.

The machine-readable result is `coverage/smoke-status.json`:

- `PASS` means replacement, reload, cleanup, and exact prior-state restoration succeeded.
- `FAIL` means execution passed the mutation boundary but cleanup or restoration could not be proved; the command exits nonzero.
- `DEFERRED-ENVIRONMENT` means the safe flag, CLI connection, conflict check, or prior-state proof was unavailable before mutation. Deferral exits successfully so offline work can finish, but the native integration is not certified on that machine.
