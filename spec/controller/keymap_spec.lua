local Config = require("Anodyne.config")
local Keymap = require("Anodyne.core.keymap")

describe("Anodyne keymap", function()
  local keymap

  before_each(function()
    local _, metadata = Config.build()
    keymap = Keymap.new(metadata)
  end)

  local function intent(screen, key, flags)
    local value, consumed = keymap:interpret(screen, key, flags or {})
    assert.is_true(consumed)
    return value
  end

  it("applies global precedence for exit, undo, reset, selectors, and back", function()
    assert.same({ type = "exit" }, intent("move", "escape"))
    assert.same({ type = "action", action = "undo" }, intent("resize", "u"))
    assert.same({ type = "action", action = "reset" }, intent("resize", "u", { shift = true }))
    assert.same({ type = "transition", screen = "exact" }, intent("move", "e"))
    assert.same({ type = "transition", screen = "aspect" }, intent("move", "a"))
    assert.same({ type = "transition", screen = "width" }, intent("home", "w"))
    assert.same({ type = "transition", screen = "height" }, intent("home", "h"))
    assert.same({ type = "transition", screen = "move" }, intent("home", "m"))
    assert.same({ type = "transition", screen = "resize" }, intent("home", "r"))
    assert.same({ type = "transition", screen = "move" }, intent("move_bottom", "delete"))
    assert.same({ type = "transition", screen = "home" }, intent("width", "delete"))
    assert.same({ type = "status", status = { kind = "already-home" } }, intent("home", "delete"))
  end)

  it("maps every digit as a preset before mode-specific fallback", function()
    for number = 0, 9 do
      assert.same({ type = "preset", index = number }, intent("move", tostring(number)))
    end
  end)

  it("maps every move direction and top/bottom corner exactly", function()
    assert.same({ type = "transition", screen = "move_bottom" }, intent("move", "b"))
    for _, direction in ipairs({ "left", "right", "up", "down" }) do
      assert.same({ type = "action", action = "move", value = direction }, intent("move", direction))
    end
    assert.same({ type = "action", action = "corner", value = "topleft" }, intent("move", "left", { shift = true }))
    assert.same({ type = "action", action = "corner", value = "centertop" }, intent("move", "c"))
    assert.same({ type = "action", action = "corner", value = "topright" }, intent("move", "right", { shift = true }))
    assert.same({ type = "transition", screen = "move" }, intent("move_bottom", "b"))
    assert.same({ type = "action", action = "corner", value = "bottomleft", successScreen = "move" }, intent("move_bottom", "left"))
    assert.same({ type = "action", action = "corner", value = "centerbottom", successScreen = "move" }, intent("move_bottom", "c"))
    assert.same({ type = "action", action = "corner", value = "bottomright", successScreen = "move" }, intent("move_bottom", "right"))
  end)

  it("maps every resize key to its exact configured action", function()
    local expected = {
      right = { 50, 0, "Grow Width" },
      down = { 0, 50, "Grow Height" },
      left = { -50, 0, "Shrink Width" },
      up = { 0, -50, "Shrink Height" },
      g = { 50, 50, "Grow Width + Height" },
      s = { -50, -50, "Shrink Width + Height" },
    }
    for key, values in pairs(expected) do
      local mapped = intent("resize", key)
      assert.are.equal("action", mapped.type)
      assert.are.equal("resize", mapped.action)
      assert.are.equal(values[1], mapped.value.deltaWidth)
      assert.are.equal(values[2], mapped.value.deltaHeight)
      assert.are.equal(values[3], mapped.value.label)
    end
  end)

  it("uses exact unavailable intents for modified global keys, selectors, delete, and numbers", function()
    local keys = { "escape", "u", "e", "a", "w", "h", "m", "r", "delete", "1" }
    local modifiers = { { shift = true }, { cmd = true }, { alt = true }, { ctrl = true }, { shift = true, cmd = true }, { fn = true } }
    for _, key in ipairs(keys) do
      for _, flags in ipairs(modifiers) do
        if not (key == "u" and flags.shift and not flags.cmd and not flags.alt and not flags.ctrl and not flags.fn) then
          assert.same({
            type = "status",
            status = { kind = "unavailable-key", key = key, flags = flags, screen = "home" },
          }, intent("home", key, flags))
        end
      end
    end
  end)

  it("permits Fn only on arrows and preserves shifted-arrow precedence", function()
    assert.are.equal("move", intent("move", "right", { fn = true }).action)
    assert.are.equal("corner", intent("move", "left", { fn = true, shift = true }).action)
    assert.same({
      type = "status",
      status = { kind = "unavailable-key", key = "b", flags = { fn = true }, screen = "move" },
    }, intent("move", "b", { fn = true }))
    assert.same({
      type = "status",
      status = { kind = "unavailable-key", key = "left", flags = { shift = true }, screen = "move_bottom" },
    }, intent("move_bottom", "left", { shift = true }))
  end)

  it("rejects move and resize commands with independently enumerated modifiers", function()
    for _, case in ipairs({
      { "move", "left", { cmd = true } },
      { "move", "right", { alt = true } },
      { "move", "up", { ctrl = true } },
      { "move", "c", { shift = true } },
      { "move_bottom", "c", { fn = true } },
      { "resize", "left", { shift = true } },
      { "resize", "g", { fn = true } },
      { "resize", "s", { cmd = true, alt = true, ctrl = true } },
    }) do
      assert.same({
        type = "status",
        status = { kind = "unavailable-key", key = case[2], flags = case[3], screen = case[1] },
      }, intent(case[1], case[2], case[3]))
    end
  end)

  it("returns exact semantic descriptors for unknown and unavailable keys", function()
    assert.same({ type = "status", status = { kind = "unrecognized-key" } }, intent("home", nil))
    local flags = { cmd = true, shift = true }
    assert.same({
      type = "status",
      status = { kind = "unavailable-key", key = "a", flags = flags, screen = "home" },
    }, intent("home", "a", flags))
    assert.same({
      type = "status",
      status = { kind = "unavailable-key", key = "x", flags = {}, screen = "unknown" },
    }, intent("unknown", "x"))
  end)
end)
