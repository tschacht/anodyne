local Config = require("Anodyne.config")
local Controller = require("Anodyne.controller")
local Keymap = require("Anodyne.core.keymap")
local View = require("Anodyne.view")

describe("Anodyne controller", function()
  local controller, owner, state, actions, ports, timers, log, current

  before_each(function()
    local config, metadata = Config.build()
    owner = {}
    state = { active = false, screen = "home" }
    timers = {}
    log = { renders = {}, failures = {}, exits = 0, closes = 0, starts = 0, stops = 0, calls = {} }
    current = true
    actions = { snapshotCurrent = true }
    function actions:getModalHomeWindow()
      return nil
    end
    function actions:screenSnapshotIsCurrent()
      return self.snapshotCurrent
    end
    function actions:rememberFocused(window)
      log.focused = window
    end
    function actions:forgetWindow(window)
      log.destroyed = window
    end
    for _, name in ipairs({
      "undoLastFrame",
      "resetSessionFrame",
      "applyAspectPreset",
      "applyWidthPreset",
      "applyHeightPreset",
      "moveByStep",
      "moveToCorner",
      "resize",
    }) do
      actions[name] = function(_, ...)
        log.calls[#log.calls + 1] = { name, ... }
        return true, nil, name .. " ok"
      end
    end
    ports = {
      currentGeneration = function()
        return current
      end,
      schedule = function(delay, callback)
        local timer = { delay = delay, callback = callback, stopped = false }
        timers[#timers + 1] = timer
        return timer
      end,
      stopTimer = function(timer)
        timer.stopped = true
      end,
      exitMode = function()
        log.exits = log.exits + 1
      end,
      currentSize = function()
        return { width = 800, height = 600 }
      end,
      renderModal = function(message)
        log.renders[#log.renders + 1] = message
      end,
      renderFailure = function(message)
        log.failures[#log.failures + 1] = message
      end,
      closeOverlay = function()
        log.closes = log.closes + 1
      end,
      startKeyGuard = function()
        log.starts = log.starts + 1
      end,
      stopKeyGuard = function()
        log.stops = log.stops + 1
      end,
    }
    controller = Controller.new({
      owner = owner,
      state = state,
      config = config,
      metadata = metadata,
      actions = actions,
      keymap = Keymap.new(metadata),
      view = View.new(config, metadata),
      ports = ports,
    })
  end)

  it("enters, renders, pins state, and exits with complete cleanup", function()
    local window, frame, screen = {}, {}, {}
    controller:enter(window, frame, screen)
    assert.same({ active = true, screen = "home", targetWindow = window, sessionInitialFrame = frame, sessionInitialScreen = screen }, state)
    assert.are.equal(8, owner.modalTimer.delay)
    assert.are.equal(1, log.starts)
    assert.matches("^Window mode:", log.renders[1])
    controller:exit()
    assert.is_false(state.active)
    assert.is_nil(state.targetWindow)
    assert.is_true(timers[1].stopped)
    assert.are.equal(1, log.stops)
    assert.are.equal(1, log.closes)
  end)

  it("retains a timer and refuses replacement when native stop fails", function()
    local retained = { name = "retained" }
    owner.modalTimer = retained
    ports.stopTimer = function(timer)
      assert.are.equal(retained, timer)
      error("injected timer stop failure")
    end
    assert.has_error(function()
      controller:startModalTimer()
    end, "injected timer stop failure")
    assert.are.equal(retained, owner.modalTimer)
    assert.are.equal(0, #timers)
  end)

  it("implements exact event consumption without dispatch on keyUp or flags", function()
    assert.is_false(controller:handleEvent("keyDown", "a", {}))
    controller:enter({}, {}, {})
    local renders = #log.renders
    assert.is_false(controller:handleEvent("flagsChanged", nil, {}))
    assert.is_true(controller:handleEvent("keyUp", nil, {}))
    assert.is_true(controller:handleEvent("other", nil, {}))
    assert.are.equal(renders, #log.renders)
    assert.is_true(controller:handleEvent("keyDown", "a", {}))
    assert.are.equal("aspect", state.screen)
    current = false
    assert.is_false(controller:handleEvent("keyDown", "w", {}))
  end)

  it("dispatches preset availability, missing indexes, transitions, status, and exit", function()
    controller:enter({}, {}, {})
    controller:dispatch({ type = "preset", index = 1 })
    assert.matches("Number keys are not available", log.renders[#log.renders])
    for _, expected in ipairs({
      { "aspect", "applyAspectPreset", 6, "No aspect preset preset 6" },
      { "width", "applyWidthPreset", 8, "No width preset preset 8" },
      { "height", "applyHeightPreset", 5, "No height preset preset 5" },
    }) do
      controller:transition(expected[1])
      controller:dispatch({ type = "preset", index = expected[3] })
      assert.matches(expected[4], log.renders[#log.renders], 1, true)
      controller:dispatch({ type = "preset", index = 1 })
      assert.are.equal(expected[2], log.calls[#log.calls][1])
    end
    controller:dispatch({ type = "status", status = "hello" })
    assert.matches("Status: hello", log.renders[#log.renders])
    controller:dispatch({ type = "transition", screen = "bogus" })
    assert.matches("Unknown mode bogus", log.renders[#log.renders])
    controller:dispatch({ type = "exit" })
    assert.are.equal(1, log.exits)
  end)

  it("dispatches every action with resize labels and reports unknown actions", function()
    local intents = {
      { action = "undo" },
      { action = "reset" },
      { action = "aspect", value = {} },
      { action = "width", value = 1 },
      { action = "height", value = 2 },
      { action = "move", value = "left" },
      { action = "corner", value = "topleft" },
      { action = "resize", value = { label = "Shrink Width", deltaWidth = -50, deltaHeight = 0 } },
      { action = "resize", value = { label = "Grow Height", deltaWidth = 0, deltaHeight = 50 } },
    }
    for _, intent in ipairs(intents) do
      intent.type = "action"
      assert.is_true(controller:perform(intent))
    end
    assert.are.equal("Shrink Width -50 px", log.calls[8][4])
    assert.are.equal("Grow Height +50 px", log.calls[9][4])
    local ok, message = controller:perform({ action = "bogus" })
    assert.is_false(ok)
    assert.same({ kind = "unknown-action", action = "bogus" }, message)
  end)

  it("keeps bottom-corner success synchronous and failure visible", function()
    controller:enter({}, {}, {})
    state.screen = "move_bottom"
    controller:dispatch({ type = "action", action = "corner", value = "bottomleft", successScreen = "move" })
    assert.are.equal("move", state.screen)
    assert.matches("Status: moveToCorner ok", log.renders[#log.renders])
    actions.moveToCorner = function()
      return false, "target lost"
    end
    state.screen = "move_bottom"
    controller:dispatch({ type = "action", action = "corner", value = "bottomleft", successScreen = "move" })
    assert.are.equal("move_bottom", state.screen)
    assert.matches("Status: target lost", log.renders[#log.renders])
  end)

  it("requires generation, identity, and active state for modal timeout", function()
    controller:enter({}, {}, {})
    local first = owner.modalTimer
    controller:handleEvent("keyDown", "w", {})
    local second = owner.modalTimer
    assert.is_true(first.stopped)
    first.callback()
    assert.are.equal(0, log.exits)
    state.active = false
    second.callback()
    assert.are.equal(0, log.exits)
    state.active = true
    current = false
    second.callback()
    assert.are.equal(0, log.exits)
    current = true
    second.callback()
    assert.are.equal(1, log.exits)
  end)

  it("prevents stopped and stale refresh callbacks from redrawing a newer session", function()
    controller:enter({}, {}, {})
    controller:dispatch({ type = "action", action = "undo" })
    local first = owner.modalRefreshTimer
    controller:dispatch({ type = "action", action = "reset" })
    local second = owner.modalRefreshTimer
    local renders = #log.renders
    first.callback()
    assert.are.equal(renders, #log.renders)
    controller:exit()
    controller:enter({}, {}, {})
    second.callback()
    assert.are.equal(renders + 1, #log.renders)
    controller:dispatch({ type = "action", action = "undo" })
    local currentRefresh = owner.modalRefreshTimer
    currentRefresh.callback()
    assert.matches("Status: undoLastFrame ok", log.renders[#log.renders])
    assert.is_nil(owner.modalRefreshTimer)
  end)

  it("isolates inactive menu failure timers by identity and active state", function()
    actions.undoLastFrame = function()
      return false, "nothing"
    end
    controller:runMenu({ type = "action", action = "undo" })
    local first = owner.menuFailureTimer
    controller:runMenu({ type = "action", action = "undo" })
    local second = owner.menuFailureTimer
    local closes = log.closes
    first.callback()
    assert.are.equal(closes, log.closes)
    state.active = true
    second.callback()
    assert.are.equal(closes, log.closes)
    state.active = false
    second.callback()
    assert.are.equal(closes + 1, log.closes)
    assert.is_nil(owner.menuFailureTimer)
  end)

  it("routes active menu feedback, target loss, focus, destruction, and dynamic menu reset", function()
    controller:enter({}, {}, {})
    controller:runMenu({ type = "action", action = "undo" })
    assert.are.equal(0.05, owner.modalRefreshTimer.delay)
    actions.undoLastFrame = function()
      return false, "target lost"
    end
    controller:runMenu({ type = "action", action = "undo" })
    assert.matches("target lost", log.renders[#log.renders])
    controller:onFocused("focused")
    controller:onDestroyed("destroyed")
    assert.are.equal("focused", log.focused)
    assert.are.equal("destroyed", log.destroyed)
    actions.snapshotCurrent = false
    local reset = controller:menuItems()[5]
    assert.is_true(reset.disabled)
    assert.matches("screen configuration changed", reset.title)
  end)

  it("makes stale generation lifecycle and observers no-ops", function()
    current = false
    controller:enter({}, {}, {})
    controller:exit()
    controller:onFocused("x")
    controller:onDestroyed("y")
    controller:runMenu({ action = "undo" })
    assert.is_false(state.active)
    assert.is_nil(log.focused)
    assert.is_nil(log.destroyed)
    assert.are.equal(0, #timers)
  end)
end)
