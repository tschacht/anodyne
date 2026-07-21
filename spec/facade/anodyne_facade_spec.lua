local FakeHs = require("spec.support.fake_hs")

local function freshFacade()
  package.loaded.Anodyne = nil
  return require("Anodyne")
end

local function assertNoResources(driver)
  assert.same({ timers = 0, menus = 0, hotkeys = 0, modals = 0, filters = 0, taps = 0, canvases = 0 }, driver:activeCounts())
end

describe("Milestone 3 facade", function()
  local driver, Anodyne

  before_each(function()
    _G.Anodyne, _G.hs = nil, nil
    driver = FakeHs.new()
    Anodyne = freshFacade()
  end)

  after_each(function()
    driver:shutdown()
    package.loaded.Anodyne = nil
  end)

  it("requires inertly without reading hs or changing globals", function()
    local sentinel = {}
    _G.UNRELATED = sentinel
    _G.hs = setmetatable({}, {
      __index = function()
        error("hs was touched")
      end,
    })
    package.loaded.Anodyne = nil
    local facade = require("Anodyne")
    assert.is_function(facade.new)
    assert.are.equal(sentinel, _G.UNRELATED)
    assert.is_nil(_G.Anodyne)
    _G.UNRELATED = nil
    assertNoResources(driver)
  end)

  it("validates exact facade option keys and types", function()
    assert.has_error(function()
      Anodyne.new()
    end, "new options must be a table")
    assert.has_error(function()
      Anodyne.new({ hs = driver.hs, extra = true })
    end, "unknown new option: extra")
    assert.has_error(function()
      Anodyne.new({ hs = false })
    end, "new.hs must be a table")
    assert.has_error(function()
      Anodyne.new({ hs = driver.hs, modules = false })
    end, "new.modules must be a table")
    assert.has_error(function()
      Anodyne.new({ hs = driver.hs, modules = { other = function() end } })
    end, "unknown new.modules key: other")
    assert.has_error(function()
      Anodyne.new({ hs = driver.hs, modules = { runtimeFactory = true } })
    end, "new.modules.runtimeFactory must be a function")
    assert.has_error(function()
      Anodyne.replace({ hs = driver.hs, modules = {} })
    end, "unknown replace option: modules")
    assert.has_error(function()
      Anodyne.replace({ hs = driver.hs, previous = {} })
    end, "replace.previous.stop must be a function")
    assert.has_error(function()
      Anodyne.replace({ hs = driver.hs, previous = false })
    end, "replace.previous must be a table")
  end)

  it("uses a private validated runtime composition seam", function()
    local observed = {}
    local factory = function(instance, hs, config, generation)
      observed.instance = instance
      observed.hs = hs
      observed.config = config
      observed.current = generation.current()
      instance.menu = hs.menubar.new()
      instance.menu:setTitle(config.menuTitle)
    end
    local modules = { runtimeFactory = factory }
    local instance = Anodyne.new({ hs = driver.hs, modules = modules })
    modules.runtimeFactory = function()
      error("mutated composition seam")
    end
    assert.is_nil(rawget(instance, "runtimeFactory"))
    assertNoResources(driver)
    instance:start()
    assert.are.equal(instance, observed.instance)
    assert.are.equal(driver.hs, observed.hs)
    assert.are.equal(instance.config, observed.config)
    assert.is_true(observed.current)
    assert.same({ timers = 0, menus = 1, hotkeys = 0, modals = 0, filters = 0, taps = 0, canvases = 0 }, driver:activeCounts())
    assert.is_nil(select(2, instance:stop()))
    assertNoResources(driver)

    local failing = Anodyne.new({
      hs = driver.hs,
      modules = {
        runtimeFactory = function(candidate, hs)
          candidate.menu = hs.menubar.new()
          error("seam startup failure")
        end,
      },
    })
    assert.has_error(function()
      failing:start()
    end)
    assert.is_false(failing:isRunning())
    assertNoResources(driver)
  end)

  it("validates exact config and geometry composition contracts", function()
    assert.has_error(function()
      Anodyne.new({ hs = driver.hs, modules = { config = false } })
    end, "new.modules.config must be a table")
    assert.has_error(function()
      Anodyne.new({ hs = driver.hs, modules = { config = {} } })
    end, "new.modules.config.build must be a function")
    assert.has_error(function()
      Anodyne.new({ hs = driver.hs, modules = { config = { build = function() end, extra = true } } })
    end, "unknown new.modules.config key: extra")
    assert.has_error(function()
      Anodyne.new({ hs = driver.hs, modules = { geometry = false } })
    end, "new.modules.geometry must be a table")
    assert.has_error(function()
      Anodyne.new({ hs = driver.hs, modules = { geometry = {} } })
    end, "new.modules.geometry.round must be a function")

    local geometry = require("Anodyne.core.geometry")
    local extraGeometry = {}
    for key, value in pairs(geometry) do
      extraGeometry[key] = value
    end
    extraGeometry.extra = function() end
    assert.has_error(function()
      Anodyne.new({ hs = driver.hs, modules = { geometry = extraGeometry } })
    end, "unknown new.modules.geometry key: extra")
  end)

  it("keeps injected config metadata and geometry private and unaliased from module tables", function()
    local defaultConfig = require("Anodyne.config")
    local defaultGeometry = require("Anodyne.core.geometry")
    local configModule = { build = defaultConfig.build }
    local geometryModule = {}
    for key, value in pairs(defaultGeometry) do
      geometryModule[key] = value
    end
    local observed = {}
    local instance = Anodyne.new({
      hs = driver.hs,
      modules = {
        config = configModule,
        geometry = geometryModule,
        runtimeFactory = function(_, _, _, _, geometry, metadata)
          observed.geometry = geometry
          observed.metadata = metadata
        end,
      },
    })
    geometryModule.round = function()
      return 999
    end
    configModule.build = function()
      error("caller mutation leaked")
    end
    instance:start()
    assert.are.equal(2, observed.geometry.round(1.5))
    assert.are.equal("aspect", observed.metadata.modeByKey.a)
    assert.is_nil(rawget(instance, "geometry"))
    assert.is_nil(rawget(instance, "metadata"))
    assert.is_nil(rawget(instance, "configModule"))
  end)

  it("rejects malformed config module results", function()
    assert.has_error(function()
      Anodyne.new({ hs = driver.hs, modules = { config = {
        build = function()
          return {}, nil
        end,
      } } })
    end, "new.modules.config.build must return config and metadata tables")
  end)

  it("deep-merges maps, replaces lists, does not alias, and freezes config", function()
    local override = {
      symbols = { left = "L" },
      widthPresets = { 1111, 1222 },
      modalHotkey = { modifiers = { "alt" } },
    }
    local first = Anodyne.new({ hs = driver.hs, config = override, modules = { runtimeFactory = function() end } })
    local second = Anodyne.new({ hs = driver.hs })
    override.symbols.left = "changed"
    override.widthPresets[1] = 9
    assert.are.equal("L", first.config.symbols.left)
    assert.are.equal("↑", first.config.symbols.up)
    assert.same({ 1111, 1222 }, { first.config.widthPresets[1], first.config.widthPresets[2] })
    assert.are.equal(1000, second.config.widthPresets[1])
    assert.has_error(function()
      first.config.menuTitle = "bad"
    end, "configuration is immutable")
    assert.has_error(function()
      first.config.symbols.left = "bad"
    end, "configuration is immutable")
    assert.has_error(function()
      Anodyne.new({ hs = driver.hs, config = { unknown = true } })
    end, "unknown config key: unknown")
    assert.has_error(function()
      Anodyne.new({ hs = driver.hs, config = { widthPresets = { "bad" } } })
    end, "invalid config type for widthPresets[1]: expected number")
  end)

  it("preserves baseline construction for empty lists and partial aspect entries", function()
    local empty = Anodyne.new({
      hs = driver.hs,
      config = {
        widthPresets = {},
        heightPresets = {},
        aspectPresets = {},
        modalHotkey = { modifiers = {} },
      },
    }):start()
    assert.are.equal(0, #empty.config.widthPresets)
    assert.are.equal(0, #empty.config.heightPresets)
    assert.are.equal(0, #empty.config.aspectPresets)
    assert.are.equal(0, #empty.config.modalHotkey.modifiers)
    assert.is_nil(select(2, empty:stop()))

    local partial = Anodyne.new({
      hs = driver.hs,
      config = { aspectPresets = { { label = "partial", width = 1 } } },
    }):start()
    driver:triggerEntry()
    driver:key("a")
    local ok, message = pcall(function()
      driver:key("1")
    end)
    assert.is_false(ok)
    assert.matches("attempt to perform arithmetic on a nil value %(field 'height'%)", message)
    assert.is_nil(select(2, partial:stop()))
  end)

  it("constructs stopped and supports idempotent start and stop-start", function()
    local instance = Anodyne.new({ hs = driver.hs })
    assert.is_false(instance:isRunning())
    assert.are.equal(instance, instance:start())
    assert.are.equal(instance, instance:start())
    assert.is_true(instance:isRunning())
    assert.same({ timers = 0, menus = 1, hotkeys = 2, modals = 2, filters = 2, taps = 0, canvases = 0 }, driver:activeCounts())
    local stopped, errors = instance:stop()
    assert.are.equal(instance, stopped)
    assert.is_nil(errors)
    assert.is_false(instance:isRunning())
    assert.are.equal(instance, instance:stop())
    assertNoResources(driver)
    instance:start()
    assert.is_true(instance:isRunning())
  end)

  it("cleans every partial startup failure and permits direct retry", function()
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
      { "modal.bind", 1 },
      { "modal.bind", 2 },
      { "modal.bind", 3 },
      { "modal.bind", 4 },
      { "hotkey.bind", 2 },
    }
    for _, stage in ipairs(stages) do
      local candidate = FakeHs.new()
      candidate:setLifecycleFault(stage[1], stage[2])
      local instance = Anodyne.new({ hs = candidate.hs })
      assert.has_error(function()
        instance:start()
      end)
      assert.is_false(instance:isRunning(), stage[1] .. " should be stopped")
      assertNoResources(candidate)
      candidate:clearLifecycleFaults()
      assert.are.equal(instance, instance:start())
      assert.is_true(instance:isRunning())
      assert.is_nil(select(2, instance:stop()))
      assertNoResources(candidate)
    end
  end)

  it("rolls back nil entry-hotkey acquisitions and permits retry", function()
    for _, case in ipairs({
      { invocation = 1, message = "Failed to create/enable composition entry hotkey", field = "compositionEntryHotkey" },
      { invocation = 2, message = "Failed to create/enable entry hotkey", field = "entryHotkey" },
    }) do
      local candidate = FakeHs.new()
      local instance = Anodyne.new({ hs = candidate.hs })
      candidate:setLifecycleReturn("hotkey.bind", case.invocation, nil)
      local ok, message = pcall(function()
        instance:start()
      end)
      assert.is_false(ok)
      assert.matches(case.message, message, 1, true)
      assert.is_false(instance:isRunning())
      assert.is_nil(instance[case.field])
      assertNoResources(candidate)
      candidate:clearLifecycleReturns()
      assert.are.equal(instance, instance:start())
      assert.is_true(instance:isRunning())
      assert.is_nil(select(2, instance:stop()))
      assertNoResources(candidate)
    end
  end)

  it("reports retained native stop handles and reaches zero after retry", function()
    local instance = Anodyne.new({ hs = driver.hs }):start()
    driver:triggerEntry()
    local retained = instance.modalKeyGuard
    driver:setPersistentLifecycleFault("eventtap.stop")
    local _, errors = instance:stop()
    assert.is_table(errors)
    assert.matches("eventtap.stop", table.concat(errors, "\n"))
    assert.are.equal(retained, instance.modalKeyGuard)
    driver:clearLifecycleFaults()
    assert.is_nil(select(2, instance:stop()))
    assert.is_nil(instance.modalKeyGuard)
    assertNoResources(driver)
  end)

  it("reloads after modal timer and eventtap use with stop-only cleanup", function()
    local instance = Anodyne.new({ hs = driver.hs }):start()
    driver:triggerEntry()
    assert.are.equal(1, driver:activeCounts().timers)
    assert.are.equal(1, driver:activeCounts().taps)
    assert.is_nil(select(2, instance:stop()))
    assert.is_nil(instance.modalTimer)
    assert.is_nil(instance.modalKeyGuard)
    assertNoResources(driver)
    assert.are.equal(instance, instance:start())
    driver:triggerEntry()
    driver:advance(instance.config.modalDuration)
    assert.is_nil(instance.modalTimer)
    assert.is_nil(instance.modalKeyGuard)
    assert.is_nil(select(2, instance:stop()))
    assertNoResources(driver)
  end)

  it("attempts all ordered teardown stages and recovers a faulted instance", function()
    local instance = Anodyne.new({ hs = driver.hs }):start()
    driver:triggerEntry()
    driver:clearCallLog()
    driver:setLifecycleFault("hotkey.delete", 1)
    driver:setLifecycleFault("filter.unsubscribeAll", 1)
    local _, errors = instance:stop()
    assert.is_table(errors)
    assert.are.equal(2, #errors)
    assert.is_true(instance:isRunning())
    assert.has_error(function()
      instance:start()
    end, "Anodyne instance is faulted; call stop() until cleanup succeeds")
    local log = table.concat(driver:callLog(), ",")
    assert.matches("timer.stop", log)
    assert.matches("eventtap.stop", log)
    assert.matches("modal.delete", log)
    assert.matches("canvas.delete", log)
    assert.matches("menubar.delete", log)
    assert.matches("filter.unsubscribeAll#2", log)
    driver:clearLifecycleFaults()
    local _, retryErrors = instance:stop()
    assert.is_nil(retryErrors)
    assert.is_false(instance:isRunning())
    assertNoResources(driver)
    instance:start()
    assert.is_true(instance:isRunning())
  end)

  it("recovers when delete succeeds after an earlier stop failure", function()
    local instance = Anodyne.new({ hs = driver.hs }):start()
    driver:triggerEntry()
    driver:setLifecycleFault("timer.stop", 1)
    local _, errors = instance:stop()
    assert.is_table(errors)
    assert.is_true(instance:isRunning())
    driver:clearLifecycleFaults()
    assert.is_nil(select(2, instance:stop()))
    assert.is_false(instance:isRunning())
    assertNoResources(driver)
  end)

  it("aggregates startup and rollback failures while retaining failed handles", function()
    local instance = Anodyne.new({ hs = driver.hs })
    driver:setLifecycleFault("hotkey.bind", 1, "injected startup acquisition failure")
    driver:setLifecycleFault("menubar.delete", 1, "injected rollback cleanup failure")
    local ok, message = pcall(function()
      instance:start()
    end)
    assert.is_false(ok)
    assert.matches("injected startup acquisition failure", message)
    assert.matches("injected rollback cleanup failure", message)
    assert.is_true(instance:isRunning())
    local menuAcquisitions = driver.runtime.invocationCounts["menubar.new"]
    assert.has_error(function()
      instance:start()
    end, "Anodyne instance is faulted; call stop() until cleanup succeeds")
    assert.are.equal(menuAcquisitions, driver.runtime.invocationCounts["menubar.new"])
    driver:clearLifecycleFaults()
    assert.is_nil(select(2, instance:stop()))
    assert.is_false(instance:isRunning())
    assertNoResources(driver)
    instance:start()
    assert.is_true(instance:isRunning())
    assert.is_nil(select(2, instance:stop()))
    assertNoResources(driver)
  end)

  it("invalidates callbacks captured from an older generation", function()
    local instance = Anodyne.new({ hs = driver.hs }):start()
    local oldFocus = instance.windowFilter._state.callbacks.windowFocused
    local oldEntry = instance.entryHotkey._state.callback
    local other = driver:addWindow({ id = 42 })
    instance:stop()
    instance:start()
    local remembered = instance.lastFocusedWindow
    oldFocus(other)
    oldEntry()
    assert.are.equal(remembered, instance.lastFocusedWindow)
    assert.is_false(instance.modalState.active)
  end)

  it("stops the previous instance before starting its replacement", function()
    local calls = {}
    local previous = {
      stop = function(self)
        table.insert(calls, "previous.stop")
        return self, nil
      end,
    }
    local replacement = Anodyne.replace({
      hs = driver.hs,
      previous = previous,
    })
    assert.same({ "previous.stop" }, calls)
    assert.is_true(replacement:isRunning())
    assert.is_nil(select(2, replacement:stop()))
  end)

  it("aggregates prior errors and constructs no replacement", function()
    local calls = {}
    local previous = {
      stop = function(self)
        table.insert(calls, "previous")
        return self, { "returned one", "returned two" }
      end,
    }
    local ok, message = pcall(Anodyne.replace, {
      hs = driver.hs,
      previous = previous,
    })
    assert.is_false(ok)
    assert.matches("returned one", message)
    assert.matches("returned two", message)
    assert.same({ "previous" }, calls)
    assertNoResources(driver)
  end)

  it("normalizes thrown and scalar prior-stop errors without constructing a replacement", function()
    local throwing = {
      stop = function()
        error("thrown stop failure")
      end,
    }
    local ok, message = pcall(Anodyne.replace, { hs = driver.hs, previous = throwing })
    assert.is_false(ok)
    assert.matches("previous.stop", message)
    assert.matches("thrown stop failure", message)
    assertNoResources(driver)

    local scalar = {
      stop = function(self)
        return self, "scalar stop failure"
      end,
    }
    ok, message = pcall(Anodyne.replace, { hs = driver.hs, previous = scalar })
    assert.is_false(ok)
    assert.matches("previous.stop: scalar stop failure", message)
    assertNoResources(driver)
  end)

  it("assigns loader globals atomically only after replace succeeds", function()
    local oldAnodyne = {}
    _G.Anodyne, _G.hs = oldAnodyne, driver.hs
    local facade = package.loaded.Anodyne
    package.loaded.Anodyne = {
      replace = function()
        error("replacement failed")
      end,
    }
    assert.has_error(function()
      dofile("init.lua")
    end, "replacement failed")
    assert.are.equal(oldAnodyne, _G.Anodyne)

    local nextInstance = {}
    package.loaded.Anodyne = {
      replace = function(options)
        assert.are.equal(oldAnodyne, options.previous)
        return nextInstance
      end,
    }
    dofile("init.lua")
    assert.are.equal(nextInstance, _G.Anodyne)
    package.loaded.Anodyne = facade
  end)
end)
