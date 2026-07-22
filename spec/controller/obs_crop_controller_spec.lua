local Config = require("Anodyne.config")
local ObsCrop = require("Anodyne.core.obs_crop")
local Controller = require("Anodyne.obs_crop_controller")
local View = require("Anodyne.view")

describe("OBS crop controller", function()
  local controller, ports, log, target, screen, current, config, metadata

  local function rect(x, y, w, h)
    return { x = x, y = y, w = w, h = h }
  end

  before_each(function()
    config, metadata = Config.build()
    target = { id = 41, frame = rect(100, 80, 777, 432) }
    screen = { id = "display-a", fullFrame = rect(-100, 0, 1920, 1080), scale = 2 }
    target.screen = screen
    current = true
    log = {
      alerts = {},
      renders = {},
      presentations = {},
      copies = {},
      closes = 0,
      copyCalls = 0,
      windowIdReads = 0,
      frameReads = 0,
      screenReads = 0,
      identityReads = 0,
      fullFrameReads = 0,
      scaleReads = 0,
    }
    ports = {
      currentGeneration = function()
        return current
      end,
      selectWindow = function()
        return target
      end,
      windowId = function(window)
        log.windowIdReads = log.windowIdReads + 1
        return window.id
      end,
      windowFrame = function(window)
        log.frameReads = log.frameReads + 1
        return window.frame
      end,
      windowScreen = function(window)
        log.screenReads = log.screenReads + 1
        return window.screen
      end,
      screenIdentity = function(value)
        log.identityReads = log.identityReads + 1
        return value.id
      end,
      screenFullFrame = function(value)
        log.fullFrameReads = log.fullFrameReads + 1
        return value.fullFrame
      end,
      screenScale = function(value)
        log.scaleReads = log.scaleReads + 1
        return value.scale
      end,
      renderGuide = function(...)
        log.renders[#log.renders + 1] = { ... }
        return true
      end,
      refreshPresentation = function(value, labels)
        log.presentations[#log.presentations + 1] = { help = value, labels = labels }
        return true
      end,
      copy = function(value)
        log.copyCalls = log.copyCalls + 1
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

  local function cropWithPreview(preview)
    local crop = {}
    for key, value in pairs(ObsCrop) do
      crop[key] = value
    end
    crop.preview = preview
    return crop
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
    assert.are.equal("screen", state.captureSource)
    assert.are.equal(generation, state.generation)
    assert.are.equal(target, ports.selectWindow())
    assert.are.equal(original, target.frame)
    assert.same({
      screen,
      screen.fullFrame,
      state.guideFrame,
      "Composition Mode:\nLocked baseline: 777 x 432\nSelected source: Screen Capture\nS = Screen Capture · W = Window Capture\nReturn = Finish/Copy\nEsc = Cancel",
      {
        { edge = "left", text = "L 400", value = 400, invalid = false },
        { edge = "top", text = "T 160", value = 160, invalid = false },
        { edge = "right", text = "R 1886", value = 1886, invalid = false },
        { edge = "bottom", text = "B 1136", value = 1136, invalid = false },
      },
    }, log.renders[1])
  end)

  it("selects only closed sources transactionally without replacing session snapshots", function()
    local generation = enter()
    local state = controller:currentState()
    local snapshots = {
      window = state.window,
      guideFrame = state.guideFrame,
      screenFullFrame = state.screenFullFrame,
      scale = state.scale,
    }

    assert.is_true(controller:selectSource("screen", generation))
    assert.are.equal(0, #log.presentations)
    assert.is_true(controller:selectSource("window", generation))
    assert.are.equal("window", state.captureSource)
    assert.are.equal(generation, state.generation)
    assert.are.equal(snapshots.window, state.window)
    assert.are.equal(snapshots.guideFrame, state.guideFrame)
    assert.are.equal(snapshots.screenFullFrame, state.screenFullFrame)
    assert.are.equal(snapshots.scale, state.scale)
    assert.are.equal(1, #log.renders)
    assert.are.equal(2, log.frameReads)
    assert.are.equal(1, log.screenReads)
    assert.are.equal(1, log.scaleReads)
    assert.are.equal(
      "Composition Mode:\nLocked baseline: 777 x 432\nSelected source: Window Capture\nS = Screen Capture · W = Window Capture\nReturn = Finish/Copy\nEsc = Cancel",
      log.presentations[1].help
    )
    assert.same({
      { edge = "left", text = "L 0", value = 0, invalid = false },
      { edge = "top", text = "T 0", value = 0, invalid = false },
      { edge = "right", text = "R 0", value = 0, invalid = false },
      { edge = "bottom", text = "B 0", value = 0, invalid = false },
    }, log.presentations[1].labels)
    assert.is_true(controller:selectSource("window", generation))
    assert.are.equal(1, #log.presentations)
    assert.is_true(controller:selectSource("screen", generation))
    assert.are.equal("screen", state.captureSource)
    assert.are.equal(2, #log.presentations)
  end)

  it("rejects invalid, inactive, and stale source selections", function()
    local ok, failure = controller:selectSource("display", 1)
    assert.is_false(ok)
    assert.same({ code = "invalid-source", source = "display" }, failure)
    assert.is_false(controller:selectSource(nil, 1))
    assert.is_false(controller:selectSource("window", 1))

    local generation = enter()
    assert.is_false(controller:selectSource("window"))
    assert.is_false(controller:selectSource("window", generation + 1))
    current = false
    assert.is_false(controller:selectSource("window", generation))
    assert.are.equal("screen", controller:currentState().captureSource)
    assert.are.equal(0, #log.presentations)
  end)

  it("does not commit selection when presentation fails or raises", function()
    local generation = enter()
    for _, failure in ipairs({ false, "raise" }) do
      ports.refreshPresentation = function()
        if failure == "raise" then
          error("presentation")
        end
        return false
      end
      local ok, reason = controller:selectSource("window", generation)
      assert.is_false(ok)
      assert.same({ kind = "presentation-failed" }, reason)
      assert.are.equal("screen", controller:currentState().captureSource)
      assert.are.equal(generation, controller:currentState().generation)
      assert.are.equal(1, #log.renders)
    end
  end)

  it("does not commit a source transition when its candidate frame or preview fails", function()
    local generation = enter()
    local originalFrame = ports.windowFrame
    ports.windowFrame = function()
      return false
    end
    assert.is_false(controller:selectSource("window", generation))
    assert.are.equal("screen", controller:currentState().captureSource)
    ports.windowFrame = originalFrame

    local originalPreview = controller.crop.preview
    controller.crop.preview = function()
      error("preview")
    end
    assert.is_false(controller:selectSource("window", generation))
    assert.are.equal("screen", controller:currentState().captureSource)
    controller.crop.preview = originalPreview

    assert.is_true(controller:selectSource("window", generation))
    assert.are.equal("window", controller:currentState().captureSource)
    assert.are.equal(1, #log.presentations)
    assert.are.equal(0, #log.copies)
  end)

  it("keeps fixed Screen preview ticks entirely native-read and presentation free", function()
    local generation = enter()
    local reads = { frame = log.frameReads, screen = log.screenReads }

    assert.is_true(controller:refreshPreview(generation, "screen"))
    assert.is_true(controller:refreshPreview(generation))
    assert.are.equal(reads.frame, log.frameReads)
    assert.are.equal(reads.screen, log.screenReads)
    assert.are.equal(0, #log.presentations)
    assert.are.equal(0, #log.copies)
  end)

  it("updates signed Window labels, deduplicates them, and recovers all invalid edges", function()
    local generation = enter()
    assert.is_true(controller:selectSource("window", generation))
    assert.are.equal(1, #log.presentations)

    assert.is_true(controller:refreshPreview(generation, "window"))
    assert.are.equal(1, #log.presentations)

    target.frame = rect(110, 90, 750, 400)
    assert.is_true(controller:refreshPreview(generation, "window"))
    assert.same({
      { edge = "left", text = "L -20", value = -20, invalid = true },
      { edge = "top", text = "T -20", value = -20, invalid = true },
      { edge = "right", text = "R -34", value = -34, invalid = true },
      { edge = "bottom", text = "B -44", value = -44, invalid = true },
    }, log.presentations[2].labels)

    target.frame = rect(50, 40, 900, 520)
    assert.is_true(controller:refreshPreview(generation, "window"))
    assert.same({
      { edge = "left", text = "L 100", value = 100, invalid = false },
      { edge = "top", text = "T 80", value = 80, invalid = false },
      { edge = "right", text = "R 146", value = 146, invalid = false },
      { edge = "bottom", text = "B 96", value = 96, invalid = false },
    }, log.presentations[3].labels)
    assert.are.equal(0, #log.copies)
  end)

  it("retains the last complete labels across transient read, preview, and presentation failures", function()
    local generation = enter()
    assert.is_true(controller:selectSource("window", generation))
    local state = controller:currentState()
    local retainedLabels = state.lastLabels
    local retainedPreview = state.lastPreview
    target.frame = rect(50, 40, 900, 520)

    local originalFrame = ports.windowFrame
    ports.windowFrame = function()
      return false
    end
    assert.is_false(controller:refreshPreview(generation, "window"))
    ports.windowFrame = originalFrame

    local originalPreview = controller.crop.preview
    for _, behavior in ipairs({ "false", "raise" }) do
      controller.crop.preview = function()
        if behavior == "raise" then
          error("preview")
        end
        return false
      end
      assert.is_false(controller:refreshPreview(generation, "window"))
    end
    controller.crop.preview = originalPreview

    local originalPresentation = ports.refreshPresentation
    for _, behavior in ipairs({ "false", "raise" }) do
      ports.refreshPresentation = function()
        if behavior == "raise" then
          error("presentation")
        end
        return false
      end
      assert.is_false(controller:refreshPreview(generation, "window"))
      assert.are.equal(retainedLabels, state.lastLabels)
      assert.are.equal(retainedPreview, state.lastPreview)
    end
    ports.refreshPresentation = originalPresentation

    assert.is_true(controller:refreshPreview(generation, "window"))
    assert.are_not.equal(retainedLabels, state.lastLabels)
    assert.are.equal(2, #log.presentations)
    assert.are.equal(0, #log.copies)
  end)

  it("guards preview ticks by application, session, source, and closed source validity", function()
    local generation = enter()
    assert.is_false(controller:refreshPreview())
    assert.is_false(controller:refreshPreview(generation + 1))
    assert.is_false(controller:refreshPreview(generation, "window"))
    assert.is_true(controller:selectSource("window", generation))
    assert.is_false(controller:refreshPreview(generation, "screen"))
    controller:currentState().captureSource = "invalid"
    assert.is_false(controller:refreshPreview(generation))
    controller:currentState().captureSource = "window"
    current = false
    assert.is_false(controller:refreshPreview(generation, "window"))
    assert.are.equal(1, #log.presentations)
    assert.are.equal(0, #log.copies)
  end)

  it("switches rapidly with a fresh candidate and restores the frozen Screen labels", function()
    local generation = enter()
    target.frame = rect(50, 40, 900, 520)
    assert.is_true(controller:selectSource("window", generation))
    assert.are.equal("L 100", log.presentations[1].labels[1].text)
    assert.is_true(controller:selectSource("screen", generation))
    assert.are.equal("L 400", log.presentations[2].labels[1].text)
    target.frame = rect(25, 20, 1000, 600)
    assert.is_true(controller:selectSource("window", generation))
    assert.are.equal("L 150", log.presentations[3].labels[1].text)
    assert.are.equal("window", controller:currentState().captureSource)
    assert.are.equal(3, #log.presentations)
  end)

  it("does not enter when preview or label modeling cannot produce a complete snapshot", function()
    for _, preview in ipairs({
      function()
        return false
      end,
      function()
        error("preview")
      end,
    }) do
      controller = Controller.new({
        config = config,
        crop = cropWithPreview(preview),
        view = View.new(config, metadata),
        ports = ports,
      })
      assert.is_false(controller:enter())
      assert.same({ kind = "inactive" }, controller:currentState())
      assert.are.equal(0, #log.renders)
    end

    local view = View.new(config, metadata)
    view.cropEdgeLabels = function()
      return { { edge = "left" } }
    end
    controller = Controller.new({ config = config, crop = ObsCrop, view = view, ports = ports })
    assert.is_false(controller:enter())
    assert.same({ kind = "inactive" }, controller:currentState())
    assert.are.equal(0, #log.renders)
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

  it("finishes Screen Capture from the frozen display without reading final window geometry", function()
    local generation = enter()
    target.frame = rect(50, 40, 900, 520)
    assert.is_true(controller:finish(generation))
    assert.are.equal("Screen Capture | Left: 400, Top: 160, Right: 1886, Bottom: 1136 | Result: 1554 x 864 | Scale: 2", log.copies[1])
    assert.are.equal(1, log.frameReads)
    assert.are.equal(1, log.closes)
    assert.same({ kind = "inactive" }, controller:currentState())
    assert.are.equal("Screen Capture\nLeft: 400, Top: 160, Right: 1886, Bottom: 1136 | Result: 1554 x 864 | Scale: 2", log.alerts[#log.alerts][1])
    assert.is_false(controller:finish(generation))
    assert.is_false(controller:cancel(generation))
    assert.are.equal(1, log.closes)
    assert.are.equal(1, #log.copies)
  end)

  it("keeps Finish authoritative when the last Window preview deliberately disagrees", function()
    local generation = enter()
    target.frame = rect(110, 90, 750, 400)
    assert.is_true(controller:selectSource("window", generation))
    assert.is_true(controller:refreshPreview(generation, "window"))
    assert.is_true(controller:currentState().lastLabels[1].invalid)
    assert.are.equal("L -20", controller:currentState().lastLabels[1].text)

    target.frame = rect(50, 40, 900, 520)
    assert.is_true(controller:finish(generation))
    assert.are.equal("Window Capture | Left: 100, Top: 80, Right: 146, Bottom: 96 | Result: 1554 x 864 | Scale: 2", log.copies[1])
    assert.same({ kind = "inactive" }, controller:currentState())
  end)

  it("keeps Screen Capture output invariant under arbitrary window movement and resizing", function()
    local outputs = {}
    for _, finalFrame in ipairs({ rect(100, 80, 777, 432), rect(-500, -400, 1, 1), rect(800, 700, 3000, 2400) }) do
      target.frame = rect(100, 80, 777, 432)
      local generation = enter()
      target.frame = finalFrame
      assert.is_true(controller:finish(generation))
      outputs[#outputs + 1] = log.copies[#log.copies]
    end
    assert.are.equal(outputs[1], outputs[2])
    assert.are.equal(outputs[1], outputs[3])
    assert.are.equal("Screen Capture | Left: 400, Top: 160, Right: 1886, Bottom: 1136 | Result: 1554 x 864 | Scale: 2", outputs[1])
    assert.are.equal(3, log.frameReads)
  end)

  it("routes explicit W, S to W, and repeated W through the shipped Window Capture output", function()
    for _, route in ipairs({ { "window" }, { "screen", "window" }, { "window", "window" } }) do
      target.frame = rect(100, 80, 777, 432)
      local generation = enter()
      for _, source in ipairs(route) do
        assert.is_true(controller:selectSource(source, generation))
      end
      target.frame = rect(50, 40, 900, 520)
      assert.is_true(controller:finish(generation))
      assert.are.equal("Window Capture | Left: 100, Top: 80, Right: 146, Bottom: 96 | Result: 1554 x 864 | Scale: 2", log.copies[#log.copies])
      assert.are.equal("Window Capture\nLeft: 100, Top: 80, Right: 146, Bottom: 96 | Result: 1554 x 864 | Scale: 2", log.alerts[#log.alerts][1])
    end
    assert.are.equal(3, log.closes)
  end)

  it("keeps outside-edge failures active and copies nothing", function()
    local generation = enter()
    assert.is_true(controller:selectSource("window", generation))
    target.frame = rect(101, 80, 900, 520)
    local ok, failure = controller:finish(generation)
    assert.is_false(ok)
    assert.same({ code = "outside_final", edge = "left" }, failure)
    assert.is_true(controller:isActive())
    assert.are.equal(0, #log.copies)
    assert.are.equal(0, log.closes)
    assert.matches("final window", log.alerts[#log.alerts][1])
  end)

  it("keeps frozen-screen containment failures active with source-specific recovery", function()
    target.frame = rect(-101, 80, 777, 432)
    local generation = enter()
    local ok, failure = controller:finish(generation)
    assert.is_false(ok)
    assert.same({ code = "outside_final", edge = "left" }, failure)
    assert.is_true(controller:isActive())
    assert.are.equal(0, #log.copies)
    assert.are.equal(0, log.closes)
    assert.matches("frozen screen", log.alerts[#log.alerts][1])
  end)

  it("keeps pasteboard failures active for retry", function()
    local generation = enter()
    assert.is_true(controller:selectSource("window", generation))
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
    assert.are.equal("Window Capture | Left: 100, Top: 80, Right: 146, Bottom: 96 | Result: 1554 x 864 | Scale: 2", log.copies[1])
  end)

  it("cancels an invalid or missing active source before copying and retries failed teardown", function()
    for _, source in ipairs({ "invalid", false }) do
      local generation = enter()
      local expectedIo = {
        copyCalls = log.copyCalls,
        windowIdReads = log.windowIdReads,
        frameReads = log.frameReads,
        screenReads = log.screenReads,
        identityReads = log.identityReads,
        fullFrameReads = log.fullFrameReads,
        scaleReads = log.scaleReads,
      }
      local function assertNoFinishIo()
        assert.same(expectedIo, {
          copyCalls = log.copyCalls,
          windowIdReads = log.windowIdReads,
          frameReads = log.frameReads,
          screenReads = log.screenReads,
          identityReads = log.identityReads,
          fullFrameReads = log.fullFrameReads,
          scaleReads = log.scaleReads,
        })
      end
      controller:currentState().captureSource = source == false and nil or source
      ports.close = function()
        log.closes = log.closes + 1
        return false
      end

      local ok, failure = controller:finish(generation)
      assert.is_false(ok)
      assert.same({ kind = "teardown-failed" }, failure)
      assert.is_true(controller:isActive())
      assert.are.equal(0, #log.copies)
      assertNoFinishIo()

      ports.close = function()
        log.closes = log.closes + 1
        return true
      end
      assert.is_true(controller:finish(generation))
      assert.same({ kind = "inactive" }, controller:currentState())
      assert.are.equal(0, #log.copies)
      assertNoFinishIo()
    end
    assert.are.equal(4, log.closes)
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
    assert.is_true(controller:selectSource("window", generation))
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

    assert.is_true(controller:selectSource("window", newGeneration))
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
    assert.is_true(controller:selectSource("window", generation))
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
