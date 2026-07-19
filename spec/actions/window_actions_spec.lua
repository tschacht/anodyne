local Config = require("Anodyne.config")
local Geometry = require("Anodyne.core.geometry")
local History = require("Anodyne.core.history")
local WindowActions = require("Anodyne.window_actions")
local FakeHs = require("spec.support.fake_hs")

local function frame(x, y, width, height)
  return { x = x, y = y, w = width, h = height }
end

describe("Milestone 5 transactional window actions", function()
  local driver, window, screen, owner, modalState, entries, actions

  before_each(function()
    driver = FakeHs.new()
    window = driver.runtime.windows[1]
    screen = driver.runtime.screens[1]
    owner = { lastFocusedWindow = driver.hs.window.frontmostWindow() }
    modalState = { active = false }
    entries = {}
    local config, metadata = Config.build()
    local history = History.new({ entries = entries, depth = config.undoDepth, copyFrame = Geometry.copyFrame, framesEqual = Geometry.framesEqual })
    actions = WindowActions.new({
      owner = owner,
      modalState = modalState,
      config = config,
      geometry = Geometry,
      history = history,
      cornerLabels = metadata.cornerLabelByName,
      ports = {
        focusedWindow = function()
          return driver.hs.window.focusedWindow()
        end,
        frontmostWindow = function()
          return driver.hs.window.frontmostWindow()
        end,
        allScreens = function()
          return driver.hs.screen.allScreens()
        end,
        windowId = function(candidate)
          return candidate:id()
        end,
        windowScreen = function(candidate)
          return candidate:screen()
        end,
        windowFrame = function(candidate)
          return candidate:frame()
        end,
        setWindowFrame = function(candidate, target)
          candidate:setFrame(target, 0)
        end,
        screenIdentity = function(candidate)
          return candidate:getUUID() or tostring(candidate:id())
        end,
        screenFullFrame = function(candidate)
          return candidate:fullFrame()
        end,
        screenFrame = function(candidate)
          return candidate:frame()
        end,
      },
    })
  end)

  it("resolves focused, remembered, frontmost, absent, and pinned modal targets", function()
    local alternate = driver:addWindow({ id = 2 })
    assert.are.equal(window, actions:getFocusedWindow())
    driver:setFocused(nil)
    assert.are.equal(window, actions:getFocusedWindow())
    driver:setFault(window, "invalidId")
    driver:setFrontmost(alternate)
    assert.are.equal(alternate, actions:getFocusedWindow())
    driver:setFault(alternate, "invalidScreen")
    assert.same({ nil, "No focused window" }, { actions:getFocusedWindow() })
    modalState.active, modalState.targetWindow = true, window
    assert.same({ nil, "Modal target window is no longer available" }, { actions:getFocusedWindow() })
  end)

  it("resolves the modal-home fallback chain and remembers focus", function()
    local alternate = driver:addWindow({ id = 2 })
    assert.are.equal(window, actions:getModalHomeWindow())
    driver:setFocused(nil)
    assert.are.equal(window, actions:getModalHomeWindow())
    driver:setFault(window, "invalidId")
    driver:setFrontmost(alternate)
    assert.are.equal(alternate, actions:getModalHomeWindow())
    modalState.active, modalState.targetWindow = true, alternate
    assert.are.equal(alternate, actions:getModalHomeWindow())
  end)

  it("takes copied identity/full-frame snapshots and verifies current screens", function()
    local snapshot = assert(actions:windowScreenSnapshot(window))
    assert.are.equal(screen._state.uuid, snapshot.identity)
    assert.is_true(actions:screenSnapshotIsCurrent(snapshot))
    snapshot.frame.x = snapshot.frame.x + 1
    assert.is_false(actions:screenSnapshotIsCurrent(snapshot))
    assert.is_false(actions:screenSnapshotIsCurrent(nil))
  end)

  it("rejects invalid window and screen snapshot inputs", function()
    driver:setFault(window, "invalidScreen")
    assert.is_nil(actions:windowScreenSnapshot(window))
    driver:clearFaults(window)
    local original = actions.ports.screenIdentity
    actions.ports.screenIdentity = function()
      error("identity")
    end
    assert.is_nil(actions:screenSnapshot(screen))
    actions.ports.screenIdentity = original
    actions.ports.screenFullFrame = function()
      return nil
    end
    assert.is_nil(actions:screenSnapshot(screen))
  end)

  it("records authoritative readback and reports sized success", function()
    driver:setFault(window, "coerceWrite", 1)
    local ok, _, status = actions:applyWidthPreset(1400)
    assert.is_true(ok)
    assert.are.equal("Width 1400 px (1401 x 600)", status)
    assert.are.equal(1401, entries[1][1].after.w)
  end)

  it("does not record no-op, ignored, rejected-id, or thrown writes", function()
    assert.same({ true, nil, "No change — Width 800 px (800 x 600)" }, { actions:applyWidthPreset(800) })
    driver:setFault(window, "ignoreWrite")
    assert.same({ false, "The window did not accept that change" }, { actions:applyWidthPreset(900) })
    driver:setFault(window, "setThrows")
    assert.same({ false, "The window could not be changed" }, { actions:applyWidthPreset(900) })
    driver:setFault(window, "invalidId")
    assert.same({ false, "No focused window" }, { actions:applyWidthPreset(900) })
    assert.is_nil(entries[1])
  end)

  it("rejects invalid direct targets before attempting mutation", function()
    driver:setFault(window, "invalidId")
    assert.same({ false, "The target window is no longer available" }, { actions:applyFrame(window, frame(1, 2, 700, 500), "change") })
    driver:clearFaults(window)
    driver:setFault(window, "invalidScreen")
    assert.same({ false, "The window screen could not be verified" }, { actions:applyFrame(window, frame(1, 2, 700, 500), "change") })
  end)

  it("invalidates history when authoritative readback fails", function()
    entries[1] = { { after = window:frame() } }
    driver:setFault(window, "readThrowsAfterSet")
    assert.same({ false, "The window frame could not be verified" }, { actions:applyFrame(window, frame(1, 2, 700, 500), "change") })
    assert.is_nil(entries[1])
  end)

  it("distinguishes missing current frame and unusable screen frame", function()
    driver:setFault(window, "invalidFrame")
    assert.same({ false, "The target window is no longer available" }, { actions:applyFrame(window, frame(1, 2, 700, 500), "change") })
    driver:clearFaults(window)
    actions.ports.screenFrame = function()
      return nil
    end
    assert.same({ false, "The window screen could not be verified" }, { actions:applyFrame(window, frame(1, 2, 700, 500), "change") })
  end)

  it("rolls an inexact exact write back without invalidating history", function()
    driver:setFault(window, "coerceWrite", 1)
    local original = window:frame()
    assert.same(
      { false, "The window could not restore the requested frame exactly" },
      { actions:applyFrame(window, frame(1, 2, 700, 500), "change", { clampToScreen = false, requireExact = true }) }
    )
    assert.same(original, window:frame())
  end)

  it("reports an exact write that accepts no change", function()
    driver:setFault(window, "ignoreWrite")
    assert.same(
      { false, "The window did not accept the requested frame" },
      { actions:applyFrame(window, frame(1, 2, 700, 500), "change", { clampToScreen = false, requireExact = true }) }
    )
  end)

  it("invalidates history when exact rollback fails", function()
    entries[1] = { { after = window:frame() } }
    driver:setFault(window, "coerceWrite", 1)
    driver:setFault(window, "rollbackFails")
    assert.same(
      { false, "The window changed but could not restore the requested frame exactly" },
      { actions:applyFrame(window, frame(1, 2, 700, 500), "change", { clampToScreen = false, requireExact = true }) }
    )
    assert.is_nil(entries[1])
  end)

  it("resets only an active session on an unchanged screen", function()
    assert.same({ false, "No active window session to reset" }, { actions:resetSessionFrame() })
    modalState.active = true
    modalState.targetWindow = window
    modalState.sessionInitialFrame = frame(3, 4, 500, 400)
    modalState.sessionInitialScreen = actions:windowScreenSnapshot(window)
    assert.is_true(actions:resetSessionFrame())
    assert.same(modalState.sessionInitialFrame, window:frame())
    driver:setFullFrame(screen, frame(0, 0, 1000, 800))
    assert.same({ false, "The screen configuration changed; session reset is unavailable" }, { actions:resetSessionFrame() })
  end)

  it("rejects reset after its pinned modal target disappears", function()
    modalState.active = true
    modalState.targetWindow = window
    modalState.sessionInitialFrame = frame(3, 4, 500, 400)
    modalState.sessionInitialScreen = actions:windowScreenSnapshot(window)
    driver:setFault(window, "invalidId")
    assert.same({ false, "Modal target window is no longer available" }, { actions:resetSessionFrame() })
  end)

  it("rejects undo without history and clears external discontinuities", function()
    assert.same({ false, "Nothing to undo for this window" }, { actions:undoLastFrame() })
    assert.is_true(actions:applyWidthPreset(900))
    driver:setWindowFrame(window, frame(10, 10, 900, 600))
    assert.same({ false, "Undo history was reset because the window changed outside WI" }, { actions:undoLastFrame() })
    assert.is_nil(entries[1])
  end)

  it("retains history when its original screen is unavailable", function()
    assert.is_true(actions:applyWidthPreset(900))
    driver:removeScreen(screen)
    assert.same({ false, "The screen configuration changed; the previous frame is unavailable" }, { actions:undoLastFrame() })
    assert.is_not_nil(entries[1])
  end)

  it("restores exact frames and consumes matching undo entries", function()
    assert.is_true(actions:applyWidthPreset(900))
    assert.is_true(actions:applyHeightPreset(700))
    assert.same({ true, nil, "Undid last action (900 x 600)" }, { actions:undoLastFrame() })
    assert.are.equal(1, #entries[1])
  end)

  it("clears unusable undo frames and failed readbacks selectively", function()
    local snapshot = actions:windowScreenSnapshot(window)
    entries[1] = { { before = window:frame(), after = window:frame(), beforeScreen = snapshot } }
    assert.same({ false, "The previous window position is no longer available" }, { actions:undoLastFrame() })
    entries[1] = { { before = frame(1, 1, 700, 500), after = window:frame(), beforeScreen = snapshot } }
    driver:setFault(window, "readThrowsAfterSet")
    assert.same({ false, "The window frame could not be verified" }, { actions:undoLastFrame() })
    assert.is_nil(entries[1])
  end)

  it("clears history when an ordinary frame read throws during undo", function()
    assert.is_true(actions:applyWidthPreset(900))
    driver:setFault(window, "readThrows")
    assert.same({ false, "The target window is no longer available" }, { actions:undoLastFrame() })
    assert.is_nil(entries[1])
  end)

  it("covers concrete aspect, corner, resize, and step actions", function()
    assert.is_true(actions:applyAspectPreset({ width = 16, height = 9, label = "16:9" }))
    assert.is_true(actions:moveToCorner("bottomright"))
    assert.same({ false, "Unknown corner: nowhere" }, { actions:moveToCorner("nowhere") })
    assert.is_true(actions:resize(-50, -50, "Shrink"))
    assert.is_true(actions:moveByStep("left"))
    assert.same({ false, "Unknown move direction: nowhere" }, { actions:moveByStep("nowhere") })
  end)

  it("clamps snapped resizes to configured minima and usable-screen maxima", function()
    driver:setWindowFrame(window, frame(100, 100, 505, 605))
    assert.is_true(actions:resize(-50, 0, "Shrink Width"))
    assert.same(frame(100, 100, 500, 605), window:frame())

    driver:setWindowFrame(window, frame(100, 100, 1905, 605))
    local ok, _, status = actions:resize(50, 0, "Grow Width toward next 50 px boundary")
    assert.is_true(ok)
    assert.same(frame(0, 100, 1920, 605), window:frame())
    assert.are.equal("Grow Width toward next 50 px boundary (1920 x 605)", status)
  end)

  it("forgets destroyed or explicitly removed windows independently", function()
    assert.is_true(actions:applyWidthPreset(900))
    actions:forgetWindow(window)
    assert.is_nil(entries[1])
    actions:forgetWindow(nil)
  end)
end)
