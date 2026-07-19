local FakeHs = require("spec.support.fake_hs")

local function frame(x, y, w, h)
  return { x = x, y = y, w = w, h = h }
end

local function assertFrame(expected, actual)
  assert.same(expected, actual)
end

local function click(driver, title)
  local item = assert(driver:menuItem(title), "missing menu item: " .. title)
  assert.is_function(item.fn)
  item.fn()
end

local modalNavigation = {
  "",
  "Modes:",
  "A = Aspect",
  "W = Width",
  "H = Height",
  "M = Move",
  "R = Resize",
  "U = undo last action",
  "Shift+U = reset session",
  "Navigation: ⌫ = back/home · Esc = exit",
}

local function assertModal(driver, body)
  local expected = {}
  for _, line in ipairs(body) do
    table.insert(expected, line)
  end
  for _, line in ipairs(modalNavigation) do
    table.insert(expected, line)
  end
  assert.are.equal(table.concat(expected, "\n"), driver:lastMessage())
end

describe("Milestone 2 characterization", function()
  local driver, window, screen

  before_each(function()
    _G.Anodyne, _G.hs = nil, nil
    driver = FakeHs.new()
    screen = driver.runtime.screens[1]
    window = driver.runtime.windows[1]
    driver:load()
  end)

  after_each(function()
    driver:shutdown()
  end)

  describe("A-LIFE-01 lifecycle ownership", function()
    it("loads with exactly one menu, modal, entry hotkey, and two subscriptions", function()
      assert.is_table(_G.Anodyne)
      assert.same({ timers = 0, menus = 1, hotkeys = 1, modals = 1, filters = 2, taps = 0, canvases = 0 }, driver:activeCounts())
    end)

    it("unloads every native resource", function()
      assert.is_nil(select(2, _G.Anodyne:stop()))
      assert.same({ timers = 0, menus = 0, hotkeys = 0, modals = 0, filters = 0, taps = 0, canvases = 0 }, driver:activeCounts())
    end)

    it("cleans the first registration set before a second load", function()
      driver:load()
      assert.same({ timers = 0, menus = 1, hotkeys = 1, modals = 1, filters = 2, taps = 0, canvases = 0 }, driver:activeCounts())
    end)

    it("reloads while modal without stale resources or callbacks crossing generations", function()
      driver:triggerEntry()
      driver:advance(4)
      local manager = _G.Anodyne
      local old = {
        timer = manager.modalTimer,
        tap = manager.modalKeyGuard,
        canvas = manager.modalCanvas,
        modal = manager.windowMode,
        menu = manager.menu,
        hotkey = manager.entryHotkey,
        focusFilter = manager.windowFilter,
        historyFilter = manager.historyWindowFilter,
      }

      driver:load()
      assert.is_false(old.timer._state.active)
      assert.is_false(old.tap._state.active)
      assert.is_true(old.canvas._state.deleted)
      assert.is_true(old.modal._state.deleted)
      assert.is_true(old.menu._state.deleted)
      assert.is_true(old.hotkey._state.deleted)
      assert.is_nil(next(old.focusFilter._state.callbacks))
      assert.is_nil(next(old.historyFilter._state.callbacks))
      assert.has_error(function()
        return old.canvas[1]
      end, "fake_hs: canvas used after delete")
      assert.has_error(function()
        old.canvas[1] = { type = "text" }
      end, "fake_hs: canvas used after delete")
      assert.is_nil(driver:lastMessage())
      assert.same({ timers = 0, menus = 1, hotkeys = 1, modals = 1, filters = 2, taps = 0, canvases = 0 }, driver:activeCounts())

      driver:triggerEntry()
      local newTimer = _G.Anodyne.modalTimer
      assert.is_not.equal(old.timer._state.callback, newTimer._state.callback)
      driver:advance(4.1)
      assert.is_true(_G.Anodyne.modalState.active)
      assert.is_true(newTimer._state.active)
    end)

    it("owns one timer, key tap, and canvas only while modal", function()
      driver:triggerEntry()
      assert.same({ timers = 1, menus = 1, hotkeys = 1, modals = 1, filters = 2, taps = 1, canvases = 1 }, driver:activeCounts())
      assert.is_true(driver:key("escape"))
      assert.same({ timers = 0, menus = 1, hotkeys = 1, modals = 1, filters = 2, taps = 0, canvases = 0 }, driver:activeCounts())
      assert.is_nil(driver:lastMessage())
    end)

    it("rejects unknown fake members, dot-called methods, and use after delete", function()
      assert.has_error(function()
        return driver.runtime.menus[1].unknown
      end, "fake_hs: unknown menubar member unknown")
      assert.has_error(function()
        driver.runtime.menus[1].setTitle("bad")
      end)
      local oldMenu = driver.runtime.menus[1]
      driver:load()
      assert.has_error(function()
        oldMenu:setTitle("bad")
      end, "fake_hs: menubar used after delete")
    end)
  end)

  describe("A-LIFE-01 strict canvas indexing", function()
    it("observes only the newest visible non-deleted canvas", function()
      local older = driver.hs.canvas.new(frame(0, 0, 100, 100))
      older[2] = { type = "text", text = "older" }
      assert.is_nil(driver:lastMessage())
      older:show()
      assert.are.equal("older", driver:lastMessage())
      older:hide()
      assert.is_nil(driver:lastMessage())
      older:show()

      local replacement = driver.hs.canvas.new(frame(0, 0, 100, 100))
      replacement[2] = { type = "text", text = "replacement" }
      replacement:show()
      assert.are.equal("replacement", driver:lastMessage())
      replacement:delete()
      assert.are.equal("older", driver:lastMessage())

      local blank = driver.hs.canvas.new(frame(0, 0, 100, 100))
      blank:show()
      assert.is_nil(driver:lastMessage())
      blank:delete()
      assert.are.equal("older", driver:lastMessage())
      older:delete()
      assert.is_nil(driver:lastMessage())
    end)

    it("returns nil for a missing live element and roundtrips table elements", function()
      local canvas = driver.hs.canvas.new(frame(0, 0, 100, 100))
      assert.is_nil(canvas[99])
      local element = { type = "text", text = "roundtrip" }
      canvas[1] = element
      assert.are.equal(element, canvas[1])
      assert.has_error(function()
        canvas.bad = {}
      end, "fake_hs: canvas elements require numeric indexes and table values")
      assert.has_error(function()
        canvas[2] = "bad"
      end, "fake_hs: canvas elements require numeric indexes and table values")
    end)

    it("rejects every numeric access and repeated delete after deletion", function()
      local canvas = driver.hs.canvas.new(frame(0, 0, 100, 100))
      canvas[1] = { type = "text" }
      canvas:delete()
      assert.has_error(function()
        return canvas[1]
      end, "fake_hs: canvas used after delete")
      assert.has_error(function()
        return canvas[99]
      end, "fake_hs: canvas used after delete")
      assert.has_error(function()
        canvas[2] = { type = "text" }
      end, "fake_hs: canvas used after delete")
      assert.has_error(function()
        canvas[2] = "bad"
      end, "fake_hs: canvas used after delete")
      assert.has_error(function()
        canvas.bad = {}
      end, "fake_hs: canvas used after delete")
      assert.has_error(function()
        canvas:delete()
      end, "fake_hs: canvas used after delete")
    end)
  end)

  describe("A-LIFE-01 deterministic timer scheduler", function()
    it("fires timers by deadline rather than registration order", function()
      local observed = {}
      driver.hs.timer.doAfter(3, function()
        table.insert(observed, "late")
      end)
      driver.hs.timer.doAfter(1, function()
        table.insert(observed, "early")
      end)
      driver:advance(3)
      assert.same({ "early", "late" }, observed)
    end)

    it("uses registration order as the stable tie breaker", function()
      local observed = {}
      driver.hs.timer.doAfter(1, function()
        table.insert(observed, "first")
      end)
      driver.hs.timer.doAfter(1, function()
        table.insert(observed, "second")
      end)
      driver:advance(1)
      assert.same({ "first", "second" }, observed)
    end)

    it("fires nested timers at deadlines relative to their callback time", function()
      local observed = {}
      driver.hs.timer.doAfter(1, function()
        table.insert(observed, driver.runtime.now)
        driver.hs.timer.doAfter(1, function()
          table.insert(observed, driver.runtime.now)
        end)
      end)
      driver:advance(3)
      assert.same({ 1, 2 }, observed)
      assert.are.equal(3, driver.runtime.now)
    end)
  end)

  describe("A-WIN-01 target selection", function()
    it("prefers the focused window", function()
      local other = driver:addWindow({ id = 2, frame = frame(200, 200, 700, 600), screen = screen })
      driver:setFrontmost(other)
      click(driver, "1400 px [W 1]")
      assert.are.equal(1400, window:frame().w)
      assert.are.equal(700, other:frame().w)
    end)

    it("uses the remembered window before frontmost fallback", function()
      local other = driver:addWindow({ id = 2, frame = frame(200, 200, 700, 600), screen = screen })
      driver:focus(window)
      driver:setFocused(nil)
      driver:setFrontmost(other)
      click(driver, "1400 px [W 1]")
      assert.are.equal(1400, window:frame().w)
      assert.are.equal(700, other:frame().w)
    end)

    it("uses frontmost when focused and remembered windows are invalid", function()
      local other = driver:addWindow({ id = 2, frame = frame(200, 200, 700, 600), screen = screen })
      driver:setFault(window, "invalidId")
      driver:setFocused(nil)
      driver:setFrontmost(other)
      click(driver, "1400 px [W 1]")
      assert.are.equal(1400, other:frame().w)
    end)

    it("pins modal actions and never falls through when its target becomes invalid", function()
      local other = driver:addWindow({ id = 2, frame = frame(200, 200, 700, 600), screen = screen })
      driver:triggerEntry()
      driver:setFocused(other)
      driver:setFrontmost(other)
      driver:setFault(window, "invalidId")
      assert.is_true(driver:key("w"))
      assert.is_true(driver:key("1"))
      assert.matches("Status: Modal target window is no longer available", driver:lastMessage(), 1, true)
      assert.are.equal(700, other:frame().w)
    end)
  end)

  describe("A-FRAME-01 geometry", function()
    it("clamps a width preset and position to usable bounds", function()
      driver:setScreenFrame(screen, frame(10, 20, 1000, 700))
      driver:setWindowFrame(window, frame(900, 600, 800, 600))
      click(driver, "1400 px [W 1]")
      assertFrame(frame(10, 120, 1000, 600), window:frame())
    end)

    it("uses the entire usable screen when it is smaller than configured minimums", function()
      driver:setScreenFrame(screen, frame(-400, 30, 400, 300))
      driver:setFullFrame(screen, frame(-400, 0, 400, 330))
      click(driver, "1400 px [W 1]")
      assertFrame(frame(-400, 30, 400, 300), window:frame())
    end)

    it("preserves the observed 16:9 result independently", function()
      click(driver, "16:9 [A 1]")
      assertFrame(frame(100, 100, 889, 500), window:frame())
    end)

    it("moves to bottom right using usable screen bounds", function()
      click(driver, "Bottom Right [M B →]")
      assertFrame(frame(1120, 480, 800, 600), window:frame())
    end)

    it("snaps right to the next 50 pixel grid line", function()
      driver:setWindowFrame(window, frame(111, 100, 800, 600))
      click(driver, "Right 50 px [M →]")
      assert.are.equal(150, window:frame().x)
    end)

    it("snaps resize dimensions to the adjacent 50 point boundaries", function()
      driver:setWindowFrame(window, frame(100, 100, 1005, 1005))
      click(driver, "Grow both to next 50 px [R G]")
      assertFrame(frame(100, 30, 1050, 1050), window:frame())
      driver:setWindowFrame(window, frame(100, 100, 1005, 1005))
      click(driver, "Shrink both to previous 50 px [R S]")
      assertFrame(frame(100, 80, 1000, 1000), window:frame())
      driver:setWindowFrame(window, frame(100, 100, 1000, 1000))
      click(driver, "Grow both to next 50 px [R G]")
      assertFrame(frame(100, 30, 1050, 1050), window:frame())
    end)
  end)

  describe("A-TXN-01 transactional writes", function()
    it("reports a thrown set without changing the frame", function()
      driver:setFault(window, "setThrows")
      click(driver, "1400 px [W 1]")
      assert.matches("WI action failed\nThe window could not be changed", driver:lastMessage(), 1, true)
      assertFrame(frame(100, 100, 800, 600), window:frame())
    end)

    it("rejects an ignored write", function()
      driver:setFault(window, "ignoreWrite")
      click(driver, "1400 px [W 1]")
      assert.matches("The window did not accept that change", driver:lastMessage(), 1, true)
    end)

    it("rolls an inexact exact undo write back and retains history", function()
      click(driver, "1400 px [W 1]")
      driver:setFault(window, "coerceWrite")
      click(driver, "Undo Last Action [U]")
      assertFrame(frame(100, 100, 1400, 600), window:frame())
      assert.matches("The window could not restore the previous frame exactly", driver:lastMessage(), 1, true)
      driver:clearFaults(window)
      click(driver, "Undo Last Action [U]")
      assertFrame(frame(100, 100, 800, 600), window:frame())
    end)

    it("invalidates history when rollback after an inexact undo fails", function()
      click(driver, "1400 px [W 1]")
      driver:setFault(window, "coerceWrite")
      driver:setFault(window, "rollbackFails")
      click(driver, "Undo Last Action [U]")
      driver:clearFaults(window)
      click(driver, "Undo Last Action [U]")
      assert.matches("Nothing to undo for this window", driver:lastMessage(), 1, true)
    end)

    it("records authoritative coerced readback for ordinary writes", function()
      driver:setFault(window, "coerceWrite")
      click(driver, "1400 px [W 1]")
      assert.are.equal(1401, window:frame().w)
      driver:clearFaults(window)
      click(driver, "Undo Last Action [U]")
      assert.are.equal(800, window:frame().w)
    end)

    it("invalidates history when authoritative readback throws", function()
      click(driver, "1400 px [W 1]")
      driver:setFault(window, "readThrowsAfterSet")
      click(driver, "1600 px [W 2]")
      driver:clearFaults(window)
      click(driver, "Undo Last Action [U]")
      assert.matches("Nothing to undo for this window", driver:lastMessage(), 1, true)
    end)

    it("rejects an invalid window screen", function()
      driver:setFault(window, "invalidScreen")
      click(driver, "1400 px [W 1]")
      assert.matches("No focused window", driver:lastMessage(), 1, true)
    end)

    it("preserves the observed preset error on an invalid frame", function()
      driver:clearFaults(window)
      driver:setFault(window, "invalidFrame")
      assert.has_error(function()
        click(driver, "1400 px [W 1]")
      end, "attempt to index a nil value (local 'currentFrame')")
    end)
  end)

  describe("A-HIST-01 history", function()
    it("is per-window", function()
      local other = driver:addWindow({ id = 2, frame = frame(20, 20, 700, 600), screen = screen })
      click(driver, "1400 px [W 1]")
      driver:focus(other)
      click(driver, "Undo Last Action [U]")
      assert.matches("Nothing to undo for this window", driver:lastMessage(), 1, true)
      driver:focus(window)
      click(driver, "Undo Last Action [U]")
      assert.are.equal(800, window:frame().w)
    end)

    it("bounds undo to the latest three accepted actions", function()
      click(driver, "1400 px [W 1]")
      click(driver, "1600 px [W 2]")
      click(driver, "1800 px [W 3]")
      click(driver, "2000 px [W 4]")
      click(driver, "Undo Last Action [U]")
      click(driver, "Undo Last Action [U]")
      click(driver, "Undo Last Action [U]")
      assert.are.equal(1400, window:frame().w)
      click(driver, "Undo Last Action [U]")
      assert.matches("Nothing to undo for this window", driver:lastMessage(), 1, true)
    end)

    it("clears history after an external frame discontinuity", function()
      click(driver, "1400 px [W 1]")
      driver:setWindowFrame(window, frame(101, 100, 1400, 600))
      click(driver, "Undo Last Action [U]")
      assert.matches("Undo history was reset because the window changed outside WI", driver:lastMessage(), 1, true)
    end)

    it("clears history when the owning window is destroyed", function()
      click(driver, "1400 px [W 1]")
      driver:destroyWindow(window)
      local replacement = driver:addWindow({ id = 1, frame = frame(0, 0, 900, 600), screen = screen })
      driver:setFocused(replacement)
      driver:setFrontmost(replacement)
      click(driver, "Undo Last Action [U]")
      assert.matches("Nothing to undo for this window", driver:lastMessage(), 1, true)
    end)

    it("copies frame reads before recording history", function()
      driver:clearFrameReads(window)
      click(driver, "1400 px [W 1]")
      local reads = driver:frameReads(window)
      assert.is_true(#reads >= 3)
      for _, returnedFrame in ipairs(reads) do
        returnedFrame.x = 777
        returnedFrame.y = 666
        returnedFrame.w = 333
        returnedFrame.h = 222
      end
      click(driver, "Undo Last Action [U]")
      assertFrame(frame(100, 100, 800, 600), window:frame())
    end)
  end)

  describe("A-SCREEN-01 snapshots", function()
    it("refuses undo when the original screen was removed", function()
      click(driver, "1400 px [W 1]")
      driver:removeScreen(screen)
      click(driver, "Undo Last Action [U]")
      assert.matches("screen configuration changed; the previous frame is unavailable", driver:lastMessage(), 1, true)
    end)

    it("refuses session reset when fullFrame changes", function()
      driver:triggerEntry()
      driver:key("w")
      driver:key("1")
      driver:advance(0.05)
      driver:setFullFrame(screen, frame(0, 0, 1920, 1079))
      driver:key("u", { shift = true })
      assert.matches("screen configuration changed; session reset is unavailable", driver:lastMessage(), 1, true)
    end)

    it("restores the exact session frame when screen identity and fullFrame are unchanged", function()
      assertFrame(frame(100, 100, 800, 600), window:frame())
      driver:triggerEntry()
      driver:key("w")
      driver:key("1")
      assertFrame(frame(100, 100, 1400, 600), window:frame())

      driver:key("u", { shift = true })
      driver:advance(0.05)
      assertFrame(frame(100, 100, 800, 600), window:frame())
      assert.are.equal(1, driver:activeCounts().canvases)
      local currentCanvas = driver.runtime.canvases[#driver.runtime.canvases]._state
      assert.is_nil(currentCanvas.deleted)
      assert.is_true(currentCanvas.visible)
      assert.are.equal("Status: Reset session (800 x 600)", driver:lastMessage():match("([^\n]+)$"))
    end)

    it("rejects undo on a replacement screen with identical geometry but different identity", function()
      click(driver, "1400 px [W 1]")
      driver:removeScreen(screen)
      local replacement = driver:addScreen({ id = 2, uuid = "replacement", frame = frame(0, 0, 1920, 1080) })
      driver:setWindowScreen(window, replacement)
      click(driver, "Undo Last Action [U]")
      assert.matches("screen configuration changed; the previous frame is unavailable", driver:lastMessage(), 1, true)
    end)

    it("rejects reset on a replacement screen with identical geometry but different identity", function()
      driver:triggerEntry()
      driver:key("w")
      driver:key("1")
      driver:advance(0.05)
      driver:removeScreen(screen)
      local replacement = driver:addScreen({ id = 2, uuid = "replacement", frame = frame(0, 0, 1920, 1080) })
      driver:setWindowScreen(window, replacement)
      driver:key("u", { shift = true })
      assert.matches("screen configuration changed; session reset is unavailable", driver:lastMessage(), 1, true)
    end)

    it("uses usable frame for placement while snapshotting fullFrame", function()
      driver:setScreenFrame(screen, frame(0, 30, 1920, 1050))
      driver:setFullFrame(screen, frame(0, 0, 1920, 1080))
      click(driver, "Top Left [M shift + ←]")
      assert.are.equal(30, window:frame().y)
      click(driver, "Undo Last Action [U]")
      assert.are.equal(100, window:frame().y)
    end)
  end)

  describe("A-KEY-01 routing", function()
    before_each(function()
      driver:triggerEntry()
    end)

    it("consumes key down and key up but passes flagsChanged", function()
      assert.is_false(driver:key("a", {}, "flagsChanged"))
      assert.is_true(driver:key("a", {}, "keyUp"))
      assert.is_true(driver:key("a", {}, "keyDown"))
    end)

    it("registers all three exact event types and filters unregistered delivery", function()
      local tap = driver.runtime.taps[#driver.runtime.taps]
      assert.same({ 10, 11, 12 }, tap._state.events)
      tap._state.registered[driver.hs.eventtap.event.types.keyUp] = nil
      local deliveries = tap._state.deliveries
      assert.is_false(driver:key("a", {}, "keyUp"))
      assert.are.equal(deliveries, tap._state.deliveries)
      tap._state.registered[driver.hs.eventtap.event.types.flagsChanged] = nil
      assert.is_false(driver:key("a", {}, "flagsChanged"))
      assert.are.equal(deliveries, tap._state.deliveries)
    end)

    it("requires colon syntax and exact arity for event methods", function()
      driver:key("a")
      local event = driver.runtime.lastEvent
      assert.has_error(function()
        event.getType()
      end, "fake_hs: event:getType must be called with colon syntax")
      assert.has_error(function()
        event.getKeyCode()
      end, "fake_hs: event:getKeyCode must be called with colon syntax")
      assert.has_error(function()
        event.getFlags()
      end, "fake_hs: event:getFlags must be called with colon syntax")
      assert.has_error(function()
        event:getType("extra")
      end, "fake_hs: event:getType received too many arguments")
    end)

    it("rejects unknown keycodes APIs while unknown map entries remain nil", function()
      assert.has_error(function()
        return driver.hs.keycodes.unknown
      end, "fake_hs: unknown keycodes API unknown")
      assert.is_nil(driver.hs.keycodes.map[999999])
    end)

    it("navigates modes and backspace home with exact headings", function()
      driver:key("w")
      assert.matches("^Width preset:", driver:lastMessage())
      driver:key("delete")
      assert.matches("^Window mode:", driver:lastMessage())
    end)

    it("allows Fn on arrows but rejects Fn on letters", function()
      driver:key("m")
      driver:key("right", { fn = true })
      assert.are.equal(150, window:frame().x)
      driver:key("b", { fn = true })
      assert.matches("Fn%+B is not available in Move", driver:lastMessage())
    end)

    it("routes shifted arrows before ordinary movement", function()
      driver:key("m")
      driver:key("left", { shift = true })
      driver:advance(0.05)
      assertFrame(frame(0, 0, 800, 600), window:frame())
    end)

    it("shows unrecognized and modifier-aware invalid key feedback", function()
      driver:key("not-mapped")
      assert.matches("Status: Unrecognized key", driver:lastMessage(), 1, true)
      driver:key("a", { cmd = true, shift = true })
      assert.matches("Cmd%+Shift%+A is not available in Window mode", driver:lastMessage())
    end)
  end)

  describe("A-UI-01 strings, order, and timers", function()
    it("registers the exact entry chord, menubar identity, tooltip, and tap types", function()
      local hotkey = driver.runtime.hotkeys[1]._state
      local menu = driver.runtime.menus[1]._state
      assert.same({ "ctrl", "alt", "cmd" }, hotkey.modifiers)
      assert.are.equal("m", hotkey.key)
      assert.are.equal("WI", menu.title)
      assert.are.equal("Window management: ctrl+alt+cmd+M for keyboard mode", menu.tooltip)
      driver:triggerEntry()
      assert.same({ 10, 11, 12 }, driver.runtime.taps[1]._state.events)
    end)

    it("constructs all 47 menu items with frozen strings and order", function()
      local items = driver:menuItems()
      local titles = {}
      for _, item in ipairs(items) do
        table.insert(titles, item.title)
      end
      assert.same({
        "Keyboard Mode: ctrl+alt+cmd+M",
        "Modes: A Aspect · W Width · H Height · M Move · R Resize",
        "Navigation: ⌫ = back/home · Esc = exit",
        "Undo Last Action [U]",
        "Reset Session [Shift+U]",
        "-",
        "Aspect [A then 1-5]",
        "16:9 [A 1]",
        "4:3 [A 2]",
        "3:2 [A 3]",
        "2:1 [A 4]",
        "3:1 [A 5]",
        "-",
        "Width [W then 1-7]",
        "1400 px [W 1]",
        "1600 px [W 2]",
        "1800 px [W 3]",
        "2000 px [W 4]",
        "2200 px [W 5]",
        "2400 px [W 6]",
        "2600 px [W 7]",
        "-",
        "Height [H then 1-4]",
        "1000 px [H 1]",
        "1200 px [H 2]",
        "1400 px [H 3]",
        "1500 px [H 4]",
        "-",
        "Move [M then arrows / C / B]",
        "Left 50 px [M ←]",
        "Right 50 px [M →]",
        "Up 50 px [M ↑]",
        "Down 50 px [M ↓]",
        "Top Left [M shift + ←]",
        "Center Top [M C]",
        "Top Right [M shift + →]",
        "Bottom Left [M B ←]",
        "Center Bottom [M B C]",
        "Bottom Right [M B →]",
        "-",
        "Resize [R then arrows / G / S]",
        "Grow to next 50 px [R →]",
        "Grow to next 50 px [R ↓]",
        "Shrink to previous 50 px [R ←]",
        "Shrink to previous 50 px [R ↑]",
        "Grow both to next 50 px [R G]",
        "Shrink both to previous 50 px [R S]",
      }, titles)
    end)

    it("renders exact home content and current size", function()
      driver:triggerEntry()
      assert.are.equal(
        table.concat({
          "Window mode:",
          "Current: 800 x 600",
          "",
          "Choose a mode with A, W, H, M, or R",
          "",
          "Modes:",
          "A = Aspect",
          "W = Width",
          "H = Height",
          "M = Move",
          "R = Resize",
          "U = undo last action",
          "Shift+U = reset session",
          "Navigation: ⌫ = back/home · Esc = exit",
        }, "\n"),
        driver:lastMessage()
      )
    end)

    it("renders the exact Aspect body", function()
      driver:triggerEntry()
      driver:key("a")
      assertModal(driver, {
        "Aspect preset:",
        "Current: 800 x 600",
        "",
        "1 = 16:9",
        "2 = 4:3",
        "3 = 3:2",
        "4 = 2:1",
        "5 = 3:1",
      })
    end)

    it("renders the exact Width body", function()
      driver:triggerEntry()
      driver:key("w")
      assertModal(driver, {
        "Width preset:",
        "Current: 800 x 600",
        "",
        "1 = 1400 px",
        "2 = 1600 px",
        "3 = 1800 px",
        "4 = 2000 px",
        "5 = 2200 px",
        "6 = 2400 px",
        "7 = 2600 px",
      })
    end)

    it("renders the exact Height body", function()
      driver:triggerEntry()
      driver:key("h")
      assertModal(driver, {
        "Height preset:",
        "Current: 800 x 600",
        "",
        "1 = 1000 px",
        "2 = 1200 px",
        "3 = 1400 px",
        "4 = 1500 px",
      })
    end)

    it("renders the exact Move body", function()
      driver:triggerEntry()
      driver:key("m")
      assertModal(driver, {
        "Move:",
        "Current: 800 x 600",
        "",
        "← = Left 50 px",
        "→ = Right 50 px",
        "↑ = Up 50 px",
        "↓ = Down 50 px",
        "shift + ← = Top Left",
        "C = Center Top",
        "shift + → = Top Right",
        "B = bottom positions",
      })
    end)

    it("renders the exact Move Bottom body", function()
      driver:triggerEntry()
      driver:key("m")
      driver:key("b")
      assertModal(driver, {
        "Move bottom positions:",
        "Current: 800 x 600",
        "",
        "← = Bottom Left",
        "C = Center Bottom",
        "→ = Bottom Right",
        "B or ⌫ = back to Move",
      })
    end)

    it("renders the exact Resize body", function()
      driver:triggerEntry()
      driver:key("r")
      assertModal(driver, {
        "Resize:",
        "Current: 800 x 600",
        "",
        "→ = Grow to next 50 px",
        "↓ = Grow to next 50 px",
        "← = Shrink to previous 50 px",
        "↑ = Shrink to previous 50 px",
        "G = Grow both to next 50 px",
        "S = Shrink both to previous 50 px",
      })
    end)

    it("replaces the 8 second modal timer on handled key input", function()
      driver:triggerEntry()
      driver:advance(7.9)
      driver:key("w")
      driver:advance(0.2)
      assert.is_true(_G.Anodyne.modalState.active)
      driver:advance(7.81)
      assert.is_false(_G.Anodyne.modalState.active)
    end)

    it("delays active action feedback by 0.05 seconds", function()
      driver:triggerEntry()
      driver:key("w")
      driver:key("1")
      assert.matches("^Width preset:", driver:lastMessage())
      driver:advance(0.05)
      assert.are.equal(1, driver:activeCounts().canvases)
      local currentCanvas = driver.runtime.canvases[#driver.runtime.canvases]._state
      assert.is_nil(currentCanvas.deleted)
      assert.is_true(currentCanvas.visible)
      assert.are.equal("Status: Width 1400 px (1400 x 600)", driver:lastMessage():match("([^\n]+)$"))
    end)

    it("shows inactive failures for exactly two seconds", function()
      driver:setFocused(nil)
      driver:setFrontmost(nil)
      driver:setFault(window, "invalidId")
      click(driver, "Undo Last Action [U]")
      assert.matches("WI action failed", driver:lastMessage(), 1, true)
      assert.are.equal(1, driver:activeCounts().canvases)
      driver:advance(2)
      assert.are.equal(0, driver:activeCounts().canvases)
      assert.is_nil(driver:lastMessage())
    end)

    it("reports no-op actions as successful modal status", function()
      driver:setWindowFrame(window, frame(0, 0, 800, 600))
      driver:triggerEntry()
      driver:key("m")
      driver:key("left", { shift = true })
      driver:advance(0.05)
      assert.matches("Status: No change — Move to top left", driver:lastMessage(), 1, true)
    end)
  end)
end)
