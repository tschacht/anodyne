local Config = require("Anodyne.config")
local View = require("Anodyne.view")

describe("Anodyne view", function()
  local config, metadata, view

  before_each(function()
    config, metadata = Config.build()
    view = View.new(config, metadata)
  end)

  it("preserves all 52 exact ordered Window Mode menu titles and adds Composition Mode", function()
    local items = view:menuItems({ active = false }, false)
    local titles = {}
    for _, item in ipairs(items) do
      titles[#titles + 1] = item.title
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
      "Width [W then 1-8]",
      "1000 px [W 1]",
      "1200 px [W 2]",
      "1400 px [W 3]",
      "1600 px [W 4]",
      "1800 px [W 5]",
      "2000 px [W 6]",
      "2200 px [W 7]",
      "2400 px [W 8]",
      "-",
      "Height [H then 1-8]",
      "600 px [H 1]",
      "700 px [H 2]",
      "800 px [H 3]",
      "1000 px [H 4]",
      "1200 px [H 5]",
      "1400 px [H 6]",
      "1500 px [H 7]",
      "1600 px [H 8]",
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
      "-",
      "Composition Mode: ctrl+alt+cmd+C",
    }, titles)
    assert.same({ type = "action", action = "undo" }, items[4].intent)
    assert.same({ type = "action", action = "width", value = 1000 }, items[15].intent)
    assert.is_true(items[5].disabled)
    assert.same({ type = "composition", action = "enter" }, items[54].intent)
  end)

  it("renders exact bodies for every screen", function()
    local expectedBodies = {
      home = { "Choose a mode with A, W, H, M, or R" },
      aspect = { "1 = 16:9", "2 = 4:3", "3 = 3:2", "4 = 2:1", "5 = 3:1" },
      width = { "1 = 1000 px", "2 = 1200 px", "3 = 1400 px", "4 = 1600 px", "5 = 1800 px", "6 = 2000 px", "7 = 2200 px", "8 = 2400 px" },
      height = { "1 = 600 px", "2 = 700 px", "3 = 800 px", "4 = 1000 px", "5 = 1200 px", "6 = 1400 px", "7 = 1500 px", "8 = 1600 px" },
      move = {
        "← = Left 50 px",
        "→ = Right 50 px",
        "↑ = Up 50 px",
        "↓ = Down 50 px",
        "shift + ← = Top Left",
        "C = Center Top",
        "shift + → = Top Right",
        "B = bottom positions",
      },
      move_bottom = { "← = Bottom Left", "C = Center Bottom", "→ = Bottom Right", "B or ⌫ = back to Move" },
      resize = {
        "→ = Grow to next 50 px",
        "↓ = Grow to next 50 px",
        "← = Shrink to previous 50 px",
        "↑ = Shrink to previous 50 px",
        "G = Grow both to next 50 px",
        "S = Shrink both to previous 50 px",
      },
    }
    for screen, body in pairs(expectedBodies) do
      local lines = view:modalLines({ screen = screen }, { width = 800, height = 600 })
      for index, line in ipairs(body) do
        assert.are.equal(line, lines[index + 3])
      end
      assert.matches("Navigation: ⌫ = back/home · Esc = exit$", table.concat(lines, "\n"))
    end
  end)

  it("renders status, missing size, and unknown mode fallback", function()
    assert.matches("Current: no focused window", view:modalText({ screen = "home" }))
    assert.matches("Status: failed$", view:modalText({ screen = "home" }, { width = 1, height = 2 }, "failed"))
    assert.matches("^Window mode:", view:modalText({ screen = "unknown" }, { width = 1, height = 2 }))
    assert.are.equal("Window management: ctrl+alt+cmd+M for keyboard mode", view:tooltip())
    assert.are.equal(
      "Cmd+Shift+A is not available in Window mode",
      view:statusText({
        kind = "unavailable-key",
        key = "a",
        flags = { cmd = true, shift = true },
        screen = "home",
      })
    )
    assert.are.equal("Ctrl+Alt+Fn+Backspace", view:formatKey("delete", { ctrl = true, alt = true, fn = true }))
    assert.are.equal("Unrecognized key", view:statusText({ kind = "unrecognized-key" }))
    assert.are.equal("Already at Home", view:statusText({ kind = "already-home" }))
    assert.are.equal("Unknown status", view:statusText({ kind = "other" }))
    assert.are.equal("The target window is no longer available", view:statusText({ kind = "target-unavailable" }))
    assert.are.equal("Unknown action bogus", view:statusText({ kind = "unknown-action", action = "bogus" }))
    assert.are.equal("WI action failed\nThe action could not be completed", view:failureText())
    assert.are.equal("WI action failed\nUnknown action bogus", view:failureText({ kind = "unknown-action", action = "bogus" }))
    assert.are.equal("Shrink to previous 50 px", view:resizeLabel({ label = "Shrink Width", deltaWidth = -50, deltaHeight = 0 }))
  end)

  it("renders deterministic Composition Mode help and OBS output text", function()
    assert.are.equal(
      "Composition Mode:\nLocked baseline: 1234 x 777\nReturn = Finish/Copy\nEsc = Cancel",
      view:compositionHelpText({ width = 1234, height = 777 })
    )
    assert.are.equal(
      "Composition Mode:\nLocked baseline: 1235 x 777\nReturn = Finish/Copy\nEsc = Cancel",
      view:compositionHelpText({ width = 1234.5, height = 777.49 })
    )
    assert.are.equal(
      "Composition Mode:\nLocked baseline: unavailable\nReturn = Finish/Copy\nEsc = Cancel\nStatus: failed",
      view:compositionHelpText(nil, "failed")
    )
    local result = { left = 10, top = 20, right = 30, bottom = 40, resultWidth = 1280, resultHeight = 720, scale = 2 }
    local expected = "Left: 10, Top: 20, Right: 30, Bottom: 40 | Result: 1280 x 720 | Scale: 2"
    assert.are.equal(expected, view:cropClipboardText(result))
    assert.are.equal(expected, view:cropResultText(result))
    assert.is_nil(view:cropClipboardText(result):match("\n"))
  end)

  it("identifies Composition Mode crop, stale, and copy failures", function()
    local expected = {
      { { code = "outside_final", edge = "left" }, "The locked guide is outside the final window at the left edge" },
      { { code = "outside_final", edge = "top" }, "The locked guide is outside the final window at the top edge" },
      { { code = "outside_final", edge = "right" }, "The locked guide is outside the final window at the right edge" },
      { { code = "outside_final", edge = "bottom" }, "The locked guide is outside the final window at the bottom edge" },
      { { code = "outside_final" }, "The locked guide is outside the final window" },
      { { code = "invalid_rect", rect = "final" }, "Invalid final window geometry" },
      { { code = "invalid_rect", rect = "guide" }, "Invalid locked guide geometry" },
      { { code = "invalid_rect" }, "Invalid crop geometry" },
      { { code = "invalid_scale" }, "Invalid display scale" },
      { { kind = "stale-target" }, "The target window is no longer available" },
      { { kind = "stale-screen" }, "The screen geometry changed; Composition Mode was cancelled" },
      { { kind = "stale-scale" }, "The display scale changed; Composition Mode was cancelled" },
      { { kind = "stale-geometry" }, "The captured geometry changed; Composition Mode was cancelled" },
      { { kind = "copy-failed" }, "Could not copy OBS crop values; Composition Mode is still active" },
      { { kind = "pasteboard-failed" }, "Could not copy OBS crop values; Composition Mode is still active" },
    }
    for _, case in ipairs(expected) do
      assert.are.equal(case[2], view:statusText(case[1]))
      assert.matches("Status: " .. case[2] .. "$", view:compositionHelpText({ width = 800, height = 600 }, case[1]))
    end
  end)

  it("preserves the exact legacy empty-preset line sequence", function()
    for _, screen in ipairs({ "aspect", "width", "height" }) do
      local overrides = {}
      overrides[screen .. "Presets"] = {}
      local emptyConfig, emptyMetadata = Config.build(overrides)
      local lines = View.new(emptyConfig, emptyMetadata):modalLines({ screen = screen }, { width = 800, height = 600 })
      assert.same({ emptyMetadata.screenTitles[screen] .. ":", "Current: 800 x 600", "", "", "", "Modes:" }, {
        lines[1],
        lines[2],
        lines[3],
        lines[4],
        lines[5],
        lines[6],
      })
    end
  end)

  it("models reset availability and screen-change explanation", function()
    local state = { active = true, sessionInitialFrame = {}, sessionInitialScreen = {} }
    local available = view:menuItems(state, false)[5]
    assert.is_false(available.disabled)
    local changed = view:menuItems(state, true)[5]
    assert.is_true(changed.disabled)
    assert.matches("%(screen configuration changed%)$", changed.title)
  end)
end)
