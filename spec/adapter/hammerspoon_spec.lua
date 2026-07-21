local Adapter = require("Anodyne.adapter.hammerspoon")
local Config = require("Anodyne.config")
local Geometry = require("Anodyne.core.geometry")
local FakeHs = require("spec.support.fake_hs")

local function assertNoResources(driver)
  assert.same({ timers = 0, menus = 0, hotkeys = 0, modals = 0, filters = 0, taps = 0, canvases = 0 }, driver:activeCounts())
end

local function mask(frame, alpha)
  return {
    type = "rectangle",
    action = "fill",
    fillColor = { red = 0, green = 0, blue = 0, alpha = alpha or 0.45 },
    frame = frame,
  }
end

local function border(frame, width)
  return {
    type = "rectangle",
    action = "stroke",
    strokeColor = { red = 1, green = 0.5, blue = 0, alpha = 1 },
    strokeWidth = width or 1,
    frame = frame,
  }
end

describe("Hammerspoon adapter", function()
  local adapter, driver, owner

  local function start(currentGeneration, overrides)
    local config, metadata = Config.build(overrides)
    owner = {}
    adapter = Adapter.new({
      owner = owner,
      hs = driver.hs,
      config = config,
      geometry = Geometry,
      metadata = metadata,
      currentGeneration = currentGeneration or function()
        return true
      end,
    })
    adapter:start()
    return owner
  end

  before_each(function()
    driver = FakeHs.new()
  end)

  after_each(function()
    if adapter then
      pcall(function()
        adapter:stop()
      end)
    end
    driver:shutdown()
  end)

  it("acquires exactly one native owner set with strict signatures and constants", function()
    start()
    assert.same({ timers = 0, menus = 1, hotkeys = 2, modals = 2, filters = 2, taps = 0, canvases = 0 }, driver:activeCounts())
    assert.are.equal(owner.menu, driver.runtime.menus[1])
    assert.are.equal(owner.entryHotkey, driver.runtime.hotkeys[2])
    assert.are.equal(owner.windowMode, driver.runtime.modals[1])
    assert.are.equal(owner.compositionMode, driver.runtime.modals[2])
    assert.same({ "ctrl", "alt", "cmd" }, owner.entryHotkey._state.modifiers)
    assert.are.equal("m", owner.entryHotkey._state.key)
    assert.same({ "ctrl", "alt", "cmd" }, owner.compositionEntryHotkey._state.modifiers)
    assert.are.equal("c", owner.compositionEntryHotkey._state.key)
    assert.same({ {}, {}, {}, {} }, {
      owner.compositionMode._state.bindings[1].modifiers,
      owner.compositionMode._state.bindings[2].modifiers,
      owner.compositionMode._state.bindings[3].modifiers,
      owner.compositionMode._state.bindings[4].modifiers,
    })
    assert.same({ "return", "escape", "s", "w" }, {
      owner.compositionMode._state.bindings[1].key,
      owner.compositionMode._state.bindings[2].key,
      owner.compositionMode._state.bindings[3].key,
      owner.compositionMode._state.bindings[4].key,
    })
    assert.is_false(owner.windowFilter._state.global)
    assert.is_true(owner.historyWindowFilter._state.global)
    assert.is_function(owner.windowFilter._state.callbacks[driver.hs.window.filter.windowFocused])
    assert.is_function(owner.historyWindowFilter._state.callbacks[driver.hs.window.filter.windowDestroyed])
  end)

  it("preserves menu order and turns menu intents into native callbacks", function()
    start()
    local items = driver:menuItems()
    assert.are.equal(57, #items)
    assert.are.equal("Keyboard Mode: ctrl+alt+cmd+M", items[1].title)
    assert.are.equal("Undo Last Action [U]", items[4].title)
    assert.are.equal("2560 x 1440 px [E 1]", items[8].title)
    assert.are.equal("Shrink both to previous 50 px [R S]", items[55].title)
    assert.is_nil(items[8].intent)
    assert.is_function(items[8].fn)
    items[8].fn()
    assert.same({ x = 100, y = 100, w = 2560, h = 1440 }, driver.runtime.focused._state.frame)
    driver:setWindowFrame(driver.runtime.focused, { x = 100, y = 100, w = 800, h = 600 })
    assert.is_nil(items[38].intent)
    assert.is_function(items[38].fn)
    items[38].fn()
    assert.same({ x = 50, y = 100, w = 800, h = 600 }, driver.runtime.focused._state.frame)
  end)

  it("uses native frame workarounds so a Dock-edge resize accepts the full step", function()
    local window = driver.runtime.focused
    driver:setWindowFrame(window, { x = 100, y = 480, w = 800, h = 600 })
    driver:setFault(window, "stickyEdgeWrite", 2)
    start()
    driver:triggerEntry()
    driver:key("r")
    driver:key("up")
    assert.same({ x = 100, y = 480, w = 800, h = 550 }, window:frame())
    assert.are.equal(1, driver.runtime.invocationCounts["window:setFrameWithWorkarounds"])
    assert.is_nil(driver.runtime.invocationCounts["window:setFrame"])
  end)

  it("converts modal events and owns canvas, tap, and timers only while active", function()
    start()
    driver:triggerEntry()
    assert.same({ 10, 11, 12 }, owner.modalKeyGuard._state.events)
    assert.same({ timers = 1, menus = 1, hotkeys = 2, modals = 2, filters = 2, taps = 1, canvases = 1 }, driver:activeCounts())
    assert.are.equal("overlay", owner.modalCanvas._state.level)
    assert.are.equal("canJoinAllSpaces", owner.modalCanvas._state.behavior)
    assert.are.equal("rectangle", owner.modalCanvas._state.elements[1].type)
    assert.are.equal("text", owner.modalCanvas._state.elements[2].type)
    assert.has_error(function()
      return owner.modalTimer.delete
    end, "fake_hs: unknown timer member delete")
    assert.has_error(function()
      return owner.modalKeyGuard.delete
    end, "fake_hs: unknown eventtap member delete")
    assert.is_false(driver:key("a", {}, "flagsChanged"))
    assert.is_true(driver:key("a", {}, "keyUp"))
    assert.is_true(driver:key("a", {}, "keyDown"))
    assert.are.equal("aspect", owner.modalState.screen)
    owner.windowMode:exit()
    assert.is_nil(owner.modalTimer)
    assert.is_nil(owner.modalKeyGuard)
    assert.same({ timers = 0, menus = 1, hotkeys = 2, modals = 2, filters = 2, taps = 0, canvases = 0 }, driver:activeCounts())
  end)

  it("guards native callbacks by generation", function()
    local current = true
    start(function()
      return current
    end)
    local other = driver:addWindow({ id = 42 })
    current = false
    driver:focus(other)
    driver:triggerEntry()
    assert.are.equal(driver.runtime.frontmost, owner.lastFocusedWindow)
    assert.is_false(owner.modalState.active)
  end)

  it("deletes an active modal without implicit exit while explicit exit still notifies", function()
    local modal = driver.hs.hotkey.modal.new()
    local hotkey = driver.hs.hotkey.bind({}, "x", function() end)
    local exited = 0
    function modal:entered() end
    function modal:exited()
      exited = exited + 1
    end
    modal:enter()
    driver:clearCallLog()
    driver:setPersistentLifecycleFault("modal.exit")
    modal:delete()
    hotkey:delete()
    assert.are.equal(0, exited)
    assert.is_nil(driver.runtime.invocationCounts["modal.exit"])
    assert.is_false(table.concat(driver:callLog(), ","):find("modal.exit", 1, true) ~= nil)
    assert.same({ timers = 0, menus = 0, hotkeys = 0, modals = 0, filters = 0, taps = 0, canvases = 0 }, driver:activeCounts())

    driver:clearLifecycleFaults()
    local explicit = driver.hs.hotkey.modal.new()
    function explicit:entered() end
    function explicit:exited()
      exited = exited + 1
    end
    explicit:enter()
    explicit:exit()
    assert.are.equal(1, exited)
    explicit:delete()
    assert.are.equal(1, exited)
  end)

  it("rolls back every native acquisition fault and can be started again", function()
    local stages = {
      { "menubar.new", 1 },
      { "filter.new", 1 },
      { "filter.new", 2 },
      { "window.frontmostWindow", 1 },
      { "menubar.setTitle", 1 },
      { "menubar.setTooltip", 1 },
      { "menubar.setMenu", 1 },
      { "filter.subscribe", 1 },
      { "filter.subscribe", 2 },
      { "modal.new", 1 },
      { "modal.new", 2 },
      { "hotkey.bind", 1 },
      { "hotkey.bind", 2 },
      { "modal.bind", 1 },
      { "modal.bind", 2 },
      { "modal.bind", 3 },
      { "modal.bind", 4 },
    }
    for _, stage in ipairs(stages) do
      local candidate = FakeHs.new()
      driver = candidate
      candidate:setLifecycleFault(stage[1], stage[2])
      local config, metadata = Config.build()
      owner = {}
      adapter = Adapter.new({
        owner = owner,
        hs = candidate.hs,
        config = config,
        geometry = Geometry,
        metadata = metadata,
        currentGeneration = function()
          return true
        end,
      })
      assert.has_error(function()
        adapter:start()
      end)
      assert.is_nil(adapter:stop())
      assertNoResources(candidate)
      candidate:clearLifecycleFaults()
      adapter:start()
      assert.is_nil(adapter:stop())
      assertNoResources(candidate)
      candidate:shutdown()
      adapter = nil
    end
  end)

  it("rejects a nil menu acquisition", function()
    local config, metadata = Config.build()
    local hs = setmetatable({
      menubar = {
        new = function()
          return nil
        end,
      },
    }, { __index = driver.hs })
    owner = {}
    adapter = Adapter.new({
      owner = owner,
      hs = hs,
      config = config,
      geometry = Geometry,
      metadata = metadata,
      currentGeneration = function()
        return true
      end,
    })
    assert.has_error(function()
      adapter:start()
    end, "Failed to create menu bar item")
  end)

  it("fails safely when any guarded native constructor returns nil", function()
    local cases = {
      { "filter.new", 1, "Failed to create focused-window filter", false },
      { "filter.new", 2, "Failed to create history window filter", false },
      { "modal.new", 1, "Failed to create window modal", false },
      { "modal.new", 2, "Failed to create composition modal", false },
      { "hotkey.bind", 1, "Failed to create/enable composition entry hotkey", false },
      { "hotkey.bind", 2, "Failed to create/enable entry hotkey", false },
      { "modal.bind", 1, "Failed to create Composition Finish/Copy binding", false },
      { "modal.bind", 2, "Failed to create Composition Cancel binding", false },
      { "modal.bind", 3, "Failed to create Composition Screen Capture binding", false },
      { "modal.bind", 4, "Failed to create Composition Window Capture binding", false },
      { "timer.doAfter", 1, "Failed to create timer", true },
      { "eventtap.new", 1, "Failed to create modal key guard", true },
      { "canvas.new", 1, "Failed to create modal canvas", true },
    }
    for _, case in ipairs(cases) do
      driver = FakeHs.new()
      driver:setLifecycleReturn(case[1], case[2], nil)
      local ok, message = pcall(function()
        start()
        if case[4] then
          driver:triggerEntry()
        end
      end)
      assert.is_false(ok)
      assert.is_not_nil(message:find(case[3], 1, true))
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("rejects every false modal binding acquisition and rolls back to zero", function()
    for invocation, message in ipairs({
      "Failed to create Composition Finish/Copy binding",
      "Failed to create Composition Cancel binding",
      "Failed to create Composition Screen Capture binding",
      "Failed to create Composition Window Capture binding",
    }) do
      driver = FakeHs.new()
      driver:setLifecycleReturn("modal.bind", invocation, false)
      assert.has_error(function()
        start()
      end, message)
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("renders a masked click-through guide and finishes through the pinned window", function()
    start()
    local window = driver.runtime.focused
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    local canvas = owner.compositionCanvas
    assert.is_true(owner.compositionMode._state.active)
    assert.same({ x = 0, y = 0, w = 1920, h = 1080 }, driver:canvasFrame(canvas))
    assert.are.equal("overlay", canvas._state.level)
    assert.is_true(canvas._state.mouseCallbackSet)
    local guideElements = driver:canvasElements(canvas)
    assert.same({
      mask({ x = 0, y = 0, w = 1920, h = 100 }),
      mask({ x = 0, y = 700, w = 1920, h = 380 }),
      mask({ x = 0, y = 100, w = 100, h = 600 }),
      mask({ x = 900, y = 100, w = 1020, h = 600 }),
      border({ x = 100, y = 100, w = 800, h = 600 }),
    }, guideElements)
    local maskArea = 0
    for index = 1, 4 do
      local frame = guideElements[index].frame
      maskArea = maskArea + frame.w * frame.h
    end
    assert.are.equal(1920 * 1080 - 800 * 600, maskArea)
    local help =
      "Composition Mode:\nLocked baseline: 800 x 600\nSelected source: Screen Capture\nS = Screen Capture · W = Window Capture\nReturn = Finish/Copy\nEsc = Cancel"
    local helpCanvas = owner.compositionStatusCanvas
    assert.same({ x = 696, y = 60, w = 528, h = 204 }, driver:canvasFrame(helpCanvas))
    assert.are.equal("overlay", helpCanvas._state.level)
    assert.are.equal("canJoinAllSpaces", helpCanvas._state.behavior)
    assert.is_true(helpCanvas._state.mouseCallbackSet)
    assert.same({
      {
        type = "rectangle",
        action = "fill",
        fillColor = { red = 0.08, green = 0.08, blue = 0.08, alpha = 0.92 },
        roundedRectRadii = { xRadius = 12, yRadius = 12 },
      },
      {
        type = "text",
        text = help,
        textSize = 20,
        textColor = { white = 1, alpha = 1 },
        textFont = "Menlo",
        textAlignment = "left",
        frame = { x = 20, y = 14, w = 488, h = 176 },
      },
    }, driver:canvasElements(helpCanvas))
    assert.is_nil(owner.compositionResultTimer)
    assert.are.equal(0, #driver:alerts())
    assert.same({ timers = 0, menus = 1, hotkeys = 2, modals = 2, filters = 2, taps = 0, canvases = 2 }, driver:activeCounts())

    assert.is_true(driver:triggerModalHotkey({}, "w"))
    driver:setWindowFrame(window, { x = 50, y = 40, w = 900, h = 700 })
    assert.is_true(driver:triggerModalHotkey({}, "return"))
    local expected = "Left: 50, Top: 60, Right: 50, Bottom: 40 | Result: 800 x 600 | Scale: 1"
    assert.are.equal("Window Capture | " .. expected, driver:clipboardContents())
    local resultCanvas = owner.compositionStatusCanvas
    assert.is_true(helpCanvas._state.deleted)
    assert.are.equal("Window Capture\n" .. expected, driver:canvasElements(resultCanvas)[2].text)
    assert.is_true(owner.compositionResultTimer._state.active)
    assert.is_true(owner.compositionMode._state.active)
    assert.is_true(canvas._state.deleted)
    assert.is_nil(owner.compositionCanvas)
    assert.same({ timers = 1, menus = 1, hotkeys = 2, modals = 2, filters = 2, taps = 0, canvases = 1 }, driver:activeCounts())
    driver:advance(3.999)
    assert.is_true(owner.compositionMode._state.active)
    assert.are.equal(resultCanvas, owner.compositionStatusCanvas)
    driver:advance(0.001)
    assert.is_false(owner.compositionMode._state.active)
    assert.is_true(resultCanvas._state.deleted)
    assert.is_nil(owner.compositionResultTimer)
    assert.is_nil(owner.compositionStatusCanvas)
    assert.are.equal("Window Capture | " .. expected, driver:clipboardContents())
  end)

  it("defaults visibly to Screen and refreshes only status for idempotent S/W selection", function()
    start()
    local target = driver.runtime.focused
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    local guide = owner.compositionCanvas
    local guideFrame = driver:canvasFrame(guide)
    local guideElements = driver:canvasElements(guide)
    local screenStatus = owner.compositionStatusCanvas
    local frameReads = #target._state.frameReads
    assert.matches("Selected source: Screen Capture", driver:canvasElements(screenStatus)[2].text)

    assert.is_true(driver:triggerModalHotkey({}, "s"))
    assert.are.equal(screenStatus, owner.compositionStatusCanvas)
    assert.are.equal(guide, owner.compositionCanvas)
    assert.are.equal(frameReads, #target._state.frameReads)

    assert.is_true(driver:triggerModalHotkey({}, "w"))
    local windowStatus = owner.compositionStatusCanvas
    assert.is_true(screenStatus._state.deleted)
    assert.matches("Selected source: Window Capture", driver:canvasElements(windowStatus)[2].text)
    assert.are.equal(guide, owner.compositionCanvas)
    assert.same(guideFrame, driver:canvasFrame(guide))
    assert.same(guideElements, driver:canvasElements(guide))
    assert.are.equal(frameReads, #target._state.frameReads)

    assert.is_true(driver:triggerModalHotkey({}, "w"))
    assert.are.equal(windowStatus, owner.compositionStatusCanvas)
    assert.are.equal(guide, owner.compositionCanvas)
    assert.are.equal(frameReads, #target._state.frameReads)

    assert.is_true(driver:triggerModalHotkey({}, "s"))
    assert.matches("Selected source: Screen Capture", driver:canvasElements(owner.compositionStatusCanvas)[2].text)
    assert.are.equal(guide, owner.compositionCanvas)
    assert.are.equal(frameReads, #target._state.frameReads)
  end)

  it("rolls back every status refresh stage without changing the visible Window selection", function()
    local faults = {
      { operation = "canvas.new", returnsNil = true },
      { operation = "canvas.level" },
      { operation = "canvas.behavior" },
      { operation = "canvas.mouseCallback" },
      { operation = "canvas.element" },
      { operation = "canvas.show" },
      { operation = "canvas.hide" },
      { operation = "canvas.delete" },
    }
    for _, fault in ipairs(faults) do
      driver = FakeHs.new()
      start()
      local target = driver.runtime.focused
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      assert.is_true(driver:triggerModalHotkey({}, "w"))
      local guide = owner.compositionCanvas
      local windowStatus = owner.compositionStatusCanvas
      local windowText = driver:canvasElements(windowStatus)[2].text
      local canvasCount = #driver.runtime.canvases
      local invocation = (driver.runtime.invocationCounts[fault.operation] or 0) + 1
      if fault.returnsNil then
        driver:setLifecycleReturn(fault.operation, invocation, nil)
      else
        driver:setLifecycleFault(fault.operation, invocation)
      end

      assert.is_true(driver:triggerModalHotkey({}, "s"))
      assert.are.equal(windowStatus, owner.compositionStatusCanvas)
      assert.is_true(windowStatus._state.visible)
      assert.is_not_true(windowStatus._state.deleted)
      assert.are.equal(windowText, driver:canvasElements(windowStatus)[2].text)
      assert.matches("Selected source: Window Capture", windowText)
      assert.are.equal(guide, owner.compositionCanvas)
      assert.same({ timers = 0, menus = 1, hotkeys = 2, modals = 2, filters = 2, taps = 0, canvases = 2 }, driver:activeCounts())
      if #driver.runtime.canvases > canvasCount then
        assert.is_true(driver.runtime.canvases[#driver.runtime.canvases]._state.deleted)
      end

      driver:clearLifecycleFaults()
      driver:clearLifecycleReturns()
      assert.is_true(driver:triggerModalHotkey({}, "w"))
      assert.are.equal(windowStatus, owner.compositionStatusCanvas)
      assert.is_true(driver:triggerModalHotkey({}, "s"))
      assert.matches("Selected source: Screen Capture", driver:canvasElements(owner.compositionStatusCanvas)[2].text)
      assert.is_true(driver:triggerModalHotkey({}, "w"))
      driver:setWindowFrame(target, { x = 50, y = 40, w = 900, h = 700 })
      assert.is_true(driver:triggerModalHotkey({}, "return"))
      local expected = "Left: 50, Top: 60, Right: 50, Bottom: 40 | Result: 800 x 600 | Scale: 1"
      assert.are.equal("Window Capture | " .. expected, driver:clipboardContents())
      assert.are.equal("Window Capture\n" .. expected, driver:canvasElements(owner.compositionStatusCanvas)[2].text)
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("retires a retained status candidate on Escape or top-level replacement before re-entry", function()
    for _, dismissal in ipairs({ "escape", "window" }) do
      driver = FakeHs.new()
      start()
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      assert.is_true(driver:triggerModalHotkey({}, "w"))
      local guide = owner.compositionCanvas
      local status = owner.compositionStatusCanvas
      driver:setPersistentLifecycleFault("canvas.delete")
      assert.is_true(driver:triggerModalHotkey({}, "s"))
      local candidate = owner.compositionStatusCandidateCanvas
      assert.is_not_nil(candidate)
      assert.is_false(candidate._state.visible)
      assert.are.equal(guide, owner.compositionCanvas)
      assert.are.equal(status, owner.compositionStatusCanvas)
      assert.is_true(status._state.visible)
      assert.matches("Selected source: Window Capture", driver:canvasElements(status)[2].text)

      driver:clearLifecycleFaults()
      if dismissal == "escape" then
        assert.is_true(driver:triggerModalHotkey({}, "escape"))
        assert.is_false(owner.compositionMode._state.active)
        assert.are.equal(0, driver:activeCounts().canvases)
      else
        driver:triggerEntry()
        assert.is_false(owner.compositionMode._state.active)
        assert.is_true(owner.windowMode._state.active)
        assert.are.equal(1, driver:activeCounts().canvases)
        assert.is_true(driver:key("escape"))
        assert.are.equal(0, driver:activeCounts().canvases)
      end
      assert.is_true(candidate._state.deleted)
      assert.is_nil(owner.compositionStatusCandidateCanvas)

      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      assert.is_true(owner.compositionMode._state.active)
      assert.is_not_nil(owner.compositionCanvas)
      assert.is_true(driver:triggerModalHotkey({}, "escape"))
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("never deletes a selector candidate whose hide failed and retries every cleanup path", function()
    for _, dismissal in ipairs({ "escape", "window", "stop" }) do
      driver = FakeHs.new()
      start()
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      assert.is_true(driver:triggerModalHotkey({}, "w"))
      local guide = owner.compositionCanvas
      local status = owner.compositionStatusCanvas
      local deletesBefore = driver.runtime.invocationCounts["canvas.delete"] or 0
      driver:setPersistentLifecycleFault("canvas.hide")
      assert.is_true(driver:triggerModalHotkey({}, "s"))
      local candidate = owner.compositionStatusCandidateCanvas
      assert.is_not_nil(candidate)
      assert.is_not_true(candidate._state.visible)
      assert.are.equal(deletesBefore, driver.runtime.invocationCounts["canvas.delete"] or 0)
      assert.are.equal(guide, owner.compositionCanvas)
      assert.are.equal(status, owner.compositionStatusCanvas)
      assert.is_true(status._state.visible)
      assert.matches("Selected source: Window Capture", driver:canvasElements(status)[2].text)

      driver:clearLifecycleFaults()
      assert.is_true(driver:triggerModalHotkey({}, "w"))
      assert.are.equal(candidate, owner.compositionStatusCandidateCanvas)
      assert.is_not_true(candidate._state.visible)
      assert.are.equal(status, owner.compositionStatusCanvas)
      assert.is_true(status._state.visible)
      assert.matches("Selected source: Window Capture", driver:canvasElements(status)[2].text)
      if dismissal == "stop" then
        assert.is_nil(adapter:stop())
        assertNoResources(driver)
      else
        if dismissal == "escape" then
          assert.is_true(driver:triggerModalHotkey({}, "escape"))
          assert.is_false(owner.compositionMode._state.active)
          assert.are.equal(0, driver:activeCounts().canvases)
        else
          driver:triggerEntry()
          assert.is_true(owner.windowMode._state.active)
          assert.are.equal(1, driver:activeCounts().canvases)
          assert.is_true(driver:key("escape"))
        end
        assert.is_true(candidate._state.deleted)
        assert.is_nil(owner.compositionStatusCandidateCanvas)
        driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
        assert.is_true(owner.compositionMode._state.active)
        assert.is_true(driver:triggerModalHotkey({}, "escape"))
        assert.is_nil(adapter:stop())
        assertNoResources(driver)
      end
      driver:shutdown()
      adapter = nil
    end
  end)

  it("keeps W, S-to-W, and repeated W on the identical shipped Window boundary", function()
    local expected = "Left: 50, Top: 60, Right: 50, Bottom: 40 | Result: 800 x 600 | Scale: 1"
    local expectedFinishLog = {
      "screen.currentMode#2",
      "pasteboard.setContents#1",
      "canvas.hide#2",
      "canvas.delete#2",
      "canvas.hide#3",
      "canvas.delete#3",
      "canvas.new#4",
      "canvas.level#4",
      "canvas.behavior#3",
      "canvas.mouseCallback#4",
      "canvas.element#10",
      "canvas.element#11",
      "canvas.show#4",
      "timer.doAfter#1",
    }
    for _, route in ipairs({ { "w" }, { "s", "w" }, { "w", "w" } }) do
      driver = FakeHs.new()
      start()
      local target = driver.runtime.focused
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      local guide = owner.compositionCanvas
      for _, key in ipairs(route) do
        assert.is_true(driver:triggerModalHotkey({}, key))
      end
      driver:setWindowFrame(target, { x = 50, y = 40, w = 900, h = 700 })
      local readsBeforeFinish = #target._state.frameReads
      driver:clearCallLog()
      assert.is_true(driver:triggerModalHotkey({}, "return"))
      assert.are.equal(readsBeforeFinish + 1, #target._state.frameReads)
      assert.are.equal("Window Capture | " .. expected, driver:clipboardContents())
      assert.are.equal("Window Capture\n" .. expected, driver:canvasElements(owner.compositionStatusCanvas)[2].text)
      assert.is_true(guide._state.deleted)
      assert.is_true(owner.compositionResultTimer._state.active)
      assert.same(expectedFinishLog, driver:callLog())
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("finishes Screen from the frozen display without a final window-frame read", function()
    start()
    local target = driver.runtime.focused
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    local readsBeforeFinish = #target._state.frameReads
    driver:setWindowFrame(target, { x = -700, y = 900, w = 3200, h = 25 })
    assert.is_true(driver:triggerModalHotkey({}, "return"))
    local expected = "Left: 100, Top: 100, Right: 1020, Bottom: 380 | Result: 800 x 600 | Scale: 1"
    assert.are.equal(readsBeforeFinish, #target._state.frameReads)
    assert.are.equal("Screen Capture | " .. expected, driver:clipboardContents())
    assert.are.equal("Screen Capture\n" .. expected, driver:canvasElements(owner.compositionStatusCanvas)[2].text)
  end)

  it("keeps selectors inert during result linger while Escape still dismisses early", function()
    start()
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    assert.is_true(driver:triggerModalHotkey({}, "return"))
    local status = owner.compositionStatusCanvas
    local timer = owner.compositionResultTimer
    assert.is_true(driver:triggerModalHotkey({}, "s"))
    assert.is_true(driver:triggerModalHotkey({}, "w"))
    assert.are.equal(status, owner.compositionStatusCanvas)
    assert.are.equal(timer, owner.compositionResultTimer)
    assert.is_true(driver:triggerModalHotkey({}, "escape"))
    assert.is_false(owner.compositionMode._state.active)
    assert.is_false(timer._state.active)
    assert.is_true(status._state.deleted)
  end)

  it("uses the configured guide stroke width override", function()
    start(nil, { obsCrop = { guideStrokeWidth = 2.5, dimAlpha = 0.7 } })
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    local elements = driver:canvasElements(owner.compositionCanvas)
    assert.are.equal(0.7, elements[1].fillColor.alpha)
    assert.are.equal(2.5, elements[5].strokeWidth)
  end)

  it("partitions negative-origin, edge-touching, and fractional clipped guides exactly", function()
    local cases = {
      {
        fullFrame = { x = -500, y = -300, w = 1920, h = 1080 },
        guide = { x = 100, y = 100, w = 800, h = 600 },
        elements = {
          mask({ x = 0, y = 0, w = 1920, h = 400 }),
          mask({ x = 0, y = 1000, w = 1920, h = 80 }),
          mask({ x = 0, y = 400, w = 600, h = 600 }),
          mask({ x = 1400, y = 400, w = 520, h = 600 }),
          border({ x = 600, y = 400, w = 800, h = 600 }),
        },
      },
      {
        fullFrame = { x = 0, y = 0, w = 1920, h = 1080 },
        guide = { x = 0, y = 0, w = 800, h = 600 },
        elements = {
          mask({ x = 0, y = 0, w = 1920, h = 0 }),
          mask({ x = 0, y = 600, w = 1920, h = 480 }),
          mask({ x = 0, y = 0, w = 0, h = 600 }),
          mask({ x = 800, y = 0, w = 1120, h = 600 }),
          border({ x = 0, y = 0, w = 800, h = 600 }),
        },
      },
      {
        fullFrame = { x = -100, y = -50, w = 1000, h = 800 },
        guide = { x = -150.25, y = 25.5, w = 1200.75, h = 900.25 },
        elements = {
          mask({ x = 0, y = 0, w = 1000, h = 75.5 }),
          mask({ x = 0, y = 800, w = 1000, h = 0 }),
          mask({ x = 0, y = 75.5, w = 0, h = 724.5 }),
          mask({ x = 1000, y = 75.5, w = 0, h = 724.5 }),
          border({ x = -50.25, y = 75.5, w = 1200.75, h = 900.25 }),
        },
      },
    }

    for _, case in ipairs(cases) do
      driver = FakeHs.new()
      driver:setFullFrame(driver.runtime.screens[1], case.fullFrame)
      driver:setWindowFrame(driver.runtime.focused, case.guide)
      start()
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      assert.same(case.fullFrame, driver:canvasFrame(owner.compositionCanvas))
      assert.same(case.elements, driver:canvasElements(owner.compositionCanvas))
      assert.is_true(owner.compositionCanvas._state.mouseCallbackSet)
      for index = 1, 4 do
        local frame = case.elements[index].frame
        assert.is_true(frame.x >= 0 and frame.y >= 0 and frame.w >= 0 and frame.h >= 0)
        assert.is_true(frame.x + frame.w <= case.fullFrame.w)
        assert.is_true(frame.y + frame.h <= case.fullFrame.h)
      end
      local guide = case.elements[5].frame
      local left = math.max(0, math.min(guide.x, case.fullFrame.w))
      local top = math.max(0, math.min(guide.y, case.fullFrame.h))
      local right = math.max(0, math.min(guide.x + guide.w, case.fullFrame.w))
      local bottom = math.max(0, math.min(guide.y + guide.h, case.fullFrame.h))
      local maskArea = 0
      for index = 1, 4 do
        local frame = case.elements[index].frame
        maskArea = maskArea + frame.w * frame.h
      end
      assert.are.equal(case.fullFrame.w * case.fullFrame.h - (right - left) * (bottom - top), maskArea)
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("recovers containment, pasteboard, and guide-close failures identically for every Window selector route", function()
    for _, route in ipairs({ { "w" }, { "s", "w" }, { "w", "w" } }) do
      for _, failure in ipairs({ "containment", "pasteboard", "close" }) do
        driver = FakeHs.new()
        start()
        local target = driver.runtime.focused
        driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
        for _, key in ipairs(route) do
          assert.is_true(driver:triggerModalHotkey({}, key))
        end
        if failure == "containment" then
          driver:setWindowFrame(target, { x = 101, y = 100, w = 900, h = 700 })
        else
          driver:setWindowFrame(target, { x = 50, y = 50, w = 900, h = 700 })
        end
        if failure == "pasteboard" then
          driver:setLifecycleReturn("pasteboard.setContents", 1, false)
        elseif failure == "close" then
          driver:setLifecycleFault("canvas.delete", (driver.runtime.invocationCounts["canvas.delete"] or 0) + 1)
        end

        assert.is_true(driver:triggerModalHotkey({}, "return"))
        local text = driver:canvasElements(owner.compositionStatusCanvas)[2].text
        if failure == "containment" then
          assert.matches("outside the final window", text)
          driver:setWindowFrame(target, { x = 50, y = 50, w = 900, h = 700 })
        elseif failure == "pasteboard" then
          assert.matches("Could not copy OBS crop values", text)
        else
          assert.matches("could not close", text)
        end
        assert.matches("Selected source: Window Capture", text)
        assert.matches("Locked baseline: 800 x 600", text)
        assert.matches("Return = Finish/Copy", text)
        assert.matches("Esc = Cancel", text)
        assert.is_true(owner.compositionMode._state.active)
        assert.is_not_nil(owner.compositionCanvas)
        assert.is_nil(owner.compositionResultTimer)

        assert.is_true(driver:triggerModalHotkey({}, "return"))
        assert.are.equal("Window Capture | Left: 50, Top: 50, Right: 50, Bottom: 50 | Result: 800 x 600 | Scale: 1", driver:clipboardContents())
        assert.is_true(owner.compositionResultTimer._state.active)
        assert.is_nil(owner.compositionCanvas)
        assert.is_true(driver:triggerModalHotkey({}, "escape"))
        assert.is_nil(adapter:stop())
        assertNoResources(driver)
        driver:shutdown()
        adapter = nil
      end
    end
  end)

  it("dismisses a lingering result early without changing the clipboard", function()
    start()
    local target = driver.runtime.focused
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    driver:setWindowFrame(target, { x = 50, y = 50, w = 900, h = 700 })
    assert.is_true(driver:triggerModalHotkey({}, "return"))
    local clipboard = driver:clipboardContents()
    local timer = owner.compositionResultTimer
    local status = owner.compositionStatusCanvas
    driver:advance(1)
    assert.is_true(driver:triggerModalHotkey({}, "escape"))
    assert.is_false(timer._state.active)
    assert.is_true(status._state.deleted)
    assert.is_false(owner.compositionMode._state.active)
    assert.are.equal(clipboard, driver:clipboardContents())
  end)

  it("dismisses lingering results before entering either top-level mode", function()
    for _, replacement in ipairs({ "window", "composition" }) do
      driver = FakeHs.new()
      start()
      local target = driver.runtime.focused
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      driver:setWindowFrame(target, { x = 50, y = 50, w = 900, h = 700 })
      assert.is_true(driver:triggerModalHotkey({}, "return"))
      local timer = owner.compositionResultTimer
      local status = owner.compositionStatusCanvas
      if replacement == "window" then
        driver:triggerEntry()
        assert.is_true(owner.windowMode._state.active)
        assert.is_false(owner.compositionMode._state.active)
      else
        driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
        assert.is_true(owner.compositionMode._state.active)
        assert.is_not_nil(owner.compositionCanvas)
        assert.is_nil(owner.compositionResultTimer)
      end
      assert.is_false(timer._state.active)
      assert.is_true(status._state.deleted)
      assert.is_not_nil(driver:clipboardContents())
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("keeps stale result timer callbacks inert after early dismissal", function()
    start()
    local target = driver.runtime.focused
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    driver:setWindowFrame(target, { x = 50, y = 50, w = 900, h = 700 })
    assert.is_true(driver:triggerModalHotkey({}, "return"))
    local stale = owner.compositionResultTimer._state.callback
    assert.is_true(driver:triggerModalHotkey({}, "escape"))
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    local guide = owner.compositionCanvas
    local status = owner.compositionStatusCanvas
    stale()
    assert.are.equal(guide, owner.compositionCanvas)
    assert.are.equal(status, owner.compositionStatusCanvas)
    assert.is_true(owner.compositionMode._state.active)
  end)

  it("cancels with Escape, fans target destruction out, and keeps stale callbacks inert", function()
    local current = true
    start(function()
      return current
    end)
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    local first = owner.compositionCanvas
    assert.is_true(driver:triggerModalHotkey({}, "escape"))
    assert.is_true(first._state.deleted)
    assert.is_nil(driver:clipboardContents())

    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    local second = owner.compositionCanvas
    driver:destroyWindow(driver.runtime.focused)
    assert.is_true(second._state.deleted)
    assert.matches("no longer available", driver:canvasElements(owner.compositionStatusCanvas)[2].text)
    assert.is_true(owner.compositionMode._state.active)
    assert.is_true(owner.compositionResultTimer._state.active)
    driver:advance(3.999)
    assert.is_true(owner.compositionMode._state.active)
    driver:advance(0.001)
    assert.is_false(owner.compositionMode._state.active)
    assert.is_nil(owner.compositionStatusCanvas)

    local replacement = driver:addWindow({ id = 43 })
    driver:setFocused(replacement)
    driver:setFrontmost(replacement)
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    assert.is_true(owner.compositionMode._state.active)
    assert.is_not.equal(second, owner.compositionCanvas)
    assert.is_true(driver:triggerModalHotkey({}, "escape"))

    current = false
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    assert.is_false(driver:triggerModalHotkey({}, "return"))
    assert.is_nil(owner.compositionCanvas)
    assert.is_nil(driver:clipboardContents())
  end)

  it("switches modes only after the active mode tears down cleanly", function()
    start()
    driver:triggerEntry()
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    assert.is_false(owner.windowMode._state.active)
    assert.is_true(owner.compositionMode._state.active)

    local retained = owner.compositionCanvas
    driver:setPersistentLifecycleFault("canvas.hide")
    driver:triggerEntry()
    assert.is_false(owner.windowMode._state.active)
    assert.is_true(owner.compositionMode._state.active)
    assert.are.equal(retained, owner.compositionCanvas)
    driver:clearLifecycleFaults()
    driver:triggerEntry()
    assert.is_true(owner.windowMode._state.active)
    assert.is_false(owner.compositionMode._state.active)

    owner.windowMode:exit()
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    driver:setLifecycleFault("modal.exit", (driver.runtime.invocationCounts["modal.exit"] or 0) + 1)
    driver:triggerEntry()
    assert.is_false(owner.windowMode._state.active)
    assert.is_true(owner.compositionMode._state.active)
    assert.matches("Composition Mode could not close", driver:canvasElements(owner.compositionStatusCanvas)[2].text)
    driver:triggerEntry()
    assert.is_true(owner.windowMode._state.active)
    assert.is_false(owner.compositionMode._state.active)
  end)

  it("retries native modal exit before Composition re-entry after destroy, Finish, or Cancel", function()
    for _, action in ipairs({ "destroy", "finish", "cancel" }) do
      driver = FakeHs.new()
      start()
      local target = driver.runtime.focused
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      local oldCanvas = owner.compositionCanvas
      driver:setLifecycleFault("modal.exit", (driver.runtime.invocationCounts["modal.exit"] or 0) + 1)

      if action == "destroy" then
        driver:destroyWindow(target)
        local replacement = driver:addWindow({ id = 99 })
        driver:setFocused(replacement)
        driver:setFrontmost(replacement)
      elseif action == "finish" then
        driver:setWindowFrame(target, { x = 50, y = 50, w = 900, h = 700 })
        assert.is_true(driver:triggerModalHotkey({}, "return"))
      else
        assert.is_true(driver:triggerModalHotkey({}, "escape"))
      end

      assert.is_true(oldCanvas._state.deleted)
      assert.is_true(owner.compositionMode._state.active)
      if action ~= "cancel" then
        assert.is_true(owner.compositionResultTimer._state.active)
        driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      end
      assert.matches("Composition Mode could not close", driver:canvasElements(owner.compositionStatusCanvas)[2].text)
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      assert.is_true(owner.compositionMode._state.active)
      assert.is_not.equal(oldCanvas, owner.compositionCanvas)
      assert.is_true(driver:triggerModalHotkey({}, "escape"))
      assert.is_false(owner.compositionMode._state.active)
      assert.is_false(driver:triggerModalHotkey({}, "escape"))
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("retries native modal exit before re-entry after an enter failure", function()
    start()
    driver:setLifecycleFault("canvas.level", 1)
    driver:setLifecycleFault("modal.exit", (driver.runtime.invocationCounts["modal.exit"] or 0) + 1)
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    local failed = owner.compositionCanvas
    assert.is_true(owner.compositionMode._state.active)
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    assert.is_true(failed._state.deleted)
    assert.is_true(owner.compositionMode._state.active)
    assert.matches("Composition Mode could not close", driver:canvasElements(owner.compositionStatusCanvas)[2].text)
    assert.is_nil(owner.compositionCanvas)
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    assert.is_not.equal(failed, owner.compositionCanvas)
  end)

  it("retains composition canvases across fallible setup and cleanup retries", function()
    for _, fault in ipairs({
      { "canvas.level", 1 },
      { "canvas.mouseCallback", 1 },
      { "canvas.element", 1 },
      { "canvas.element", 2 },
      { "canvas.element", 3 },
      { "canvas.element", 4 },
      { "canvas.element", 5 },
      { "canvas.show", 1 },
    }) do
      driver = FakeHs.new()
      start()
      driver:setLifecycleFault(fault[1], fault[2])
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      local failed = owner.compositionCanvas
      assert.are.equal(driver.runtime.canvases[1], failed)
      assert.are.equal(2, driver:activeCounts().canvases)
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      assert.is_true(failed._state.deleted)
      assert.is_not.equal(failed, owner.compositionCanvas)
      assert.is_true(owner.compositionMode._state.active)
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end

    for _, fault in ipairs({
      { "canvas.level", 2 },
      { "canvas.behavior", 1 },
      { "canvas.mouseCallback", 2 },
      { "canvas.element", 6 },
      { "canvas.element", 7 },
      { "canvas.show", 2 },
    }) do
      driver = FakeHs.new()
      start()
      driver:setLifecycleFault(fault[1], fault[2])
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      local failedStatus = driver.runtime.canvases[2]
      assert.is_true(failedStatus._state.deleted)
      assert.is_not.equal(failedStatus, owner.compositionStatusCanvas)
      assert.is_true(owner.compositionMode._state.active)
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      assert.is_true(owner.compositionMode._state.active)
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end

    driver = FakeHs.new()
    start()
    driver:setLifecycleFault("canvas.level", 1)
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    local failed = owner.compositionCanvas
    driver:setPersistentLifecycleFault("canvas.hide")
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    assert.are.equal(failed, owner.compositionCanvas)
    assert.are.equal(2, #driver.runtime.canvases)
    driver:clearLifecycleFaults()
    assert.is_nil(adapter:stop())
    assertNoResources(driver)
    driver:shutdown()
    adapter = nil

    for _, operation in ipairs({ "canvas.hide", "canvas.delete" }) do
      driver = FakeHs.new()
      start()
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      local retained = owner.compositionCanvas
      driver:setPersistentLifecycleFault(operation)
      assert.is_true(driver:triggerModalHotkey({}, "escape"))
      assert.are.equal(retained, owner.compositionCanvas)
      local errors = adapter:stop()
      assert.is_table(errors)
      assert.matches(operation, table.concat(errors, "\n"))
      driver:clearLifecycleFaults()
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("retains lingering result resources across timer and status teardown faults", function()
    for _, operation in ipairs({ "timer.stop", "canvas.hide", "canvas.delete" }) do
      driver = FakeHs.new()
      start()
      local target = driver.runtime.focused
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      driver:setWindowFrame(target, { x = 50, y = 50, w = 900, h = 700 })
      assert.is_true(driver:triggerModalHotkey({}, "return"))
      local timer = owner.compositionResultTimer
      local status = owner.compositionStatusCanvas
      driver:setPersistentLifecycleFault(operation)
      assert.is_true(driver:triggerModalHotkey({}, "escape"))
      if operation == "timer.stop" then
        assert.are.equal(timer, owner.compositionResultTimer)
      else
        assert.is_nil(owner.compositionResultTimer)
      end
      assert.are.equal(status, owner.compositionStatusCanvas)
      assert.is_true(owner.compositionMode._state.active)
      driver:clearLifecycleFaults()
      assert.is_true(driver:triggerModalHotkey({}, "escape"))
      assert.is_false(owner.compositionMode._state.active)
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end

    for _, returnValue in ipairs({ "nil", "false", "throw" }) do
      driver = FakeHs.new()
      start()
      local target = driver.runtime.focused
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      driver:setWindowFrame(target, { x = 50, y = 50, w = 900, h = 700 })
      if returnValue == "throw" then
        driver:setLifecycleFault("timer.doAfter", 1)
      else
        driver:setLifecycleReturn("timer.doAfter", 1, returnValue == "false" and false or nil)
      end
      assert.is_true(driver:triggerModalHotkey({}, "return"))
      assert.is_nil(owner.compositionResultTimer)
      assert.is_not_nil(owner.compositionStatusCanvas)
      assert.is_true(owner.compositionMode._state.active)
      assert.is_true(driver:triggerModalHotkey({}, "escape"))
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("retains a result status when timer-expiry teardown fails and retries with Escape", function()
    start()
    local target = driver.runtime.focused
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    driver:setWindowFrame(target, { x = 50, y = 50, w = 900, h = 700 })
    assert.is_true(driver:triggerModalHotkey({}, "return"))
    local status = owner.compositionStatusCanvas
    driver:setPersistentLifecycleFault("canvas.hide")
    driver:advance(4)
    assert.is_nil(owner.compositionResultTimer)
    assert.are.equal(status, owner.compositionStatusCanvas)
    assert.is_true(owner.compositionMode._state.active)
    driver:clearLifecycleFaults()
    assert.is_true(driver:triggerModalHotkey({}, "escape"))
    assert.is_false(owner.compositionMode._state.active)
  end)

  it("aggregates lingering timer and status cleanup faults and retries stop to zero", function()
    for _, operation in ipairs({ "timer.stop", "canvas.hide", "canvas.delete" }) do
      driver = FakeHs.new()
      start()
      local target = driver.runtime.focused
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      driver:setWindowFrame(target, { x = 50, y = 50, w = 900, h = 700 })
      assert.is_true(driver:triggerModalHotkey({}, "return"))
      local timer = owner.compositionResultTimer
      local status = owner.compositionStatusCanvas
      driver:setPersistentLifecycleFault(operation)
      local errors = adapter:stop()
      assert.is_table(errors)
      assert.matches(operation, table.concat(errors, "\n"))
      if operation == "timer.stop" then
        assert.are.equal(timer, owner.compositionResultTimer)
      else
        assert.are.equal(status, owner.compositionStatusCanvas)
      end
      driver:clearLifecycleFaults()
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("retries status teardown with modal Escape after active Cancel", function()
    for _, operation in ipairs({ "canvas.hide", "canvas.delete" }) do
      driver = FakeHs.new()
      start()
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      local status = owner.compositionStatusCanvas
      driver:setLifecycleFault(operation, 2)
      assert.is_true(driver:triggerModalHotkey({}, "escape"))
      assert.is_true(owner.compositionMode._state.active)
      assert.are.equal(status, owner.compositionStatusCanvas)
      assert.is_nil(owner.compositionCanvas)
      assert.is_true(driver:triggerModalHotkey({}, "escape"))
      assert.is_false(owner.compositionMode._state.active)
      assert.is_true(status._state.deleted)
      assert.is_nil(owner.compositionStatusCanvas)
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("retries status teardown on Window entry after Composition cross-mode", function()
    for _, operation in ipairs({ "canvas.hide", "canvas.delete" }) do
      driver = FakeHs.new()
      start()
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      local status = owner.compositionStatusCanvas
      driver:setLifecycleFault(operation, 2)
      driver:triggerEntry()
      assert.is_false(owner.windowMode._state.active)
      assert.is_true(owner.compositionMode._state.active)
      assert.are.equal(status, owner.compositionStatusCanvas)
      assert.is_nil(owner.compositionCanvas)
      driver:triggerEntry()
      assert.is_true(owner.windowMode._state.active)
      assert.is_false(owner.compositionMode._state.active)
      assert.is_true(status._state.deleted)
      assert.is_nil(owner.compositionStatusCanvas)
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("blocks Window to Composition replacement until every Window resource is gone", function()
    for _, operation in ipairs({ "timer.stop", "eventtap.stop", "canvas.hide", "canvas.delete" }) do
      driver = FakeHs.new()
      start()
      driver:triggerEntry()
      driver:setPersistentLifecycleFault(operation)
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      assert.is_false(owner.compositionMode._state.active)
      assert.is_nil(owner.compositionCanvas)
      assert.is_nil(owner.compositionStatusCanvas)
      assert.is_nil(owner.compositionResultTimer)
      assert.is_true(owner.modalState.active or owner.modalTimer ~= nil or owner.modalKeyGuard ~= nil or owner.modalCanvas ~= nil)
      if operation == "timer.stop" or operation == "eventtap.stop" then
        assert.matches("Window Mode could not close", driver:canvasElements(owner.modalCanvas)[2].text)
        assert.is_not_nil(owner.menuFailureTimer)
      end

      driver:clearLifecycleFaults()
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      assert.is_false(owner.modalState.active)
      assert.is_true(owner.compositionMode._state.active)
      assert.is_not_nil(owner.compositionCanvas)
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("rolls back blocked-entry failure UI when its timer constructor fails", function()
    for _, result in ipairs({ "nil", "false", "throw" }) do
      driver = FakeHs.new()
      start()
      driver:triggerEntry()
      driver:setPersistentLifecycleFault("eventtap.stop")
      local invocation = (driver.runtime.invocationCounts["timer.doAfter"] or 0) + 1
      if result == "throw" then
        driver:setLifecycleFault("timer.doAfter", invocation)
      else
        driver:setLifecycleReturn("timer.doAfter", invocation, result == "false" and false or nil)
      end
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      assert.is_false(owner.compositionMode._state.active)
      assert.is_nil(owner.menuFailureTimer)
      assert.is_nil(owner.modalCanvas)
      assert.is_nil(owner.compositionStatusCanvas)
      driver:clearLifecycleFaults()
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      assert.is_true(owner.compositionMode._state.active)
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("retains blocked-entry failure canvases across expiry faults and retries on entry", function()
    for _, operation in ipairs({ "canvas.hide", "canvas.delete" }) do
      driver = FakeHs.new()
      start()
      driver:triggerEntry()
      driver:setPersistentLifecycleFault("eventtap.stop")
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      local failureCanvas = owner.modalCanvas
      assert.matches("Window Mode could not close", driver:canvasElements(failureCanvas)[2].text)
      driver:clearLifecycleFaults()
      driver:setPersistentLifecycleFault(operation)
      driver:advance(2)
      assert.is_nil(owner.menuFailureTimer)
      assert.are.equal(failureCanvas, owner.modalCanvas)
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      assert.is_false(owner.compositionMode._state.active)
      assert.are.equal(failureCanvas, owner.modalCanvas)
      driver:clearLifecycleFaults()
      driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
      assert.is_true(owner.compositionMode._state.active)
      assert.is_true(failureCanvas._state.deleted)
      assert.is_nil(adapter:stop())
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("does not let inactive Composition bindings swallow Return, Escape, S, or W", function()
    start()
    assert.is_false(driver:triggerModalHotkey({}, "return"))
    assert.is_false(driver:triggerModalHotkey({}, "escape"))
    assert.is_false(driver:triggerModalHotkey({}, "s"))
    assert.is_false(driver:triggerModalHotkey({}, "w"))
    driver:triggerHotkey({ "ctrl", "alt", "cmd" }, "c")
    assert.is_true(driver:triggerModalHotkey({}, "escape"))
    assert.is_false(driver:triggerModalHotkey({}, "escape"))
  end)

  it("replaces an outstanding menu-failure timer when modal rendering begins", function()
    start()
    driver:setFocused(nil)
    driver:setFrontmost(nil)
    owner.lastFocusedWindow = nil
    driver:menuItems()[33].fn()
    local failureTimer = owner.menuFailureTimer
    assert.is_true(failureTimer._state.active)
    assert.are.equal(1, driver:activeCounts().canvases)
    driver:triggerEntry()
    assert.is_false(failureTimer._state.active)
    assert.is_nil(owner.menuFailureTimer)
    assert.is_true(owner.modalTimer._state.active)
    assert.are.equal(1, driver:activeCounts().canvases)
  end)

  it("retains timers and key guards after persistent stop faults until adapter retry", function()
    for _, operation in ipairs({ "timer.stop", "eventtap.stop" }) do
      driver = FakeHs.new()
      start()
      driver:triggerEntry()
      local field = operation == "timer.stop" and "modalTimer" or "modalKeyGuard"
      local retained = owner[field]
      driver:setPersistentLifecycleFault(operation)
      owner.windowMode:exit()
      assert.are.equal(retained, owner[field])
      local errors = adapter:stop()
      assert.is_table(errors)
      assert.matches(operation, table.concat(errors, "\n"))
      assert.are.equal(retained, owner[field])
      driver:clearLifecycleFaults()
      assert.is_nil(adapter:stop())
      assert.is_nil(owner[field])
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("retains canvases acquired before every fallible setup stage", function()
    for _, operation in ipairs({ "canvas.level", "canvas.behavior", "canvas.show" }) do
      driver = FakeHs.new()
      start()
      driver:setLifecycleFault(operation, 1)
      assert.has_error(function()
        driver:triggerEntry()
      end)
      assert.are.equal(driver.runtime.canvases[1], owner.modalCanvas)
      assert.are.equal(1, driver:activeCounts().canvases)
      assert.is_nil(adapter:stop())
      assert.is_nil(owner.modalCanvas)
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("retains a canvas across hide and delete faults until cleanup retry succeeds", function()
    for _, operation in ipairs({ "canvas.hide", "canvas.delete" }) do
      driver = FakeHs.new()
      start()
      driver:triggerEntry()
      local retained = owner.modalCanvas
      driver:setPersistentLifecycleFault(operation)
      owner.windowMode:exit()
      assert.are.equal(retained, owner.modalCanvas)
      local errors = adapter:stop()
      assert.is_table(errors)
      assert.matches(operation, table.concat(errors, "\n"))
      assert.are.equal(retained, owner.modalCanvas)
      driver:clearLifecycleFaults()
      assert.is_nil(adapter:stop())
      assert.is_nil(owner.modalCanvas)
      assertNoResources(driver)
      driver:shutdown()
      adapter = nil
    end
  end)

  it("refuses to overwrite retained menu timers, canvases, and key guards", function()
    start()
    driver:setFocused(nil)
    driver:setFrontmost(nil)
    owner.lastFocusedWindow = nil
    driver:menuItems()[33].fn()
    local retainedTimer = owner.menuFailureTimer
    driver:setPersistentLifecycleFault("timer.stop")
    assert.has_error(function()
      driver:triggerEntry()
    end)
    assert.are.equal(retainedTimer, owner.menuFailureTimer)
    driver:clearLifecycleFaults()
    assert.is_nil(adapter:stop())
    assertNoResources(driver)

    driver = FakeHs.new()
    start()
    driver:triggerEntry()
    local retainedCanvas = owner.modalCanvas
    driver:setPersistentLifecycleFault("canvas.hide")
    assert.has_error(function()
      driver:key("a")
    end)
    assert.are.equal(retainedCanvas, owner.modalCanvas)
    driver:clearLifecycleFaults()
    assert.is_nil(adapter:stop())
    assertNoResources(driver)

    driver = FakeHs.new()
    start()
    driver:triggerEntry()
    local retainedGuard = owner.modalKeyGuard
    driver:setPersistentLifecycleFault("eventtap.stop")
    owner.windowMode:exit()
    assert.has_error(function()
      owner.windowMode:enter()
    end)
    assert.are.equal(retainedGuard, owner.modalKeyGuard)
    driver:clearLifecycleFaults()
    assert.is_nil(adapter:stop())
    assertNoResources(driver)
  end)

  it("aggregates ordered cleanup faults, retains handles, and retries to zero", function()
    start()
    driver:triggerEntry()
    local hotkey, filter = owner.entryHotkey, owner.windowFilter
    driver:clearCallLog()
    driver:setLifecycleFault("hotkey.delete", 1)
    driver:setLifecycleFault("filter.unsubscribeAll", 1)
    local errors = adapter:stop()
    assert.are.equal(2, #errors)
    assert.are.equal(hotkey, owner.entryHotkey)
    assert.are.equal(filter, owner.windowFilter)
    local log = table.concat(driver:callLog(), ",")
    assert.matches("timer.stop", log)
    assert.matches("eventtap.stop", log)
    assert.matches("modal.delete", log)
    assert.matches("canvas.delete", log)
    assert.matches("menubar.delete", log)
    assert.matches("filter.unsubscribeAll#2", log)
    driver:clearLifecycleFaults()
    assert.is_nil(adapter:stop())
    assertNoResources(driver)
  end)
end)
