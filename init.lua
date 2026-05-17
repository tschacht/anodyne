local CONFIG = {
  menuTitle = "WI",
  alertDuration = 0.4,
  modalDuration = 5,
  symbols = {
    left = "←",
    up = "↑",
    right = "→",
    down = "↓",
    shift = "shift",
  },
  winWinGridParts = 50,
  minimumWidth = 500,
  minimumHeight = 500,
  modalHotkey = {
    modifiers = { "ctrl", "alt", "cmd" },
    key = "m",
  },
  aspectPresets = {
    { label = "16:9", width = 16, height = 9 },
    { label = "4:3", width = 4, height = 3 },
    { label = "3:2", width = 3, height = 2 },
    { label = "2:1", width = 2, height = 1 },
    { label = "3:1", width = 3, height = 1 },
  },
  widthPresets = { 1400, 1600, 1800, 2000, 2200, 2400, 2600 },
  heightPresets = { 1000, 1200, 1400, 1500 },
  growStep = 50,
  moveStep = 50,
  cornerPresets = {
    { label = "Top Left", key = "topleft" },
    { label = "Center Top", key = "centertop" },
    { label = "Top Right", key = "topright" },
    { label = "Bottom Left", key = "bottomleft" },
    { label = "Bottom Right", key = "bottomright" },
  },
}

local WindowManager = rawget(_G, "WindowManager") or {}
_G.WindowManager = WindowManager
local windowMode

local function deleteObject(object)
  if object and object.delete then
    pcall(function()
      object:delete()
    end)
  end
end

deleteObject(WindowManager.entryHotkey)
deleteObject(WindowManager.windowMode)
deleteObject(WindowManager.modalTimer)
deleteObject(WindowManager.modalCanvas)
deleteObject(WindowManager.modalKeyGuard)

local winwin = hs.loadSpoon("WinWin")
if not winwin then
  error("Failed to load WinWin spoon")
end

winwin.gridparts = CONFIG.winWinGridParts

WindowManager.menu = hs.menubar.new()
local menu = WindowManager.menu
if not menu then
  error("Failed to create menu bar item")
end

WindowManager.windowFilter = hs.window.filter.new()
local windowFilter = WindowManager.windowFilter
WindowManager.lastFocusedWindow = hs.window.frontmostWindow()

local function alert(message)
  hs.alert.show(message, { textSize = 18 }, nil, CONFIG.alertDuration)
end

local function formatModalHotkeyLabel()
  return table.concat(CONFIG.modalHotkey.modifiers, "+") .. "+" .. string.upper(CONFIG.modalHotkey.key)
end

local function closeModalOverlay()
  if WindowManager.modalCanvas then
    pcall(function()
      WindowManager.modalCanvas:hide()
      WindowManager.modalCanvas:delete()
    end)
    WindowManager.modalCanvas = nil
  end
end

local function stopModalKeyGuard()
  if WindowManager.modalKeyGuard then
    pcall(function()
      WindowManager.modalKeyGuard:stop()
    end)
    pcall(function()
      WindowManager.modalKeyGuard:delete()
    end)
    WindowManager.modalKeyGuard = nil
  end
end

