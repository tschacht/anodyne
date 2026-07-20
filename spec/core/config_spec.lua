local Config = require("Anodyne.config")

local function plain(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = plain(child)
  end
  return result
end

describe("configuration", function()
  it("builds the canonical default values", function()
    local config = Config.build()
    assert.same({
      menuTitle = "WI",
      menuFailureDuration = 2,
      modalDuration = 8,
      symbols = { left = "←", up = "↑", right = "→", down = "↓", shift = "shift" },
      minimumWidth = 500,
      minimumHeight = 500,
      modalHotkey = { modifiers = { "ctrl", "alt", "cmd" }, key = "m" },
      compositionHotkey = { modifiers = { "ctrl", "alt", "cmd" }, key = "c" },
      obsCrop = { scaleOverride = 0, resultDuration = 4, dimAlpha = 0.45 },
      aspectPresets = {
        { label = "16:9", width = 16, height = 9 },
        { label = "4:3", width = 4, height = 3 },
        { label = "3:2", width = 3, height = 2 },
        { label = "2:1", width = 2, height = 1 },
        { label = "3:1", width = 3, height = 1 },
      },
      widthPresets = { 1000, 1200, 1400, 1600, 1800, 2000, 2200, 2400 },
      heightPresets = { 600, 700, 800, 1000, 1200, 1400, 1500, 1600 },
      growStep = 50,
      moveStep = 50,
      undoDepth = 3,
    }, plain(config))
    local source = assert(io.open("Anodyne/config.lua")):read("*a")
    assert.is_nil(source:match("require%s*%("))
  end)

  it("deep-merges maps and replaces lists", function()
    local config = Config.build({ symbols = { left = "L" }, modalHotkey = { modifiers = { "alt" } }, widthPresets = { 111, 222 } })
    assert.are.equal("L", config.symbols.left)
    assert.are.equal("↑", config.symbols.up)
    assert.same({ "alt" }, plain(config.modalHotkey.modifiers))
    assert.same({ 111, 222 }, plain(config.widthPresets))
  end)

  it("does not alias caller overrides or defaults across instances", function()
    local override = { symbols = { left = "L" }, widthPresets = { 123 } }
    local first = Config.build(override)
    local second = Config.build()
    override.symbols.left, override.widthPresets[1] = "X", 999
    assert.are.equal("L", first.symbols.left)
    assert.are.equal(123, first.widthPresets[1])
    assert.are.equal("←", second.symbols.left)
    assert.are.equal(1000, second.widthPresets[1])
  end)

  it("freezes maps, nested maps, and lists", function()
    local config = Config.build()
    assert.has_error(function()
      config.menuTitle = "X"
    end, "configuration is immutable")
    assert.has_error(function()
      config.symbols.left = "X"
    end, "configuration is immutable")
    assert.has_error(function()
      config.widthPresets[1] = 1
    end, "configuration is immutable")
    assert.has_error(function()
      config.aspectPresets[1].label = "X"
    end, "configuration is immutable")
    assert.has_error(function()
      config.obsCrop.dimAlpha = 1
    end, "configuration is immutable")
  end)

  it("rejects unknown top-level and nested keys", function()
    assert.has_error(function()
      Config.build({ nope = true })
    end, "unknown config key: nope")
    assert.has_error(function()
      Config.build({ symbols = { nope = "X" } })
    end, "unknown config key: symbols.nope")
  end)

  it("rejects invalid scalar, map, and list types", function()
    assert.has_error(function()
      Config.build(false)
    end, "config overrides must be a table")
    assert.has_error(function()
      Config.build({ moveStep = "50" })
    end, "invalid config type for moveStep: expected number")
    assert.has_error(function()
      Config.build({ symbols = "bad" })
    end, "invalid config type for symbols: expected table")
    assert.has_error(function()
      Config.build({ widthPresets = { "bad" } })
    end, "invalid config type for widthPresets[1]: expected number")
  end)

  it("rejects malformed sparse lists", function()
    assert.has_error(function()
      Config.build({ widthPresets = { [2] = 200 } })
    end, "invalid config type for widthPresets: expected list")
    assert.has_error(function()
      Config.build({ modalHotkey = { modifiers = { alt = true } } })
    end, "invalid config type for modalHotkey.modifiers: expected list")
  end)

  it("preserves atomic empty-list overrides accepted by the facade baseline", function()
    local config = Config.build({
      widthPresets = {},
      heightPresets = {},
      aspectPresets = {},
      modalHotkey = { modifiers = {} },
    })
    assert.same({}, plain(config.widthPresets))
    assert.same({}, plain(config.heightPresets))
    assert.same({}, plain(config.aspectPresets))
    assert.same({}, plain(config.modalHotkey.modifiers))
  end)

  it("accepts partial aspect entries exactly as the facade baseline did", function()
    local config = Config.build({ aspectPresets = { { label = "partial", width = 1 } } })
    assert.same({ { label = "partial", width = 1 } }, plain(config.aspectPresets))
    assert.has_error(function()
      Config.build({ aspectPresets = { { label = "square", width = 1, height = 1, extra = 2 } } })
    end, "unknown config key: aspectPresets[1].extra")
  end)

  it("rejects invalid undo depths", function()
    for _, value in ipairs({ 0, -1, 1.5 }) do
      assert.has_error(function()
        Config.build({ undoDepth = value })
      end, "CONFIG.undoDepth must be a positive integer")
    end
  end)

  it("rejects non-positive and fractional resize grid steps", function()
    for _, value in ipairs({ 0, -50, 33.3, math.huge }) do
      assert.has_error(function()
        Config.build({ growStep = value })
      end, "CONFIG.growStep must be a positive integer")
    end
  end)

  it("validates the Composition Mode hotkey", function()
    assert.has_error(function()
      Config.build({ compositionHotkey = { key = "" } })
    end, "CONFIG.compositionHotkey.key must not be empty")
    assert.has_error(function()
      Config.build({ compositionHotkey = { modifiers = { "ctrl", "ctrl" } } })
    end, "CONFIG.compositionHotkey.modifiers must contain unique valid modifiers")
    assert.has_error(function()
      Config.build({ compositionHotkey = { modifiers = { "hyper" } } })
    end, "CONFIG.compositionHotkey.modifiers must contain unique valid modifiers")
  end)

  it("validates OBS crop configuration ranges", function()
    for _, value in ipairs({ -1, math.huge, 0 / 0 }) do
      assert.has_error(function()
        Config.build({ obsCrop = { scaleOverride = value } })
      end, "CONFIG.obsCrop.scaleOverride must be zero or a finite positive number")
    end
    for _, value in ipairs({ 0, -1, math.huge, 0 / 0 }) do
      assert.has_error(function()
        Config.build({ obsCrop = { resultDuration = value } })
      end, "CONFIG.obsCrop.resultDuration must be a finite positive number")
    end
    for _, value in ipairs({ 0, -0.1, 1.1, math.huge, 0 / 0 }) do
      assert.has_error(function()
        Config.build({ obsCrop = { dimAlpha = value } })
      end, "CONFIG.obsCrop.dimAlpha must be greater than zero and at most one")
    end
    local config = Config.build({ obsCrop = { scaleOverride = 1.5, resultDuration = 0.5, dimAlpha = 1 } })
    assert.same({ scaleOverride = 1.5, resultDuration = 0.5, dimAlpha = 1 }, plain(config.obsCrop))
  end)

  it("derives consistent mode maps, labels, symbols, and resize deltas", function()
    local _, metadata = Config.build({ symbols = { left = "L", shift = "S" }, growStep = 25 })
    for _, mode in ipairs(metadata.modeSelectors) do
      assert.are.equal(mode.screen, metadata.modeByKey[mode.key])
    end
    for _, corner in ipairs(metadata.cornerActions) do
      assert.are.equal(corner.label, metadata.cornerLabelByName[corner.corner])
    end
    assert.are.equal("S + L", metadata.cornerActions[1].shortcut)
    assert.are.equal(25, metadata.resizeActions[1].deltaWidth)
    assert.are.equal(-25, metadata.resizeActions[3].deltaWidth)
  end)

  it("returns fresh immutable derived metadata per instance", function()
    local _, first = Config.build()
    local _, second = Config.build()
    assert.is_not.equal(first, second)
    assert.is_not.equal(first.modeSelectors, second.modeSelectors)
    assert.has_error(function()
      first.modeByKey.a = "bad"
    end, "configuration is immutable")
    assert.has_error(function()
      first.cornerActions[1].label = "bad"
    end, "configuration is immutable")
  end)

  it("keeps defaults, metadata, and undo-depth validation single-owned by config", function()
    local facade = assert(io.open("Anodyne/init.lua")):read("*a")
    assert.is_nil(facade:match("DEFAULT_CONFIG"))
    assert.is_nil(facade:match("CONFIG%.undoDepth must be a positive integer"))
    assert.is_nil(facade:match("local MODE_SELECTORS%s*=%s*{"))
    assert.is_nil(facade:match("local CORNER_ACTIONS%s*=%s*{"))
    assert.is_nil(facade:match("local RESIZE_ACTIONS%s*=%s*{"))
  end)
end)
