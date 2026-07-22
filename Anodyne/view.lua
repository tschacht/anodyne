local View = {}
View.__index = View

local captureSourceLabels = {
  screen = "Screen Capture",
  window = "Window Capture",
}

local cropEdges = {
  { edge = "left", label = "L" },
  { edge = "top", label = "T" },
  { edge = "right", label = "R" },
  { edge = "bottom", label = "B" },
}

local function append(target, source)
  for _, item in ipairs(source) do
    target[#target + 1] = item
  end
end

local function isArrowKey(key)
  return key == "left" or key == "right" or key == "up" or key == "down"
end

local function capitalize(value)
  return value:sub(1, 1):upper() .. value:sub(2)
end

function View.new(config, metadata)
  return setmetatable({ config = config, metadata = metadata }, View)
end

function View:hotkeyLabel()
  return table.concat(self.config.modalHotkey.modifiers, "+") .. "+" .. string.upper(self.config.modalHotkey.key)
end

function View:compositionHotkeyLabel()
  return table.concat(self.config.compositionHotkey.modifiers, "+") .. "+" .. string.upper(self.config.compositionHotkey.key)
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

function View:captureSourceLabel(source)
  return captureSourceLabels[source] or "Unknown capture source"
end

function View:cropEdgeLabels(preview)
  local labels = {}
  for _, definition in ipairs(cropEdges) do
    local value = preview[definition.edge]
    labels[#labels + 1] = {
      edge = definition.edge,
      text = string.format("%s %d", definition.label, value),
      value = value,
      invalid = preview.invalid[definition.edge] == true,
    }
  end
  return labels
end

function View:statusText(status, source)
  if type(status) ~= "table" then
    return status
  end
  local code = status.code or status.kind
  if code == "unrecognized-key" then
    return "Unrecognized key"
  elseif code == "already-home" then
    return "Already at Home"
  elseif code == "unavailable-key" then
    return string.format("%s is not available in %s", self:formatKey(status.key, status.flags), self.metadata.screenTitles[status.screen] or "this mode")
  elseif code == "unknown-mode" then
    return "Unknown mode " .. tostring(status.screen)
  elseif code == "numbers-unavailable" then
    return "Number keys are not available in " .. (self.metadata.screenTitles[status.screen] or "this mode")
  elseif code == "missing-preset" then
    return string.format("No %s preset %d", string.lower(self.metadata.screenTitles[status.screen]), status.index)
  elseif code == "target-unavailable" or code == "stale-target" or code == "stale-window" then
    return "The target window is no longer available"
  elseif code == "unknown-action" then
    return "Unknown action " .. tostring(status.action)
  elseif code == "outside_final" then
    local edge = ({ left = "left", top = "top", right = "right", bottom = "bottom" })[status.edge]
    local captureSource = source or status.source
    if captureSource == "window" then
      local location = edge and (" at the " .. edge .. " edge") or ""
      return "The locked guide is outside the final window" .. location .. "; resize or reposition the window"
    elseif captureSource == "screen" then
      local location = edge and (" at the " .. edge .. " edge") or ""
      return "The locked guide is outside the frozen screen" .. location .. "; press W for Window Capture or Esc to cancel"
    elseif captureSource ~= nil then
      return "Unknown capture source"
    end
    return edge and ("The locked guide is outside the final window at the " .. edge .. " edge") or "The locked guide is outside the final window"
  elseif code == "invalid-source" then
    return "Unknown capture source"
  elseif code == "invalid_rect" then
    local rect = ({ final = "final window", guide = "locked guide" })[status.rect]
    return rect and ("Invalid " .. rect .. " geometry") or "Invalid crop geometry"
  elseif code == "invalid_scale" then
    return "Invalid display scale"
  elseif code == "stale-screen" then
    return "The screen geometry changed; Composition Mode was cancelled"
  elseif code == "stale-scale" then
    return "The display scale changed; Composition Mode was cancelled"
  elseif code == "stale-geometry" then
    return "The captured geometry changed; Composition Mode was cancelled"
  elseif code == "copy-failed" or code == "pasteboard-failed" then
    return "Could not copy OBS crop values; Composition Mode is still active"
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

function View:compositionHelpText(baseline, status, source)
  local dimensions = baseline and string.format("%d x %d", math.floor(baseline.width + 0.5), math.floor(baseline.height + 0.5)) or "unavailable"
  local lines = { "Composition Mode:", "Locked baseline: " .. dimensions }
  if source ~= nil then
    lines[#lines + 1] = "Selected source: " .. self:captureSourceLabel(source)
    lines[#lines + 1] = "S = Screen Capture · W = Window Capture"
  end
  lines[#lines + 1] = "Return = Finish/Copy"
  lines[#lines + 1] = "Esc = Cancel"
  if status then
    lines[#lines + 1] = "Status: " .. self:statusText(status, source)
  end
  return table.concat(lines, "\n")
end

function View:cropClipboardText(result, source)
  local body = string.format(
    "Left: %d, Top: %d, Right: %d, Bottom: %d | Result: %d x %d | Scale: %s",
    result.left,
    result.top,
    result.right,
    result.bottom,
    result.resultWidth,
    result.resultHeight,
    tostring(result.scale)
  )
  if source == nil then
    return body
  end
  local label = captureSourceLabels[source]
  return label and label .. " | " .. body or nil
end

function View:cropResultText(result, source)
  local text = self:cropClipboardText(result)
  if source == nil then
    return text
  end
  local label = captureSourceLabels[source]
  return label and label .. "\n" .. text or nil
end

function View:resizeLabel(action)
  local magnitude = math.max(math.abs(action.deltaWidth), math.abs(action.deltaHeight))
  local negative = action.deltaWidth < 0 or action.deltaHeight < 0
  local both = action.deltaWidth ~= 0 and action.deltaHeight ~= 0
  return string.format("%s%s to %s %d px", negative and "Shrink" or "Grow", both and " both" or "", negative and "previous" or "next", magnitude)
end

function View:moveLabel(action)
  return string.format("%s %d px", capitalize(action.direction), self.config.moveStep)
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
    lines[#lines + 1] = "Choose a mode with E, A, W, H, M, or R"
  elseif screen == "exact" then
    for index, preset in ipairs(self.config.exactPresets) do
      lines[#lines + 1] = string.format("%d = %d x %d px", index, preset.width, preset.height)
    end
    if #self.config.exactPresets == 0 then
      lines[#lines + 1] = ""
    end
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
      lines[#lines + 1] = string.format("%s = %s", action.symbol, self:moveLabel(action))
    end
    for _, action in ipairs(self.metadata.cornerActions) do
      if action.screen == "move" then
        lines[#lines + 1] = action.shortcut .. " = " .. action.label
      end
    end
    lines[#lines + 1] = "B = bottom positions"
  elseif screen == "move_bottom" then
    for _, action in ipairs(self.metadata.cornerActions) do
      if action.screen == "move_bottom" then
        lines[#lines + 1] = action.shortcut .. " = " .. action.label
      end
    end
    lines[#lines + 1] = "B or ⌫ = back to Move"
  elseif screen == "resize" then
    for _, action in ipairs(self.metadata.resizeActions) do
      lines[#lines + 1] = action.shortcut .. " = " .. self:resizeLabel(action)
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
    { title = string.format("Exact pixels [E then 1-%d]", #self.config.exactPresets), disabled = true },
  }
  for index, preset in ipairs(self.config.exactPresets) do
    items[#items + 1] = {
      title = string.format("%d x %d px [E %d]", preset.width, preset.height, index),
      intent = { type = "action", action = "exact", value = preset },
    }
  end
  append(items, { { title = "-" }, { title = string.format("Aspect [A then 1-%d]", #self.config.aspectPresets), disabled = true } })
  for index, preset in ipairs(self.config.aspectPresets) do
    items[#items + 1] = { title = string.format("%s [A %d]", preset.label, index), intent = { type = "action", action = "aspect", value = preset } }
  end
  append(items, { { title = "-" }, { title = string.format("Width [W then 1-%d]", #self.config.widthPresets), disabled = true } })
  for index, width in ipairs(self.config.widthPresets) do
    items[#items + 1] = { title = string.format("%d px [W %d]", width, index), intent = { type = "action", action = "width", value = width } }
  end
  append(items, { { title = "-" }, { title = string.format("Height [H then 1-%d]", #self.config.heightPresets), disabled = true } })
  for index, height in ipairs(self.config.heightPresets) do
    items[#items + 1] = { title = string.format("%d px [H %d]", height, index), intent = { type = "action", action = "height", value = height } }
  end
  append(items, { { title = "-" }, { title = "Move [M then arrows / C / B]", disabled = true } })
  for _, action in ipairs(self.metadata.moveStepActions) do
    items[#items + 1] =
      { title = string.format("%s [M %s]", self:moveLabel(action), action.symbol), intent = { type = "action", action = "move", value = action.direction } }
  end
  for _, action in ipairs(self.metadata.cornerActions) do
    local shortcut = action.screen == "move_bottom" and "M B " .. action.shortcut or "M " .. action.shortcut
    items[#items + 1] = { title = string.format("%s [%s]", action.label, shortcut), intent = { type = "action", action = "corner", value = action.corner } }
  end
  append(items, { { title = "-" }, { title = "Resize [R then arrows / G / S]", disabled = true } })
  for _, action in ipairs(self.metadata.resizeActions) do
    items[#items + 1] =
      { title = string.format("%s [R %s]", self:resizeLabel(action), action.shortcut), intent = { type = "action", action = "resize", value = action } }
  end
  append(items, {
    { title = "-" },
    { title = "Composition Mode: " .. self:compositionHotkeyLabel(), intent = { type = "composition", action = "enter" } },
  })
  return items
end

return View