local function modalAlert(message)
  closeModalOverlay()

  local screenFrame = hs.screen.mainScreen():frame()
  local lines = hs.fnutils.split(message, "\n")
  local longestLine = 0

  for _, line in ipairs(lines) do
    longestLine = math.max(longestLine, #line)
  end

  local width = math.min(math.max(280, longestLine * 12 + 48), math.floor(screenFrame.w * 0.8))
  local height = math.min(math.max(90, #lines * 28 + 36), math.floor(screenFrame.h * 0.7))
  local frame = {
    x = math.floor(screenFrame.x + (screenFrame.w - width) / 2),
    y = math.floor(screenFrame.y + 60),
    w = width,
    h = height,
  }

  local canvas = hs.canvas.new(frame)
  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  canvas[1] = {
    type = "rectangle",
    action = "fill",
    fillColor = { red = 0.08, green = 0.08, blue = 0.08, alpha = 0.92 },
    roundedRectRadii = { xRadius = 12, yRadius = 12 },
  }
  canvas[2] = {
    type = "text",
    text = message,
    textSize = 20,
    textColor = { white = 1, alpha = 1 },
    textFont = "Menlo",
    textAlignment = "left",
    frame = { x = 20, y = 14, w = width - 40, h = height - 28 },
  }
  canvas:show()
  WindowManager.modalCanvas = canvas
end

local function getValidWindow(candidate)
  if not candidate then
    return nil
  end

  local ok, windowId = pcall(function()
    return candidate:id()
  end)
  if not ok or not windowId then
    return nil
  end

  local screenOk, screen = pcall(function()
    return candidate:screen()
  end)
  if not screenOk or not screen then
    return nil
  end

  return candidate, screen
end

local function getFocusedWindow()
  local win = getValidWindow(hs.window.focusedWindow())
  if win then
    WindowManager.lastFocusedWindow = win
    return win
  end

  win = getValidWindow(WindowManager.lastFocusedWindow)
  if win then
    return win
  end

  win = getValidWindow(hs.window.frontmostWindow())
  if not win then
    alert("No focused window")
    return nil
  end

  WindowManager.lastFocusedWindow = win
  return win
end

local function round(value)
  return math.floor(value + 0.5)
end

local function clamp(value, minValue, maxValue)
  if maxValue < minValue then
    return minValue
  end

  return math.max(minValue, math.min(value, maxValue))
end

local function clampFrameToScreen(frame, screenFrame)
  local width = clamp(round(frame.w), CONFIG.minimumWidth, round(screenFrame.w))
  local height = clamp(round(frame.h), CONFIG.minimumHeight, round(screenFrame.h))
  local maxX = round(screenFrame.x + screenFrame.w - width)
  local maxY = round(screenFrame.y + screenFrame.h - height)

  return {
    x = clamp(round(frame.x), round(screenFrame.x), maxX),
    y = clamp(round(frame.y), round(screenFrame.y), maxY),
    w = width,
    h = height,
  }
end

local function applyFrame(win, frame, label, options)
  local screenFrame = win:screen():frame()
  local clampedFrame = clampFrameToScreen(frame, screenFrame)
  win:setFrame(clampedFrame)

  if options and options.showSize then
    alert(string.format("%s (%d x %d)", label, clampedFrame.w, clampedFrame.h))
  else
    alert(label)
  end
end

local function applyAspectPreset(preset)
  local win = getFocusedWindow()
  if not win then
    return
  end

  local currentFrame = win:frame()
  local targetHeight = currentFrame.w * preset.height / preset.width

  applyFrame(win, {
    x = currentFrame.x,
    y = currentFrame.y,
    w = currentFrame.w,
    h = targetHeight,
  }, "Aspect " .. preset.label, { showSize = true })
end

local function applyWidthPreset(width)
  local win = getFocusedWindow()
  if not win then
    return
  end

  local currentFrame = win:frame()

  applyFrame(win, {
    x = currentFrame.x,
    y = currentFrame.y,
    w = width,
    h = currentFrame.h,
  }, string.format("Width %d px", width), { showSize = true })
end

local function applyHeightPreset(height)
  local win = getFocusedWindow()
  if not win then
    return
  end

  local currentFrame = win:frame()

  applyFrame(win, {
    x = currentFrame.x,
    y = currentFrame.y,
    w = currentFrame.w,
    h = height,
  }, string.format("Height %d px", height), { showSize = true })
end

local function moveToCorner(corner)
  local win = getFocusedWindow()
  if not win then
    return
  end

  local currentFrame = win:frame()
  local screenFrame = win:screen():frame()
  local targetFrame = {
    x = currentFrame.x,
    y = currentFrame.y,
    w = currentFrame.w,
    h = currentFrame.h,
  }

  if corner == "topleft" then
    targetFrame.x = screenFrame.x
    targetFrame.y = screenFrame.y
  elseif corner == "centertop" then
    targetFrame.x = screenFrame.x + (screenFrame.w - currentFrame.w) / 2
    targetFrame.y = screenFrame.y
  elseif corner == "topright" then
    targetFrame.x = screenFrame.x + screenFrame.w - currentFrame.w
    targetFrame.y = screenFrame.y
  elseif corner == "bottomleft" then
    targetFrame.x = screenFrame.x
    targetFrame.y = screenFrame.y + screenFrame.h - currentFrame.h
  elseif corner == "bottomright" then
    targetFrame.x = screenFrame.x + screenFrame.w - currentFrame.w
    targetFrame.y = screenFrame.y + screenFrame.h - currentFrame.h
  else
    alert("Unknown corner: " .. tostring(corner))
    return
  end

  applyFrame(win, targetFrame, "Move " .. corner)
end

local function growWindow(deltaWidth, deltaHeight, label)
  local win = getFocusedWindow()
  if not win then
    return
  end

  local currentFrame = win:frame()

  applyFrame(win, {
    x = currentFrame.x,
    y = currentFrame.y,
    w = currentFrame.w + deltaWidth,
    h = currentFrame.h + deltaHeight,
  }, label, { showSize = true })
end

local function shrinkWindow(deltaWidth, deltaHeight, label)
  local win = getFocusedWindow()
  if not win then
    return
  end

  local currentFrame = win:frame()

  applyFrame(win, {
    x = currentFrame.x,
    y = currentFrame.y,
    w = currentFrame.w - deltaWidth,
    h = currentFrame.h - deltaHeight,
  }, label, { showSize = true })
end

WindowManager.modalState = WindowManager.modalState or { group = nil, moveBottomMode = false }
local modalState = WindowManager.modalState
WindowManager.modalFlags = WindowManager.modalFlags or {}

local function resetModalState()
  modalState.group = nil
  modalState.moveBottomMode = false
end

local function stopModalTimer()
  if WindowManager.modalTimer then
    pcall(function()
      WindowManager.modalTimer:stop()
    end)
    WindowManager.modalTimer = nil
  end
end

local function startModalTimer()
  stopModalTimer()
  WindowManager.modalTimer = hs.timer.doAfter(CONFIG.modalDuration, function()
    if windowMode then
      windowMode:exit()
    end
  end)
end

local function getModalHomeWindow()
  local win = getValidWindow(hs.window.focusedWindow())
  if win then
    WindowManager.lastFocusedWindow = win
    return win
  end

  win = getValidWindow(WindowManager.lastFocusedWindow)
  if win then
    return win
  end

  win = getValidWindow(hs.window.frontmostWindow())
  if win then
    WindowManager.lastFocusedWindow = win
  end

  return win
end

local function formatCurrentWindowSize()
  local win = getModalHomeWindow()
  if not win then
    return "Current: no focused window"
  end

  local frame = win:frame()
  return string.format("Current: %d x %d", round(frame.w), round(frame.h))
end

local function showModalHome()
  modalAlert(table.concat({
    "Window mode:",
    formatCurrentWindowSize(),
    "",
    "A = aspect",
    "W = width",
    "H = height",
    "M = move",
    "R = resize",
    "Esc = cancel",
  }, "\n"))
end

local function formatPresetOptions(presets, labelFn)
  local labels = {}

  for index, preset in ipairs(presets) do
    table.insert(labels, string.format("%d = %s", index, labelFn(preset)))
  end

  return table.concat(labels, "\n")
end

local function showModalGroupPrompt(group)
  startModalTimer()

  if group == "aspect" then
    modalAlert("Aspect preset:\n" .. formatPresetOptions(CONFIG.aspectPresets, function(preset)
      return preset.label
    end))
  elseif group == "width" then
    modalAlert("Width preset:\n" .. formatPresetOptions(CONFIG.widthPresets, function(width)
      return tostring(width)
    end))
  elseif group == "height" then
    modalAlert("Height preset:\n" .. formatPresetOptions(CONFIG.heightPresets, function(height)
      return tostring(height)
    end))
  elseif group == "move" then
    if modalState.moveBottomMode then
      modalAlert(table.concat({
        "Move bottom corners:",
        CONFIG.symbols.left .. " = bottom-left",
        CONFIG.symbols.right .. " = bottom-right",
        "B = back",
      }, "\n"))
    else
      modalAlert(table.concat({
        "Move:",
        CONFIG.symbols.left .. " = move left " .. CONFIG.moveStep,
        CONFIG.symbols.right .. " = move right " .. CONFIG.moveStep,
        CONFIG.symbols.up .. " = move up " .. CONFIG.moveStep,
        CONFIG.symbols.down .. " = move down " .. CONFIG.moveStep,
        CONFIG.symbols.shift .. " + " .. CONFIG.symbols.left .. " = top-left",
        CONFIG.symbols.shift .. " + " .. CONFIG.symbols.right .. " = top-right",
        "C = center-top",
        "B = bottom corners",
      }, "\n"))
    end
  elseif group == "resize" then
    modalAlert(table.concat({
      "Resize:",
      CONFIG.symbols.right .. " = grow width",
      CONFIG.symbols.down .. " = grow height",
      CONFIG.symbols.left .. " = shrink width",
      CONFIG.symbols.up .. " = shrink height",
      "G = grow width + height",
      "S = shrink width + height",
    }, "\n"))
  end
end

local function setModalGroup(group)
  modalState.group = group
  modalState.moveBottomMode = false
  showModalGroupPrompt(group)
end

local function selectPreset(presets, index, applyFn, label)
  local preset = presets[index]
  if not preset then
    modalAlert("No " .. label .. " preset " .. tostring(index))
    return false
  end

  applyFn(preset)
  return true
end

local function handleNumberSelection(index)
  startModalTimer()

  if modalState.group == "aspect" then
    if not selectPreset(CONFIG.aspectPresets, index, applyAspectPreset, "aspect") then
      return
    end
  elseif modalState.group == "width" then
    if not selectPreset(CONFIG.widthPresets, index, applyWidthPreset, "width") then
      return
    end
  elseif modalState.group == "height" then
    if not selectPreset(CONFIG.heightPresets, index, applyHeightPreset, "height") then
      return
    end
  else
    modalAlert("Choose A, W, or H first")
    return
  end
end

local function snapPositionForDirection(origin, current, step, direction)
  local relative = current - origin

  if direction == "left" or direction == "up" then
    return origin + (math.ceil(relative / step) - 1) * step
  elseif direction == "right" or direction == "down" then
    return origin + (math.floor(relative / step) + 1) * step
  end

  return current
end

local function moveByStep(direction)
  local win = getFocusedWindow()
  if not win then
    return
  end

  local currentFrame = win:frame()
  local screenFrame = win:screen():frame()
  local targetFrame = {
    x = currentFrame.x,
    y = currentFrame.y,
    w = currentFrame.w,
    h = currentFrame.h,
  }

  if direction == "left" or direction == "right" then
    targetFrame.x = snapPositionForDirection(screenFrame.x, currentFrame.x, CONFIG.moveStep, direction)
  elseif direction == "up" or direction == "down" then
    targetFrame.y = snapPositionForDirection(screenFrame.y, currentFrame.y, CONFIG.moveStep, direction)
  else
    alert("Unknown move direction: " .. tostring(direction))
    return
  end

  applyFrame(win, targetFrame, string.format("Move %s %d px", direction, CONFIG.moveStep))
end

local function handleMoveSelection(direction, shifted)
  startModalTimer()

  if modalState.group ~= "move" then
    modalAlert("Press M first")
    return
  end

  if modalState.moveBottomMode then
    if direction == "left" then
      moveToCorner("bottomleft")
      modalState.moveBottomMode = false
    elseif direction == "right" then
      moveToCorner("bottomright")
      modalState.moveBottomMode = false
    elseif direction == "b" then
      modalState.moveBottomMode = false
      showModalGroupPrompt("move")
      return
    else
      modalAlert("Use Left, Right, or B")
      return
    end
  end

  if direction == "c" then
    moveToCorner("centertop")
  elseif direction == "b" then
    modalState.moveBottomMode = true
    showModalGroupPrompt("move")
    return
  elseif direction == "left" and shifted then
    moveToCorner("topleft")
  elseif direction == "right" and shifted then
    moveToCorner("topright")
  elseif direction == "left" or direction == "right" or direction == "up" or direction == "down" then
    moveByStep(direction)
  else
    modalAlert("Use arrows, Shift+Left, Shift+Right, C, or B")
    return
  end

  showModalGroupPrompt("move")
end

local function handleSizeSelection(direction)
  startModalTimer()

  if modalState.group ~= "resize" then
    modalAlert("Press R first")
    return
  end

  if direction == "right" then
    growWindow(CONFIG.growStep, 0, "Grow width +" .. CONFIG.growStep .. " px")
  elseif direction == "down" then
    growWindow(0, CONFIG.growStep, "Grow height +" .. CONFIG.growStep .. " px")
  elseif direction == "left" then
    shrinkWindow(CONFIG.growStep, 0, "Shrink width -" .. CONFIG.growStep .. " px")
  elseif direction == "up" then
    shrinkWindow(0, CONFIG.growStep, "Shrink height -" .. CONFIG.growStep .. " px")
  else
    modalAlert("Use Left, Up, Right, or Down")
    return
  end
end

local function handleResizeShortcut(action)
  startModalTimer()

  if modalState.group ~= "resize" then
    modalAlert("Press R first")
    return
  end

  if action == "grow_both" then
    growWindow(CONFIG.growStep, CONFIG.growStep, "Grow size +" .. CONFIG.growStep .. " px")
  elseif action == "shrink_both" then
    shrinkWindow(CONFIG.growStep, CONFIG.growStep, "Shrink size -" .. CONFIG.growStep .. " px")
  else
    modalAlert("Use G or S in resize mode")
  end
end

local function hasOnlyShift(flags)
  if not flags.shift then
    return false
  end

  for key, enabled in pairs(flags) do
    if enabled and key ~= "shift" then
      return false
    end
  end

  return true
end

local function hasOnlyModalEntryModifiers(flags)
  local expected = {}

  for _, modifier in ipairs(CONFIG.modalHotkey.modifiers) do
    expected[modifier] = true
  end

  for key, enabled in pairs(flags) do
    if enabled and not expected[key] then
      return false
    end
  end

  for modifier, _ in pairs(expected) do
    if not flags[modifier] then
      return false
    end
  end

  return true
end

local function isPlainModalKey(keyName, flags)
  if next(flags) ~= nil then
    return false
  end

  return keyName == "escape"
    or keyName == "a"
    or keyName == "w"
    or keyName == "h"
    or keyName == "m"
    or keyName == "b"
    or keyName == "c"
    or keyName == "r"
    or keyName == "g"
    or keyName == "s"
    or keyName == "up"
    or keyName == "down"
    or keyName == "left"
    or keyName == "right"
    or tonumber(keyName) ~= nil
end

local function isAllowedModalKey(keyName, flags)
  return isPlainModalKey(keyName, flags) or (hasOnlyShift(flags) and (keyName == "left" or keyName == "right"))
end

local function handleModalKey(keyName, flags)
  if keyName == "escape" and next(flags) == nil then
    windowMode:exit()
    return true
  end

  if keyName == "a" and next(flags) == nil then
    setModalGroup("aspect")
    return true
  end

  if keyName == "w" and next(flags) == nil then
    setModalGroup("width")
    return true
  end

  if keyName == "h" and next(flags) == nil then
    setModalGroup("height")
    return true
  end

  if keyName == "m" and next(flags) == nil then
    setModalGroup("move")
    return true
  end

  if keyName == "b" and next(flags) == nil then
    handleMoveSelection("b", false)
    return true
  end

  if keyName == "c" and next(flags) == nil then
    handleMoveSelection("c", false)
    return true
  end

  if keyName == "r" and next(flags) == nil then
    setModalGroup("resize")
    return true
  end

  if keyName == "g" and next(flags) == nil then
    handleResizeShortcut("grow_both")
    return true
  end

  if keyName == "s" and next(flags) == nil then
    handleResizeShortcut("shrink_both")
    return true
  end

  local number = tonumber(keyName)
  if number and next(flags) == nil then
    handleNumberSelection(number)
    return true
  end

  if keyName == "up" and next(flags) == nil then
    if modalState.group == "move" then
      handleMoveSelection("up", false)
    else
      handleSizeSelection("up")
    end
    return true
  end

  if keyName == "down" and next(flags) == nil then
    if modalState.group == "move" then
      handleMoveSelection("down", false)
    else
      handleSizeSelection("down")
    end
    return true
  end

  if keyName == "left" then
    if hasOnlyShift(flags) then
      handleMoveSelection("left", true)
      return true
    end

    if next(flags) == nil then
      if modalState.group == "move" then
        handleMoveSelection("left", false)
      else
        handleSizeSelection("left")
      end
      return true
    end
  end

  if keyName == "right" then
    if hasOnlyShift(flags) then
      handleMoveSelection("right", true)
      return true
    end

    if next(flags) == nil then
      if modalState.group == "move" then
        handleMoveSelection("right", false)
      else
        handleSizeSelection("right")
      end
      return true
    end
  end

  return false
end

local function startModalKeyGuard()
  stopModalKeyGuard()
  WindowManager.modalFlags = {}

  WindowManager.modalKeyGuard = hs.eventtap.new({
    hs.eventtap.event.types.keyDown,
    hs.eventtap.event.types.keyUp,
    hs.eventtap.event.types.flagsChanged,
  }, function(event)
    if not windowMode then
      return false
    end

    local eventType = event:getType()
    if eventType == hs.eventtap.event.types.flagsChanged then
      WindowManager.modalFlags = event:getFlags()
      if hasOnlyModalEntryModifiers(WindowManager.modalFlags) then
        resetModalState()
        startModalTimer()
        showModalHome()
      end
      return true
    end

    if eventType == hs.eventtap.event.types.keyUp then
      return true
    end

    if eventType ~= hs.eventtap.event.types.keyDown then
      return true
    end

    local keyCode = event:getKeyCode()
    local keyName = hs.keycodes.map[keyCode]
    if not keyName then
      return true
    end

    local flags = WindowManager.modalFlags or event:getFlags()
    startModalTimer()

    if handleModalKey(keyName, flags) then
      return true
    end

    return true
  end)

  WindowManager.modalKeyGuard:start()
end

local function buildMenuItems()
  local modalHotkeyLabel = formatModalHotkeyLabel()
  local items = {
    { title = "Keyboard Mode: " .. modalHotkeyLabel, disabled = true },
    { title = "-" },
    { title = "Aspect Presets [A then 1-9]", disabled = true },
  }

  for index, preset in ipairs(CONFIG.aspectPresets) do
    table.insert(items, {
      title = string.format("%s [A %d]", preset.label, index),
      fn = function()
        applyAspectPreset(preset)
      end,
    })
  end

  table.insert(items, { title = "-" })
  table.insert(items, { title = "Width Presets [W then 1-9]", disabled = true })

  for index, width in ipairs(CONFIG.widthPresets) do
    table.insert(items, {
      title = string.format("%d px [W %d]", width, index),
      fn = function()
        applyWidthPreset(width)
      end,
    })
  end

  table.insert(items, { title = "-" })
  table.insert(items, { title = "Height Presets [H then 1-9]", disabled = true })

  for index, height in ipairs(CONFIG.heightPresets) do
    table.insert(items, {
      title = string.format("%d px [H %d]", height, index),
      fn = function()
        applyHeightPreset(height)
      end,
    })
  end

  table.insert(items, { title = "-" })
  table.insert(items, {
    title = "Move " .. CONFIG.moveStep .. " px [M then arrows / C / B]",
    disabled = true,
  })
  table.insert(items, {
    title = "Move Left [M " .. CONFIG.symbols.left .. "]",
    fn = function()
      moveByStep("left")
    end,
  })
  table.insert(items, {
    title = "Move Right [M " .. CONFIG.symbols.right .. "]",
    fn = function()
      moveByStep("right")
    end,
  })
  table.insert(items, {
    title = "Move Up [M " .. CONFIG.symbols.up .. "]",
    fn = function()
      moveByStep("up")
    end,
  })
  table.insert(items, {
    title = "Move Down [M " .. CONFIG.symbols.down .. "]",
    fn = function()
      moveByStep("down")
    end,
  })
  table.insert(items, {
    title = "Top Left [M " .. CONFIG.symbols.shift .. " + " .. CONFIG.symbols.left .. "]",
    fn = function()
      moveToCorner("topleft")
    end,
  })
  table.insert(items, {
    title = "Center Top [M C]",
    fn = function()
      moveToCorner("centertop")
    end,
  })
  table.insert(items, {
    title = "Top Right [M " .. CONFIG.symbols.shift .. " + " .. CONFIG.symbols.right .. "]",
    fn = function()
      moveToCorner("topright")
    end,
  })
  table.insert(items, {
    title = "Bottom Left [M B " .. CONFIG.symbols.left .. "]",
    fn = function()
      moveToCorner("bottomleft")
    end,
  })
  table.insert(items, {
    title = "Bottom Right [M B " .. CONFIG.symbols.right .. "]",
    fn = function()
      moveToCorner("bottomright")
    end,
  })

  table.insert(items, { title = "-" })
  table.insert(items, {
    title = "Resize "
      .. CONFIG.growStep
      .. " px [R then "
      .. CONFIG.symbols.left
      .. " "
      .. CONFIG.symbols.up
      .. " "
      .. CONFIG.symbols.right
      .. " "
      .. CONFIG.symbols.down
      .. " G S]",
    disabled = true,
  })
  table.insert(items, {
    title = "Grow Width [R " .. CONFIG.symbols.right .. "]",
    fn = function()
      growWindow(CONFIG.growStep, 0, "Grow width +" .. CONFIG.growStep .. " px")
    end,
  })
  table.insert(items, {
    title = "Grow Height [R " .. CONFIG.symbols.down .. "]",
    fn = function()
      growWindow(0, CONFIG.growStep, "Grow height +" .. CONFIG.growStep .. " px")
    end,
  })
  table.insert(items, {
    title = "Shrink Width [R " .. CONFIG.symbols.left .. "]",
    fn = function()
      shrinkWindow(CONFIG.growStep, 0, "Shrink width -" .. CONFIG.growStep .. " px")
    end,
  })
  table.insert(items, {
    title = "Shrink Height [R " .. CONFIG.symbols.up .. "]",
    fn = function()
      shrinkWindow(0, CONFIG.growStep, "Shrink height -" .. CONFIG.growStep .. " px")
    end,
  })
  table.insert(items, {
    title = "Grow Width + Height [R G]",
    fn = function()
      growWindow(CONFIG.growStep, CONFIG.growStep, "Grow size +" .. CONFIG.growStep .. " px")
    end,
  })
  table.insert(items, {
    title = "Shrink Width + Height [R S]",
    fn = function()
      shrinkWindow(CONFIG.growStep, CONFIG.growStep, "Shrink size -" .. CONFIG.growStep .. " px")
    end,
  })

  return items
end

menu:setTitle(CONFIG.menuTitle)
menu:setTooltip("Window management: " .. formatModalHotkeyLabel() .. " for keyboard mode")
menu:setMenu(buildMenuItems)

windowFilter:subscribe(hs.window.filter.windowFocused, function(win)
  local validWindow = getValidWindow(win)
  if validWindow then
    WindowManager.lastFocusedWindow = validWindow
  end
end)

WindowManager.windowMode = hs.hotkey.modal.new()
windowMode = WindowManager.windowMode

function windowMode:entered()
  resetModalState()
  WindowManager.modalFlags = {}
  startModalTimer()
  startModalKeyGuard()
  showModalHome()
end

function windowMode:exited()
  stopModalTimer()
  stopModalKeyGuard()
  closeModalOverlay()
  WindowManager.modalFlags = {}
  resetModalState()
end

windowMode:bind({}, "escape", function()
  windowMode:exit()
end)

windowMode:bind({}, "a", function()
  setModalGroup("aspect")
end)

windowMode:bind({}, "w", function()
  setModalGroup("width")
end)

windowMode:bind({}, "h", function()
  setModalGroup("height")
end)

windowMode:bind({}, "m", function()
  setModalGroup("move")
end)

windowMode:bind({}, "b", function()
  handleMoveSelection("b", false)
end)

windowMode:bind({}, "c", function()
  handleMoveSelection("c", false)
end)

windowMode:bind({}, "r", function()
  setModalGroup("resize")
end)

windowMode:bind({}, "g", function()
  handleResizeShortcut("grow_both")
end)

windowMode:bind({}, "s", function()
  handleResizeShortcut("shrink_both")
end)

for index = 1, 9 do
  windowMode:bind({}, tostring(index), function()
    handleNumberSelection(index)
  end)
end

windowMode:bind({}, "up", function()
  if modalState.group == "move" then
    handleMoveSelection("up", false)
  else
    handleSizeSelection("up")
  end
end)

windowMode:bind({}, "down", function()
  if modalState.group == "move" then
    handleMoveSelection("down", false)
  else
    handleSizeSelection("down")
  end
end)

windowMode:bind({}, "left", function()
  if modalState.group == "move" then
    handleMoveSelection("left", false)
  else
    handleSizeSelection("left")
  end
end)

windowMode:bind({ "shift" }, "left", function()
  handleMoveSelection("left", true)
end)

windowMode:bind({}, "right", function()
  if modalState.group == "move" then
    handleMoveSelection("right", false)
  else
    handleSizeSelection("right")
  end
end)

windowMode:bind({ "shift" }, "right", function()
  handleMoveSelection("right", true)
end)

WindowManager.entryHotkey = hs.hotkey.bind(CONFIG.modalHotkey.modifiers, CONFIG.modalHotkey.key, function()
  windowMode:enter()
end)
