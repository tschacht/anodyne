local Adapter = require("Anodyne.adapter.hammerspoon")
local Config = require("Anodyne.config")
local Geometry = require("Anodyne.core.geometry")
local FakeHs = require("spec.support.fake_hs")

local function assertNoResources(driver)
  assert.same({ timers = 0, menus = 0, hotkeys = 0, modals = 0, filters = 0, taps = 0, canvases = 0 }, driver:activeCounts())
end

describe("Hammerspoon adapter", function()
  local adapter, driver, owner

  local function start(currentGeneration)
    local config, metadata = Config.build()
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
    assert.same({ timers = 0, menus = 1, hotkeys = 1, modals = 1, filters = 2, taps = 0, canvases = 0 }, driver:activeCounts())
    assert.are.equal(owner.menu, driver.runtime.menus[1])
    assert.are.equal(owner.entryHotkey, driver.runtime.hotkeys[1])
    assert.are.equal(owner.windowMode, driver.runtime.modals[1])
    assert.same({ "ctrl", "alt", "cmd" }, owner.entryHotkey._state.modifiers)
    assert.are.equal("m", owner.entryHotkey._state.key)
    assert.is_false(owner.windowFilter._state.global)
    assert.is_true(owner.historyWindowFilter._state.global)
    assert.is_function(owner.windowFilter._state.callbacks[driver.hs.window.filter.windowFocused])
    assert.is_function(owner.historyWindowFilter._state.callbacks[driver.hs.window.filter.windowDestroyed])
  end)

  it("preserves menu order and turns menu intents into native callbacks", function()
    start()
    local items = driver:menuItems()
    assert.are.equal(47, #items)
    assert.are.equal("Keyboard Mode: ctrl+alt+cmd+M", items[1].title)
    assert.are.equal("Undo Last Action [U]", items[4].title)
    assert.are.equal("Shrink Width + Height [R S]", items[47].title)
    assert.is_nil(items[30].intent)
    assert.is_function(items[30].fn)
    items[30].fn()
    assert.same({ x = 50, y = 100, w = 800, h = 600 }, driver.runtime.focused._state.frame)
  end)

  it("converts modal events and owns canvas, tap, and timers only while active", function()
    start()
    driver:triggerEntry()
    assert.same({ 10, 11, 12 }, owner.modalKeyGuard._state.events)
    assert.same({ timers = 1, menus = 1, hotkeys = 1, modals = 1, filters = 2, taps = 1, canvases = 1 }, driver:activeCounts())
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
    assert.same({ timers = 0, menus = 1, hotkeys = 1, modals = 1, filters = 2, taps = 0, canvases = 0 }, driver:activeCounts())
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
      { "hotkey.bind", 1 },
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

  it("rejects a nil menu acquisition and reports unusable cleanup handles", function()
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

    local missing = Adapter.cleanupLegacy({ menu = {} })
    assert.matches("menu.delete: missing method", missing[1])
    local throwing = Adapter.cleanupLegacy({
      menu = setmetatable({}, {
        __index = function()
          error("injected member lookup failure")
        end,
      }),
    })
    assert.matches("injected member lookup failure", throwing[1])
  end)

  it("fails safely when any guarded native constructor returns nil", function()
    local cases = {
      { "filter.new", 1, "Failed to create focused-window filter", false },
      { "filter.new", 2, "Failed to create history window filter", false },
      { "modal.new", 1, "Failed to create window modal", false },
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

  it("replaces an outstanding menu-failure timer when modal rendering begins", function()
    start()
    driver:setFocused(nil)
    driver:setFrontmost(nil)
    owner.lastFocusedWindow = nil
    driver:menuItems()[30].fn()
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
    driver:menuItems()[30].fn()
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
