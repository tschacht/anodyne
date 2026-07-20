local Config = require("Anodyne.config")
local ObsCrop = require("Anodyne.core.obs_crop")
local Controller = require("Anodyne.obs_crop_controller")
local View = require("Anodyne.view")

describe("OBS crop controller", function()
  local controller, ports, log, target, screen, current

  local function rect(x, y, w, h)
    return { x = x, y = y, w = w, h = h }
  end

  before_each(function()
    local config, metadata = Config.build()
    target = { id = 41, frame = rect(100, 80, 777, 432) }
    screen = { id = "display-a", fullFrame = rect(-100, 0, 1920, 1080), scale = 2 }
    target.screen = screen
    current = true
    log = { alerts = {}, renders = {}, copies = {}, closes = 0 }
    ports = {
      currentGeneration = function()
        return current
      end,
      selectWindow = function()
        return target
      end,
      windowId = function(window)
        return window.id
      end,
      windowFrame = function(window)
        return window.frame
      end,
      windowScreen = function(window)
        return window.screen
      end,
      screenIdentity = function(value)
        return value.id
      end,
      screenFullFrame = function(value)
        return value.fullFrame
      end,
      screenScale = function(value)
        return value.scale
      end,
      renderGuide = function(...)
        log.renders[#log.renders + 1] = { ... }
        return true
      end,
      copy = function(value)
        log.copies[#log.copies + 1] = value
        return true
      end,
      close = function()
        log.closes = log.closes + 1
        return true
      end,
      alert = function(value, duration)
        log.alerts[#log.alerts + 1] = { value, duration }
        return true
      end,
    }
    controller = Controller.new({ config = config, crop = ObsCrop, view = View.new(config, metadata), ports = ports })
  end)

  local function enter()
    local ok, generation = controller:enter()
    assert.is_true(ok)
    return generation
  end

  it("enters only after rendering an exact arbitrary baseline snapshot", function()
    local original = target.frame
    local generation = enter()
    local state = controller:currentState()
    assert.same({ x = 100, y = 80, w = 777, h = 432 }, state.guideFrame)
    assert.are.equal(target, state.window)
    assert.are.equal(41, state.windowId)
    assert.are.equal("display-a", state.screenIdentity)
    assert.same(screen.fullFrame, state.screenFullFrame)
    assert.are.equal(2, state.scale)
    assert.are.equal(generation, state.generation)
    assert.are.equal(target, ports.selectWindow())
    assert.are.equal(original, target.frame)
    assert.same(
      { screen, screen.fullFrame, state.guideFrame, "Composition Mode:\nLocked baseline: 777 x 432\nReturn = Finish/Copy\nEsc = Cancel" },
      log.renders[1]
    )
  end)

  it("uses a positive override while still freezing the native screen scale", function()
    local config, metadata = Config.build({ obsCrop = { scaleOverride = 1.25 } })
    controller = Controller.new({ config = config, view = View.new(config, metadata), ports = ports })
    enter()
    assert.are.equal(1.25, controller:currentState().scale)
    assert.are.equal(2, controller:currentState().screenScale)
  end)

  it("does not commit active state for selection, snapshot, scale, or rendering failures", function()
    for _, name in ipairs({ "selectWindow", "windowId", "windowFrame", "windowScreen", "screenIdentity", "screenFullFrame", "screenScale", "renderGuide" }) do
      local original = ports[name]
      ports[name] = function()
        return false
      end
      assert.is_false(controller:enter(), name)
      assert.same({ kind = "inactive" }, controller:currentState())
      ports[name] = original
    end
  end)

  it("treats port exceptions like false returns and ignores alert failures", function()
    ports.alert = function()
      error("alert")
    end
    ports.windowFrame = function()
      error("frame")
    end
    assert.is_false(controller:enter())
    assert.same({ kind = "inactive" }, controller:currentState())
  end)

  it("rejects repeated enter without replacing the active session", function()
    local generation = enter()
    target.frame = rect(1, 2, 3, 4)
    assert.is_false(controller:enter())
    assert.are.equal(generation, controller:currentState().generation)
    assert.are.equal(1, #log.renders)
  end)

  it("finishes, copies exact formatted output, tears down, and reports success", function()
    local generation = enter()
    target.frame = rect(50, 40, 900, 520)
    assert.is_true(controller:finish(generation))
    assert.are.equal("Left: 100, Top: 80, Right: 146, Bottom: 96 | Result: 1554 x 864 | Scale: 2", log.copies[1])
    assert.are.equal(1, log.closes)
    assert.same({ kind = "inactive" }, controller:currentState())
    assert.are.equal(log.copies[1], log.alerts[#log.alerts][1])
    assert.is_false(controller:finish(generation))
    assert.is_false(controller:cancel(generation))
    assert.are.equal(1, log.closes)
    assert.are.equal(1, #log.copies)
  end)

  it("keeps outside-edge failures active and copies nothing", function()
    local generation = enter()
    target.frame = rect(101, 80, 900, 520)
    local ok, failure = controller:finish(generation)
    assert.is_false(ok)
    assert.same({ code = "outside_final", edge = "left" }, failure)
    assert.is_true(controller:isActive())
    assert.are.equal(0, #log.copies)
    assert.are.equal(0, log.closes)
  end)

  it("keeps pasteboard failures active for retry", function()
    local generation = enter()
    target.frame = rect(50, 40, 900, 520)
    ports.copy = function()
      error("pasteboard")
    end
    assert.is_false(controller:finish(generation))
    assert.is_true(controller:isActive())
    assert.are.equal(0, log.closes)
    ports.copy = function(value)
      log.copies[#log.copies + 1] = value
      return true
    end
    assert.is_true(controller:finish(generation))
  end)

  it("cancels untrustworthy target replacements and copies nothing", function()
    local generation = enter()
    target.id = 99
    assert.is_true(controller:finish(generation))
    assert.same({ kind = "inactive" }, controller:currentState())
    assert.are.equal(1, log.closes)
    assert.are.equal(0, #log.copies)
  end)

  it("cancels on screen identity, full-frame, and scale changes", function()
    for _, mutate in ipairs({
      function()
        screen.id = "display-b"
      end,
      function()
        screen.fullFrame.w = 1600
      end,
      function()
        screen.scale = 1
      end,
    }) do
      local generation = enter()
      mutate()
      assert.is_true(controller:finish(generation))
      assert.are.equal(0, #log.copies)
      screen.id, screen.fullFrame, screen.scale = "display-a", rect(-100, 0, 1920, 1080), 2
    end
    assert.are.equal(3, log.closes)
  end)

  it("classifies a missing current display scale as stale scale", function()
    local generation = enter()
    ports.screenScale = function()
      return nil
    end
    assert.is_true(controller:finish(generation))
    assert.matches("display scale changed", log.alerts[#log.alerts][1])
    assert.are.equal(0, #log.copies)
  end)

  it("cancels invalid final geometry rather than copying", function()
    local generation = enter()
    target.frame.w = 0
    assert.is_true(controller:finish(generation))
    assert.are.equal(0, #log.copies)
    assert.is_false(controller:isActive())
  end)

  it("ignores stale application and session generations", function()
    local generation = enter()
    assert.is_false(controller:finish())
    assert.is_false(controller:cancel())
    assert.is_false(controller:onDestroyed(target))
    assert.is_false(controller:finish(generation + 1))
    assert.is_false(controller:cancel(generation + 1))
    current = false
    assert.is_false(controller:onDestroyed(target, generation))
    assert.is_true(controller:isActive())
    assert.are.equal(0, log.closes)
  end)

  it("does not let a token captured from an earlier session affect a replacement", function()
    local oldGeneration = enter()
    assert.is_true(controller:cancel(oldGeneration))
    local newGeneration = enter()
    target.frame = rect(50, 40, 900, 520)

    assert.is_false(controller:finish(oldGeneration))
    assert.is_false(controller:cancel(oldGeneration))
    assert.is_false(controller:onDestroyed(target, oldGeneration))
    assert.is_true(controller:isActive())
    assert.are.equal(1, log.closes)
    assert.are.equal(0, #log.copies)

    assert.is_true(controller:finish(newGeneration))
    assert.are.equal(2, log.closes)
    assert.are.equal(1, #log.copies)
  end)

  it("cancels only when the pinned target is destroyed", function()
    local generation = enter()
    assert.is_false(controller:onDestroyed({}, generation))
    assert.is_true(controller:onDestroyed(target, generation))
    assert.are.equal(1, log.closes)
    assert.is_false(controller:onDestroyed(target, generation))
    assert.are.equal(1, log.closes)
  end)

  it("supports inactive and active cross-mode switching", function()
    assert.is_true(controller:crossMode())
    assert.are.equal(0, log.closes)
    local generation = enter()
    assert.is_true(controller:crossMode(generation))
    assert.are.equal(1, log.closes)
  end)

  it("allows explicit tokenless cross-mode teardown but rejects stale and globally invalid transitions", function()
    local generation = enter()
    assert.is_false(controller:crossMode(generation + 1))
    assert.are.equal(0, log.closes)
    assert.is_true(controller:crossMode())
    assert.are.equal(1, log.closes)

    enter()
    current = false
    assert.is_false(controller:crossMode())
    assert.are.equal(1, log.closes)
    assert.is_true(controller:isActive())
  end)

  it("retains all active state when teardown fails and retries it once per action", function()
    local generation = enter()
    local active = controller:currentState()
    ports.close = function()
      log.closes = log.closes + 1
      return false
    end
    assert.is_false(controller:cancel(generation))
    assert.are.equal(active, controller:currentState())
    assert.are.equal(1, log.closes)
    ports.close = function()
      log.closes = log.closes + 1
      return true
    end
    assert.is_true(controller:cancel(generation))
    assert.are.equal(2, log.closes)
    assert.same({ kind = "inactive" }, controller:currentState())
  end)
end)
