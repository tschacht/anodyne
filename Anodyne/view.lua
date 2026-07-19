local View = {}
View.__index = View

local function append(target, source)
  for _, item in ipairs(source) do
    target[#target + 1] = item
  end
end

local function isArrowKey(key)
  return key == "left" or key == "right" or key == "up" or key == "down"
end

function View.new(config, metadata)
  return setmetatable({ config = config, metadata = metadata }, View)
end

function View:hotkeyLabel()
  return table.concat(self.config.modalHotkey.modifiers, "+") .. "+" .. string.upper(self.config.modalHotkey.key)
end

function View:tooltip()
  return "Window management: " .. self:hotkeyLabel() .. " for keyboard mode"
end

function View:formatKey(key, flags)
  local label = key == "delete" and "Backspace" or (#key == 1 and string.upper(key) or key)
  local modifiers = {}
  for _, modifier in ipairs({ { "ctrl", "Ctrl" }, { "alt", "Alt" }, { "cmd", "Cmd" }, { "shift", "Shift" } }) do
    if flags[modifier[1]] then
      modifiers[#modifiers + 1] = modifier[2]
    end
  end
  if flags.fn and not isArrowKey(key) then
    modifiers[#modifiers + 1] = "Fn"
  end
  return #modifiers > 0 and table.concat(modifiers, "+") .. "+" .. label or label
end

function View:statusText(status)
  if type(status) ~= "table" then
    return status
  elseif status.kind == "unrecognized-key" then
    return "Unrecognized key"
  elseif status.kind == "already-home" then
    return "Already at Home"
  elseif status.kind == "unavailable-key" then
    return string.format("%s is not available in %s", self:formatKey(status.key, status.flags), self.metadata.screenTitles[status.screen] or "this mode")
  elseif status.kind == "unknown-mode" then
    return "Unknown mode " .. tostring(status.screen)
  elseif status.kind == "numbers-unavailable" then
    return "Number keys are not available in " .. (self.metadata.screenTitles[status.screen] or "this mode")
  elseif status.kind == "missing-preset" then
    return string.format("No %s preset %d", string.lower(self.metadata.screenTitles[status.screen]), status.index)
  elseif status.kind == "target-unavailable" then
    return "The target window is no longer available"
  elseif status.kind == "unknown-action" then
    return "Unknown action " .. tostring(status.action)
  end
  return "Unknown status"
end

function View:sizeLine(size)
  if not size then
    return "Current: no focused window"
  end
  return string.format("Current: %d x %d", size.width, size.height)
end

function View:failureText(message)
  return "WI action failed\n" .. (message and self:statusText(message) or "The action could not be completed")
end

function View:resizeLabel(action)
  local magnitude = math.max(math.abs(action.deltaWidth), math.abs(action.deltaHeight))
  local negative = action.deltaWidth < 0 or action.deltaHeight < 0
  return string.format("%s toward %s %d px boundary", action.label, negative and "previous" or "next", magnitude)
end

function View:navigationLine()
  local labels = {}
  for _, selector in ipairs(self.metadata.modeSelectors) do
    labels[#labels + 1] = string.upper(selector.key) .. " " .. selector.label
  end
  return "Modes: " .. table.concat(labels, " · ")
end

function View:modalLines(state, currentSize, status)
  local screen = state.screen or "home"
  local lines = { (self.metadata.screenTitles[screen] or "Window mode") .. ":", self:sizeLine(currentSize), "" }
  if screen == "home" then
    lines[#lines + 1] = "Choose a mode with A, W, H, M, or R"
  elseif screen == "aspect" then
    for index, preset in ipairs(self.config.aspectPresets) do
      lines[#lines + 1] = string.format("%d = %s", index, preset.label)
    end
    if #self.config.aspectPresets == 0 then
      lines[#lines + 1] = ""
    end
  elseif screen == "width" then
    for index, width in ipairs(self.config.widthPresets) do
      lines[#lines + 1] = string.format("%d = %d px", index, width)
    end
    if #self.config.widthPresets == 0 then
      lines[#lines + 1] = ""
    end
  elseif screen == "height" then
    for index, height in ipairs(self.config.heightPresets) do
      lines[#lines + 1] = string.format("%d = %d px", index, height)
    end
    if #self.config.heightPresets == 0 then
      lines[#lines + 1] = ""
    end
  elseif screen == "move" then
    for _, action in ipairs(self.metadata.moveStepActions) do
      lines[#lines + 1] = string.format("%s = %s %d px", action.symbol, string.lower(action.label), self.config.moveStep)
    end
    for _, action in ipairs(self.metadata.cornerActions) do
      if action.screen == "move" then
        lines[#lines + 1] = action.shortcut .. " = " .. string.lower(action.label)
      end
    end
    lines[#lines + 1] = "B = bottom positions"
  elseif screen == "move_bottom" then
    for _, action in ipairs(self.metadata.cornerActions) do
      if action.screen == "move_bottom" then
        lines[#lines + 1] = action.shortcut .. " = " .. string.lower(action.label)
      end
    end
    lines[#lines + 1] = "B or ⌫ = back to Move"
  elseif screen == "resize" then
    for _, action in ipairs(self.metadata.resizeActions) do
      lines[#lines + 1] = action.shortcut .. " = " .. string.lower(self:resizeLabel(action))
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Modes:"
  for _, selector in ipairs(self.metadata.modeSelectors) do
    lines[#lines + 1] = string.upper(selector.key) .. " = " .. selector.label
  end
  lines[#lines + 1] = "U = undo last action"
  lines[#lines + 1] = "Shift+U = reset session"
  lines[#lines + 1] = "Navigation: ⌫ = back/home · Esc = exit"
  if status then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Status: " .. self:statusText(status)
  end
  return lines
end

function View:modalText(state, currentSize, status)
  return table.concat(self:modalLines(state, currentSize, status), "\n")
end

function View:menuItems(state, sessionScreenChanged)
  local snapshot = state.active and state.sessionInitialFrame and state.sessionInitialScreen
  local resetAvailable = snapshot and not sessionScreenChanged
  local resetTitle = "Reset Session [Shift+U]"
  if snapshot and sessionScreenChanged then
    resetTitle = resetTitle .. " (screen configuration changed)"
  end
  local items = {
    { title = "Keyboard Mode: " .. self:hotkeyLabel(), disabled = true },
    { title = self:navigationLine(), disabled = true },
    { title = "Navigation: ⌫ = back/home · Esc = exit", disabled = true },
    { title = "Undo Last Action [U]", intent = { type = "action", action = "undo" } },
    { title = resetTitle, disabled = not resetAvailable, intent = { type = "action", action = "reset" } },
    { title = "-" },
    { title = string.format("Aspect Presets [A then 1-%d]", #self.config.aspectPresets), disabled = true },
  }
  for index, preset in ipairs(self.config.aspectPresets) do
    items[#items + 1] = { title = string.format("%s [A %d]", preset.label, index), intent = { type = "action", action = "aspect", value = preset } }
  end
  append(items, { { title = "-" }, { title = string.format("Width Presets [W then 1-%d]", #self.config.widthPresets), disabled = true } })
  for index, width in ipairs(self.config.widthPresets) do
    items[#items + 1] = { title = string.format("%d px [W %d]", width, index), intent = { type = "action", action = "width", value = width } }
  end
  append(items, { { title = "-" }, { title = string.format("Height Presets [H then 1-%d]", #self.config.heightPresets), disabled = true } })
  for index, height in ipairs(self.config.heightPresets) do
    items[#items + 1] = { title = string.format("%d px [H %d]", height, index), intent = { type = "action", action = "height", value = height } }
  end
  append(items, { { title = "-" }, { title = "Move " .. self.config.moveStep .. " px [M then arrows / C / B]", disabled = true } })
  for _, action in ipairs(self.metadata.moveStepActions) do
    items[#items + 1] =
      { title = string.format("%s [M %s]", action.label, action.symbol), intent = { type = "action", action = "move", value = action.direction } }
  end
  for _, action in ipairs(self.metadata.cornerActions) do
    local shortcut = action.screen == "move_bottom" and "M B " .. action.shortcut or "M " .. action.shortcut
    items[#items + 1] = { title = string.format("%s [%s]", action.label, shortcut), intent = { type = "action", action = "corner", value = action.corner } }
  end
  append(items, { { title = "-" }, { title = "Resize toward " .. self.config.growStep .. " px grid [R then arrows / G / S]", disabled = true } })
  for _, action in ipairs(self.metadata.resizeActions) do
    items[#items + 1] = { title = string.format("%s [R %s]", action.label, action.shortcut), intent = { type = "action", action = "resize", value = action } }
  end
  return items
end

return View
