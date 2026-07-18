local Keymap = {}
Keymap.__index = Keymap

local function isArrowKey(key)
  return key == "left" or key == "right" or key == "up" or key == "down"
end

local function isPlain(key, flags)
  return not flags.cmd and not flags.alt and not flags.ctrl and not flags.shift and (isArrowKey(key) or not flags.fn)
end

local function isShifted(key, flags)
  return flags.shift == true and not flags.cmd and not flags.alt and not flags.ctrl and (isArrowKey(key) or not flags.fn)
end

local function find(items, predicate)
  for _, item in ipairs(items) do
    if predicate(item) then
      return item
    end
  end
end

function Keymap.new(metadata)
  return setmetatable({ metadata = metadata }, Keymap)
end

function Keymap:interpret(screen, key, flags)
  screen = screen or "home"
  flags = flags or {}
  if key == nil then
    return { type = "status", status = { kind = "unrecognized-key" } }, true
  end

  local plain = isPlain(key, flags)
  local shifted = isShifted(key, flags)
  if plain and key == "escape" then
    return { type = "exit" }, true
  end
  if plain and key == "u" then
    return { type = "action", action = "undo" }, true
  end
  if shifted and key == "u" then
    return { type = "action", action = "reset" }, true
  end
  if plain and self.metadata.modeByKey[key] then
    return { type = "transition", screen = self.metadata.modeByKey[key] }, true
  end
  if plain and key == "delete" then
    if screen == "move_bottom" then
      return { type = "transition", screen = "move" }, true
    end
    if screen ~= "home" then
      return { type = "transition", screen = "home" }, true
    end
    return { type = "status", status = { kind = "already-home" } }, true
  end

  local number = plain and tonumber(key) or nil
  if number then
    return { type = "preset", index = number }, true
  end

  if screen == "move" then
    if plain and key == "b" then
      return { type = "transition", screen = "move_bottom" }, true
    end
    local corner = find(self.metadata.cornerActions, function(action)
      return action.screen == screen and action.key == key and (action.shifted == true) == shifted
    end)
    if corner and (plain or shifted) then
      return { type = "action", action = "corner", value = corner.corner }, true
    end
    if plain then
      local step = find(self.metadata.moveStepActions, function(action)
        return action.key == key
      end)
      if step then
        return { type = "action", action = "move", value = step.direction }, true
      end
    end
  elseif screen == "move_bottom" then
    if plain and key == "b" then
      return { type = "transition", screen = "move" }, true
    end
    if plain then
      local corner = find(self.metadata.cornerActions, function(action)
        return action.screen == screen and action.key == key and action.shifted ~= true
      end)
      if corner then
        return { type = "action", action = "corner", value = corner.corner, successScreen = "move" }, true
      end
    end
  elseif screen == "resize" and plain then
    local resize = find(self.metadata.resizeActions, function(action)
      return action.key == key
    end)
    if resize then
      return { type = "action", action = "resize", value = resize }, true
    end
  end

  return {
    type = "status",
    status = { kind = "unavailable-key", key = key, flags = flags, screen = screen },
  }, true
end

return Keymap
