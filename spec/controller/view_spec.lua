local Config = require("Anodyne.config")
local View = require("Anodyne.view")

describe("Anodyne view", function()
  local config, metadata, view

  before_each(function()
    config, metadata = Config.build()
    view = View.new(config, metadata)
  end)

  it("builds all 47 exact ordered menu titles and stable intents", function()
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
      "Aspect Presets [A then 1-5]",
      "16:9 [A 1]",
      "4:3 [A 2]",
      "3:2 [A 3]",
      "2:1 [A 4]",
      "3:1 [A 5]",
      "-",
      "Width Presets [W then 1-7]",
      "1400 px [W 1]",
      "1600 px [W 2]",
      "1800 px [W 3]",
      "2000 px [W 4]",
      "2200 px [W 5]",
      "2400 px [W 6]",
      "2600 px [W 7]",
      "-",
      "Height Presets [H then 1-4]",
      "1000 px [H 1]",
      "1200 px [H 2]",
      "1400 px [H 3]",
      "1500 px [H 4]",
      "-",
      "Move 50 px [M then arrows / C / B]",
      "Move Left [M ←]",
      "Move Right [M →]",
      "Move Up [M ↑]",
      "Move Down [M ↓]",
      "Top Left [M shift + ←]",
      "Center Top [M C]",
      "Top Right [M shift + →]",
      "Bottom Left [M B ←]",
      "Center Bottom [M B C]",
      "Bottom Right [M B →]",
      "-",
      "Resize toward 50 px grid [R then arrows / G / S]",
      "Grow Width [R →]",
      "Grow Height [R ↓]",
      "Shrink Width [R ←]",
      "Shrink Height [R ↑]",
      "Grow Width + Height [R G]",
      "Shrink Width + Height [R S]",
    }, titles)
    assert.same({ type = "action", action = "undo" }, items[4].intent)
    assert.same({ type = "action", action = "width", value = 1400 }, items[15].intent)
    assert.is_true(items[5].disabled)
  end)

  it("renders exact bodies for every screen", function()
    local expectedBodies = {
      home = { "Choose a mode with A, W, H, M, or R" },
      aspect = { "1 = 16:9", "2 = 4:3", "3 = 3:2", "4 = 2:1", "5 = 3:1" },
      width = { "1 = 1400 px", "2 = 1600 px", "3 = 1800 px", "4 = 2000 px", "5 = 2200 px", "6 = 2400 px", "7 = 2600 px" },
      height = { "1 = 1000 px", "2 = 1200 px", "3 = 1400 px", "4 = 1500 px" },
      move = {
        "← = move left 50 px",
        "→ = move right 50 px",
        "↑ = move up 50 px",
        "↓ = move down 50 px",
        "shift + ← = top left",
        "C = center top",
        "shift + → = top right",
        "B = bottom positions",
      },
      move_bottom = { "← = bottom left", "C = center bottom", "→ = bottom right", "B or ⌫ = back to Move" },
      resize = {
        "→ = grow width toward next 50 px boundary",
        "↓ = grow height toward next 50 px boundary",
        "← = shrink width toward previous 50 px boundary",
        "↑ = shrink height toward previous 50 px boundary",
        "G = grow width + height toward next 50 px boundary",
        "S = shrink width + height toward previous 50 px boundary",
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
    assert.are.equal("Shrink Width toward previous 50 px boundary", view:resizeLabel({ label = "Shrink Width", deltaWidth = -50, deltaHeight = 0 }))
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
