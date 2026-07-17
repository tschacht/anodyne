local CONFIG = {
  menuTitle = "WI",
  alertDuration = 0.4,
  modalDuration = 8,
  symbols = {
    left = "←",
    up = "↑",
    right = "→",
    down = "↓",
    shift = "shift",
  },
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
  undoDepth = 3,
}

local undoDepth = tonumber(CONFIG.undoDepth)
if not undoDepth or undoDepth < 1 or undoDepth ~= math.floor(undoDepth) then
  error("CONFIG.undoDepth must be a positive integer")
end

local MODE_SELECTORS = {
  { key = "a", screen = "aspect", label = "Aspect" },
  { key = "w", screen = "width", label = "Width" },
  { key = "h", screen = "height", label = "Height" },
  { key = "m", screen = "move", label = "Move" },
  { key = "r", screen = "resize", label = "Resize" },
}

local MODE_BY_KEY = {}
for _, selector in ipairs(MODE_SELECTORS) do
  MODE_BY_KEY[selector.key] = selector.screen
end

local MOVE_STEP_ACTIONS = {
  { key = "left", direction = "left", label = "Move Left", symbol = CONFIG.symbols.left },
  { key = "right", direction = "right", label = "Move Right", symbol = CONFIG.symbols.right },
  { key = "up", direction = "up", label = "Move Up", symbol = CONFIG.symbols.up },
  { key = "down", direction = "down", label = "Move Down", symbol = CONFIG.symbols.down },
}

local CORNER_ACTIONS = {
  {
    key = "left",
    shifted = true,
    screen = "move",
    corner = "topleft",
    label = "Top Left",
    shortcut = CONFIG.symbols.shift .. " + " .. CONFIG.symbols.left,
  },
  { key = "c", screen = "move", corner = "centertop", label = "Center Top", shortcut = "C" },
  {
    key = "right",
    shifted = true,
    screen = "move",
    corner = "topright",
    label = "Top Right",
    shortcut = CONFIG.symbols.shift .. " + " .. CONFIG.symbols.right,
  },
  {
    key = "left",
    screen = "move_bottom",
    corner = "bottomleft",
    label = "Bottom Left",
    shortcut = CONFIG.symbols.left,
  },
  { key = "c", screen = "move_bottom", corner = "centerbottom", label = "Center Bottom", shortcut = "C" },
  {
    key = "right",
    screen = "move_bottom",
    corner = "bottomright",
    label = "Bottom Right",
    shortcut = CONFIG.symbols.right,
  },
}

local RESIZE_ACTIONS = {
  {
    key = "right",
    label = "Grow Width",
    prompt = "grow width",
    shortcut = CONFIG.symbols.right,
    deltaWidth = CONFIG.growStep,
    deltaHeight = 0,
  },
  {
    key = "down",
    label = "Grow Height",
    prompt = "grow height",
    shortcut = CONFIG.symbols.down,
    deltaWidth = 0,
    deltaHeight = CONFIG.growStep,
  },
  {
    key = "left",
    label = "Shrink Width",
    prompt = "shrink width",
    shortcut = CONFIG.symbols.left,
    deltaWidth = -CONFIG.growStep,
    deltaHeight = 0,
  },
  {
    key = "up",
    label = "Shrink Height",
    prompt = "shrink height",
    shortcut = CONFIG.symbols.up,
    deltaWidth = 0,
    deltaHeight = -CONFIG.growStep,
  },
  {
    key = "g",
    label = "Grow Width + Height",
    prompt = "grow width + height",
    shortcut = "G",
    deltaWidth = CONFIG.growStep,
    deltaHeight = CONFIG.growStep,
  },
  {
    key = "s",
    label = "Shrink Width + Height",
    prompt = "shrink width + height",
    shortcut = "S",
    deltaWidth = -CONFIG.growStep,
    deltaHeight = -CONFIG.growStep,
  },
}

local WindowManager = rawget(_G, "WindowManager") or {}
_G.WindowManager = WindowManager
local windowMode
WindowManager.modalState = WindowManager.modalState or {}
local modalState = WindowManager.modalState
modalState.active = false
modalState.screen = "home"
modalState.targetWindow = nil
modalState.sessionInitialFrame = nil
modalState.sessionInitialScreen = nil
WindowManager.frameHistory = {}
local frameHistory = WindowManager.frameHistory

local function deleteObject(object)
  if object and object.delete then
    pcall(function()
      object:delete()
    end)
  end
end

local function stopObject(object)
  if object and object.stop then
    pcall(function()
      object:stop()
    end)
  end
end

stopObject(WindowManager.modalTimer)
stopObject(WindowManager.modalRefreshTimer)
stopObject(WindowManager.modalKeyGuard)
deleteObject(WindowManager.entryHotkey)
deleteObject(WindowManager.windowMode)
deleteObject(WindowManager.modalTimer)
deleteObject(WindowManager.modalRefreshTimer)
deleteObject(WindowManager.modalCanvas)
deleteObject(WindowManager.modalKeyGuard)
deleteObject(WindowManager.menu)
if WindowManager.windowFilter then
  pcall(function()
    WindowManager.windowFilter:unsubscribeAll()
  end)
end
if WindowManager.historyWindowFilter then
  pcall(function()
    WindowManager.historyWindowFilter:unsubscribeAll()
  end)
end

WindowManager.menu = hs.menubar.new()
local menu = WindowManager.menu
if not menu then
  error("Failed to create menu bar item")
end

WindowManager.windowFilter = hs.window.filter.new()
local windowFilter = WindowManager.windowFilter
WindowManager.historyWindowFilter = hs.window.filter.new(true)
local historyWindowFilter = WindowManager.historyWindowFilter
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
  if modalState.active then
    local modalWindow = getValidWindow(modalState.targetWindow)
    if modalWindow then
      return modalWindow
    end

    alert("Modal target window is no longer available")
    return nil
  end

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

local function copyFrame(frame)
  return { x = frame.x, y = frame.y, w = frame.w, h = frame.h }
end

local function framesEqual(first, second)
  return round(first.x) == round(second.x) and round(first.y) == round(second.y) and round(first.w) == round(second.w) and round(first.h) == round(second.h)
end

local function screenSnapshot(screen)
  local identityOk, identity = pcall(function()
    return screen:getUUID() or tostring(screen:id())
  end)
  local frameOk, frame = pcall(function()
    return screen:fullFrame()
  end)
  if not identityOk or not identity or not frameOk or not frame then
    return nil
  end

  return { identity = identity, frame = copyFrame(frame) }
end

local function windowScreenSnapshot(win)
  local ok, screen = pcall(function()
    return win:screen()
  end)
  if not ok or not screen then
    return nil
  end
  return screenSnapshot(screen)
end

local function screenSnapshotIsCurrent(snapshot)
  if not snapshot then
    return false
  end

  for _, screen in ipairs(hs.screen.allScreens()) do
    local currentSnapshot = screenSnapshot(screen)
    if currentSnapshot and currentSnapshot.identity == snapshot.identity and framesEqual(currentSnapshot.frame, snapshot.frame) then
      return true
    end
  end
  return false
end

local function recordFrameHistory(windowId, beforeFrame, afterFrame, beforeScreen)
  local history = frameHistory[windowId] or {}

  if #history > 0 and not framesEqual(history[#history].after, beforeFrame) then
    history = {}
  end

  table.insert(history, {
    before = copyFrame(beforeFrame),
    after = copyFrame(afterFrame),
    beforeScreen = beforeScreen,
  })

  while #history > undoDepth do
    table.remove(history, 1)
  end

  frameHistory[windowId] = history
end

local function clampFrameToScreen(frame, screenFrame, options)
  local screenWidth = round(screenFrame.w)
  local screenHeight = round(screenFrame.h)
  local requestedMinimumWidth = options and options.allowBelowMinimum and 1 or CONFIG.minimumWidth
  local requestedMinimumHeight = options and options.allowBelowMinimum and 1 or CONFIG.minimumHeight
  local minimumWidth = math.min(requestedMinimumWidth, screenWidth)
  local minimumHeight = math.min(requestedMinimumHeight, screenHeight)
  local width = clamp(round(frame.w), minimumWidth, screenWidth)
  local height = clamp(round(frame.h), minimumHeight, screenHeight)
  local maxX = round(screenFrame.x + screenFrame.w - width)
  local maxY = round(screenFrame.y + screenFrame.h - height)

  return {
    x = clamp(round(frame.x), round(screenFrame.x), maxX),
    y = clamp(round(frame.y), round(screenFrame.y), maxY),
    w = width,
    h = height,
  }
end

local function actionFailure(message)
  if not modalState.active then
    alert(message)
  end
  return false, message
end

local function setFrameAndRead(win, frame)
  local setOk = pcall(function()
    -- An authoritative readback is required for transactional undo history.
    win:setFrame(frame, 0)
  end)
  if not setOk then
    return nil, "The window could not be changed", false
  end

  local frameOk, actualFrame = pcall(function()
    return win:frame()
  end)
  if not frameOk or not actualFrame then
    return nil, "The window frame could not be verified", true
  end

  return copyFrame(actualFrame), nil, false
end

local function setFrameExactly(win, targetFrame, currentFrame, frameDescription)
  local actualFrame, failureMessage, historyInvalidated = setFrameAndRead(win, targetFrame)
  if not actualFrame then
    return nil, failureMessage, historyInvalidated
  end
  if framesEqual(currentFrame, actualFrame) then
    return nil, "The window did not accept " .. frameDescription, false
  end
  if framesEqual(actualFrame, targetFrame) then
    return actualFrame, nil, false
  end

  local rollbackFrame = setFrameAndRead(win, currentFrame)
  if not rollbackFrame or not framesEqual(rollbackFrame, currentFrame) then
    return nil, "The window changed but could not restore " .. frameDescription .. " exactly", true
  end
  return nil, "The window could not restore " .. frameDescription .. " exactly", false
end

local function applyFrame(win, frame, label, options)
  local idOk, windowId = pcall(function()
    return win:id()
  end)
  if not idOk or not windowId then
    return actionFailure("The target window is no longer available")
  end

  local currentScreen = windowScreenSnapshot(win)
  if not currentScreen then
    return actionFailure("The window screen could not be verified")
  end

  local frameOk, currentFrame = pcall(function()
    return win:frame()
  end)
  if not frameOk or not currentFrame then
    return actionFailure("The target window is no longer available")
  end

  local targetFrame
  if options and options.clampToScreen == false then
    targetFrame = copyFrame(frame)
  else
    local screenFrameOk, screenFrame = pcall(function()
      return win:screen():frame()
    end)
    if not screenFrameOk or not screenFrame then
      return actionFailure("The window screen could not be verified")
    end
    targetFrame = clampFrameToScreen(frame, screenFrame, options)
  end
  local actualFrame = currentFrame

  if not framesEqual(currentFrame, targetFrame) then
    local failureMessage
    local historyInvalidated = false
    if options and options.requireExact then
      actualFrame, failureMessage, historyInvalidated = setFrameExactly(win, targetFrame, currentFrame, options.frameDescription or "the requested frame")
    else
      actualFrame, failureMessage, historyInvalidated = setFrameAndRead(win, targetFrame)
    end
    if historyInvalidated then
      frameHistory[windowId] = nil
    end
    if not actualFrame then
      return actionFailure(failureMessage)
    end
    if framesEqual(currentFrame, actualFrame) then
      return actionFailure("The window did not accept that change")
    end

    recordFrameHistory(windowId, currentFrame, actualFrame, currentScreen)
  end

  if options and options.showSize then
    alert(string.format("%s (%d x %d)", label, round(actualFrame.w), round(actualFrame.h)))
  else
    alert(label)
  end

  return true
end

local function resetSessionFrame()
  if not modalState.active or not modalState.sessionInitialFrame or not modalState.sessionInitialScreen then
    return actionFailure("No active window session to reset")
  end
  if not screenSnapshotIsCurrent(modalState.sessionInitialScreen) then
    return actionFailure("The screen configuration changed; session reset is unavailable")
  end

  local win = getFocusedWindow()
  if not win then
    return false
  end

  return applyFrame(win, copyFrame(modalState.sessionInitialFrame), "Reset session", {
    showSize = true,
    clampToScreen = false,
    requireExact = true,
    frameDescription = "the session frame",
  })
end

local function undoLastFrame()
  local win = getFocusedWindow()
  if not win then
    return false
  end

  local idOk, windowId = pcall(function()
    return win:id()
  end)
  if not idOk or not windowId then
    return actionFailure("The target window is no longer available")
  end

  local history = frameHistory[windowId]
  if not history or #history == 0 then
    return actionFailure("Nothing to undo for this window")
  end

  local entry = history[#history]
  local frameOk, currentFrame = pcall(function()
    return win:frame()
  end)
  if not frameOk or not currentFrame then
    frameHistory[windowId] = nil
    return actionFailure("The target window is no longer available")
  end
  if not framesEqual(currentFrame, entry.after) then
    frameHistory[windowId] = nil
    return actionFailure("Undo history was reset because the window changed outside WI")
  end

  if not screenSnapshotIsCurrent(entry.beforeScreen) then
    return actionFailure("The screen configuration changed; the previous frame is unavailable")
  end

  local restoredFrame = copyFrame(entry.before)
  if framesEqual(currentFrame, restoredFrame) then
    frameHistory[windowId] = nil
    return actionFailure("The previous window position is no longer available")
  end

  local actualFrame, failureMessage, historyInvalidated = setFrameExactly(win, restoredFrame, currentFrame, "the previous frame")
  if historyInvalidated then
    frameHistory[windowId] = nil
  end
  if not actualFrame then
    return actionFailure(failureMessage)
  end

  table.remove(history)
  if #history == 0 or not framesEqual(history[#history].after, actualFrame) then
    frameHistory[windowId] = nil
  end

  alert(string.format("Undo (%d x %d)", round(actualFrame.w), round(actualFrame.h)))
  return true
end

local function applyAspectPreset(preset)
  local win = getFocusedWindow()
  if not win then
    return false
  end

  local currentFrame = win:frame()
  local screenFrame = win:screen():frame()
  local ratio = preset.width / preset.height
  local minimumWidthForRatio = math.max(CONFIG.minimumWidth, CONFIG.minimumHeight * ratio)
  local maximumWidthForRatio = math.min(screenFrame.w, screenFrame.h * ratio)
  local targetWidth

  if maximumWidthForRatio < minimumWidthForRatio then
    targetWidth = maximumWidthForRatio
  else
    targetWidth = clamp(currentFrame.w, minimumWidthForRatio, maximumWidthForRatio)
  end
  local targetHeight = targetWidth / ratio

  return applyFrame(win, {
    x = currentFrame.x,
    y = currentFrame.y,
    w = targetWidth,
    h = targetHeight,
  }, "Aspect " .. preset.label, { showSize = true, allowBelowMinimum = true })
end

local function applyWidthPreset(width)
  local win = getFocusedWindow()
  if not win then
    return false
  end

  local currentFrame = win:frame()

  return applyFrame(win, {
    x = currentFrame.x,
    y = currentFrame.y,
    w = width,
    h = currentFrame.h,
  }, string.format("Width %d px", width), { showSize = true })
end

local function applyHeightPreset(height)
  local win = getFocusedWindow()
  if not win then
    return false
  end

  local currentFrame = win:frame()

  return applyFrame(win, {
    x = currentFrame.x,
    y = currentFrame.y,
    w = currentFrame.w,
    h = height,
  }, string.format("Height %d px", height), { showSize = true })
end

local function moveToCorner(corner)
  local win = getFocusedWindow()
  if not win then
    return false
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
  elseif corner == "centerbottom" then
    targetFrame.x = screenFrame.x + (screenFrame.w - currentFrame.w) / 2
    targetFrame.y = screenFrame.y + screenFrame.h - currentFrame.h
  elseif corner == "bottomright" then
    targetFrame.x = screenFrame.x + screenFrame.w - currentFrame.w
    targetFrame.y = screenFrame.y + screenFrame.h - currentFrame.h
  else
    alert("Unknown corner: " .. tostring(corner))
    return false
  end

  return applyFrame(win, targetFrame, "Move " .. corner)
end

local function growWindow(deltaWidth, deltaHeight, label)
  local win = getFocusedWindow()
  if not win then
    return false
  end

  local currentFrame = win:frame()

  return applyFrame(win, {
    x = currentFrame.x,
    y = currentFrame.y,
    w = currentFrame.w + deltaWidth,
    h = currentFrame.h + deltaHeight,
  }, label, { showSize = true })
end

local function shrinkWindow(deltaWidth, deltaHeight, label)
  local win = getFocusedWindow()
  if not win then
    return false
  end

  local currentFrame = win:frame()

  return applyFrame(win, {
    x = currentFrame.x,
    y = currentFrame.y,
    w = currentFrame.w - deltaWidth,
    h = currentFrame.h - deltaHeight,
  }, label, { showSize = true })
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

local function stopModalRefreshTimer()
  if WindowManager.modalRefreshTimer then
    pcall(function()
      WindowManager.modalRefreshTimer:stop()
    end)
    WindowManager.modalRefreshTimer = nil
  end
end

local function getModalHomeWindow()
  if modalState.active then
    return getValidWindow(modalState.targetWindow)
  end

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

local function formatPresetOptions(presets, labelFn)
  local labels = {}

  for index, preset in ipairs(presets) do
    table.insert(labels, string.format("%d = %s", index, labelFn(preset)))
  end

  return table.concat(labels, "\n")
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
    return false
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
    return false
  end

  return applyFrame(win, targetFrame, string.format("Move %s %d px", direction, CONFIG.moveStep))
end

local SCREEN_TITLES = {
  home = "Window mode",
  aspect = "Aspect preset",
  width = "Width preset",
  height = "Height preset",
  move = "Move",
  move_bottom = "Move bottom positions",
  resize = "Resize",
}

local function appendLines(target, source)
  for _, line in ipairs(source) do
    table.insert(target, line)
  end
end

local function formatNavigationLine()
  local labels = {}
  for _, selector in ipairs(MODE_SELECTORS) do
    table.insert(labels, string.upper(selector.key) .. " " .. selector.label)
  end
  return "Modes: " .. table.concat(labels, " · ")
end

local function appendModeNavigationLines(lines)
  table.insert(lines, "Modes:")
  for _, selector in ipairs(MODE_SELECTORS) do
    table.insert(lines, string.upper(selector.key) .. " = " .. selector.label)
  end
end

local function formatNavigationControlLine()
  return "Navigation: ⌫ = back/home · Esc = exit"
end

local function formatUndoLine()
  return "U = undo last action"
end

local function formatSessionResetLine()
  return "Shift+U = reset session"
end

local function buildModalLines(status)
  local screen = modalState.screen or "home"
  local lines = { (SCREEN_TITLES[screen] or "Window mode") .. ":", formatCurrentWindowSize(), "" }

  if screen == "home" then
    table.insert(lines, "Choose a mode with A, W, H, M, or R")
  elseif screen == "aspect" then
    appendLines(
      lines,
      hs.fnutils.split(
        formatPresetOptions(CONFIG.aspectPresets, function(preset)
          return preset.label
        end),
        "\n"
      )
    )
  elseif screen == "width" then
    appendLines(
      lines,
      hs.fnutils.split(
        formatPresetOptions(CONFIG.widthPresets, function(width)
          return tostring(width) .. " px"
        end),
        "\n"
      )
    )
  elseif screen == "height" then
    appendLines(
      lines,
      hs.fnutils.split(
        formatPresetOptions(CONFIG.heightPresets, function(height)
          return tostring(height) .. " px"
        end),
        "\n"
      )
    )
  elseif screen == "move" then
    for _, action in ipairs(MOVE_STEP_ACTIONS) do
      table.insert(lines, string.format("%s = %s %d px", action.symbol, string.lower(action.label), CONFIG.moveStep))
    end
    for _, action in ipairs(CORNER_ACTIONS) do
      if action.screen == "move" then
        table.insert(lines, action.shortcut .. " = " .. string.lower(action.label))
      end
    end
    table.insert(lines, "B = bottom positions")
  elseif screen == "move_bottom" then
    for _, action in ipairs(CORNER_ACTIONS) do
      if action.screen == "move_bottom" then
        table.insert(lines, action.shortcut .. " = " .. string.lower(action.label))
      end
    end
    table.insert(lines, "B or ⌫ = back to Move")
  elseif screen == "resize" then
    for _, action in ipairs(RESIZE_ACTIONS) do
      table.insert(lines, action.shortcut .. " = " .. action.prompt .. " " .. CONFIG.growStep .. " px")
    end
  end

  table.insert(lines, "")
  appendModeNavigationLines(lines)
  table.insert(lines, formatUndoLine())
  table.insert(lines, formatSessionResetLine())
  table.insert(lines, formatNavigationControlLine())

  if status then
    table.insert(lines, "")
    table.insert(lines, "Status: " .. status)
  end

  return lines
end

local function renderModal(status)
  modalAlert(table.concat(buildModalLines(status), "\n"))
end

local function transitionTo(screen)
  stopModalRefreshTimer()
  if not SCREEN_TITLES[screen] then
    renderModal("Unknown mode " .. tostring(screen))
    return
  end

  modalState.screen = screen
  renderModal()
end

local function completeModalAction(success, failureMessage)
  if success then
    stopModalRefreshTimer()
    WindowManager.modalRefreshTimer = hs.timer.doAfter(0.05, function()
      WindowManager.modalRefreshTimer = nil
      if modalState.active then
        renderModal()
      end
    end)
  else
    renderModal(failureMessage or "The target window is no longer available")
  end
end

local function runMenuAction(actionFn)
  if modalState.active then
    stopModalRefreshTimer()
    startModalTimer()
  end

  local success, failureMessage = actionFn()
  if modalState.active then
    completeModalAction(success, failureMessage)
  end
end

local function isArrowKey(keyName)
  return keyName == "left" or keyName == "right" or keyName == "up" or keyName == "down"
end

local function hasNoCommandModifiers(keyName, flags)
  return not flags.cmd and not flags.alt and not flags.ctrl and not flags.shift and (isArrowKey(keyName) or not flags.fn)
end

local function hasOnlyShift(keyName, flags)
  return flags.shift == true and not flags.cmd and not flags.alt and not flags.ctrl and (isArrowKey(keyName) or not flags.fn)
end

local function findCornerAction(screen, keyName, shifted)
  for _, action in ipairs(CORNER_ACTIONS) do
    local actionShifted = action.shifted == true
    if action.screen == screen and action.key == keyName and actionShifted == shifted then
      return action
    end
  end
  return nil
end

local function findMoveStepAction(keyName)
  for _, action in ipairs(MOVE_STEP_ACTIONS) do
    if action.key == keyName then
      return action
    end
  end
  return nil
end

local function findResizeAction(keyName)
  for _, action in ipairs(RESIZE_ACTIONS) do
    if action.key == keyName then
      return action
    end
  end
  return nil
end

local function applyResizeAction(action)
  local magnitude = math.max(math.abs(action.deltaWidth), math.abs(action.deltaHeight))
  local sign = action.deltaWidth < 0 or action.deltaHeight < 0
  local label = string.format("%s %s%d px", action.label, sign and "-" or "+", magnitude)

  if sign then
    return shrinkWindow(math.abs(action.deltaWidth), math.abs(action.deltaHeight), label)
  end
  return growWindow(action.deltaWidth, action.deltaHeight, label)
end

local function handlePresetSelection(index)
  local screen = modalState.screen
  local preset
  local applyFn

  if screen == "aspect" then
    preset = CONFIG.aspectPresets[index]
    applyFn = applyAspectPreset
  elseif screen == "width" then
    preset = CONFIG.widthPresets[index]
    applyFn = applyWidthPreset
  elseif screen == "height" then
    preset = CONFIG.heightPresets[index]
    applyFn = applyHeightPreset
  end

  if not applyFn then
    renderModal("Number keys are not available in " .. (SCREEN_TITLES[screen] or "this mode"))
  elseif not preset then
    renderModal(string.format("No %s preset %d", string.lower(SCREEN_TITLES[screen]), index))
  else
    completeModalAction(applyFn(preset))
  end
end

local function formatKeyName(keyName, flags)
  local label = keyName
  if keyName == "delete" then
    label = "Backspace"
  elseif #keyName == 1 then
    label = string.upper(keyName)
  end
  local modifiers = {}
  if flags.ctrl then
    table.insert(modifiers, "Ctrl")
  end
  if flags.alt then
    table.insert(modifiers, "Alt")
  end
  if flags.cmd then
    table.insert(modifiers, "Cmd")
  end
  if flags.shift then
    table.insert(modifiers, "Shift")
  end
  if flags.fn and not isArrowKey(keyName) then
    table.insert(modifiers, "Fn")
  end
  if #modifiers > 0 then
    label = table.concat(modifiers, "+") .. "+" .. label
  end
  return label
end

local function handleModalKey(keyName, flags)
  stopModalRefreshTimer()
  local plain = hasNoCommandModifiers(keyName, flags)
  local shifted = hasOnlyShift(keyName, flags)

  if plain and keyName == "escape" then
    windowMode:exit()
    return
  end

  if plain and keyName == "u" then
    local success, failureMessage = undoLastFrame()
    completeModalAction(success, failureMessage)
    return
  end

  if shifted and keyName == "u" then
    local success, failureMessage = resetSessionFrame()
    completeModalAction(success, failureMessage)
    return
  end

  if plain and MODE_BY_KEY[keyName] then
    transitionTo(MODE_BY_KEY[keyName])
    return
  end

  if plain and keyName == "delete" then
    if modalState.screen == "move_bottom" then
      transitionTo("move")
    elseif modalState.screen ~= "home" then
      transitionTo("home")
    else
      renderModal("Already at Home")
    end
    return
  end

  local screen = modalState.screen or "home"
  local number = plain and tonumber(keyName) or nil
  if number then
    handlePresetSelection(number)
    return
  end

  if screen == "move" then
    if plain and keyName == "b" then
      transitionTo("move_bottom")
      return
    end

    local cornerAction = findCornerAction(screen, keyName, shifted)
    if cornerAction and (plain or shifted) then
      completeModalAction(moveToCorner(cornerAction.corner))
      return
    end

    local stepAction = plain and findMoveStepAction(keyName) or nil
    if stepAction then
      completeModalAction(moveByStep(stepAction.direction))
      return
    end
  elseif screen == "move_bottom" then
    if plain and keyName == "b" then
      transitionTo("move")
      return
    end

    local cornerAction = plain and findCornerAction(screen, keyName, false) or nil
    if cornerAction then
      local success, failureMessage = moveToCorner(cornerAction.corner)
      if success then
        transitionTo("move")
      else
        completeModalAction(false, failureMessage)
      end
      return
    end
  elseif screen == "resize" and plain then
    local resizeAction = findResizeAction(keyName)
    if resizeAction then
      completeModalAction(applyResizeAction(resizeAction))
      return
    end
  end

  renderModal(string.format("%s is not available in %s", formatKeyName(keyName, flags), SCREEN_TITLES[screen]))
end

local function startModalKeyGuard()
  stopModalKeyGuard()

  WindowManager.modalKeyGuard = hs.eventtap.new({
    hs.eventtap.event.types.keyDown,
    hs.eventtap.event.types.keyUp,
    hs.eventtap.event.types.flagsChanged,
  }, function(event)
    if not windowMode or not modalState.active then
      return false
    end

    local eventType = event:getType()
    if eventType == hs.eventtap.event.types.flagsChanged then
      return false
    end

    if eventType == hs.eventtap.event.types.keyUp then
      return true
    end

    if eventType ~= hs.eventtap.event.types.keyDown then
      return true
    end

    startModalTimer()
    local keyCode = event:getKeyCode()
    local keyName = hs.keycodes.map[keyCode]
    if not keyName then
      renderModal("Unrecognized key")
      return true
    end

    local flags = event:getFlags()
    handleModalKey(keyName, flags)
    return true
  end)

  WindowManager.modalKeyGuard:start()
end

local function buildMenuItems()
  local modalHotkeyLabel = formatModalHotkeyLabel()
  local sessionSnapshotAvailable = modalState.active and modalState.sessionInitialFrame and modalState.sessionInitialScreen
  local sessionScreenChanged = sessionSnapshotAvailable and not screenSnapshotIsCurrent(modalState.sessionInitialScreen)
  local sessionResetAvailable = sessionSnapshotAvailable and not sessionScreenChanged
  local sessionResetTitle = "Reset Session [Shift+U]"
  if sessionScreenChanged then
    sessionResetTitle = sessionResetTitle .. " (screen configuration changed)"
  end
  local items = {
    { title = "Keyboard Mode: " .. modalHotkeyLabel, disabled = true },
    { title = formatNavigationLine(), disabled = true },
    { title = formatNavigationControlLine(), disabled = true },
    {
      title = "Undo Last Action [U]",
      fn = function()
        runMenuAction(undoLastFrame)
      end,
    },
    {
      title = sessionResetTitle,
      disabled = not sessionResetAvailable,
      fn = function()
        runMenuAction(resetSessionFrame)
      end,
    },
    { title = "-" },
    { title = string.format("Aspect Presets [A then 1-%d]", #CONFIG.aspectPresets), disabled = true },
  }

  for index, preset in ipairs(CONFIG.aspectPresets) do
    table.insert(items, {
      title = string.format("%s [A %d]", preset.label, index),
      fn = function()
        runMenuAction(function()
          return applyAspectPreset(preset)
        end)
      end,
    })
  end

  table.insert(items, { title = "-" })
  table.insert(items, {
    title = string.format("Width Presets [W then 1-%d]", #CONFIG.widthPresets),
    disabled = true,
  })

  for index, width in ipairs(CONFIG.widthPresets) do
    table.insert(items, {
      title = string.format("%d px [W %d]", width, index),
      fn = function()
        runMenuAction(function()
          return applyWidthPreset(width)
        end)
      end,
    })
  end

  table.insert(items, { title = "-" })
  table.insert(items, {
    title = string.format("Height Presets [H then 1-%d]", #CONFIG.heightPresets),
    disabled = true,
  })

  for index, height in ipairs(CONFIG.heightPresets) do
    table.insert(items, {
      title = string.format("%d px [H %d]", height, index),
      fn = function()
        runMenuAction(function()
          return applyHeightPreset(height)
        end)
      end,
    })
  end

  table.insert(items, { title = "-" })
  table.insert(items, {
    title = "Move " .. CONFIG.moveStep .. " px [M then arrows / C / B]",
    disabled = true,
  })

  for _, action in ipairs(MOVE_STEP_ACTIONS) do
    table.insert(items, {
      title = string.format("%s [M %s]", action.label, action.symbol),
      fn = function()
        runMenuAction(function()
          return moveByStep(action.direction)
        end)
      end,
    })
  end

  for _, action in ipairs(CORNER_ACTIONS) do
    local shortcut = action.screen == "move_bottom" and "M B " .. action.shortcut or "M " .. action.shortcut
    table.insert(items, {
      title = string.format("%s [%s]", action.label, shortcut),
      fn = function()
        runMenuAction(function()
          return moveToCorner(action.corner)
        end)
      end,
    })
  end

  table.insert(items, { title = "-" })
  table.insert(items, {
    title = "Resize " .. CONFIG.growStep .. " px [R then arrows / G / S]",
    disabled = true,
  })

  for _, action in ipairs(RESIZE_ACTIONS) do
    table.insert(items, {
      title = string.format("%s [R %s]", action.label, action.shortcut),
      fn = function()
        runMenuAction(function()
          return applyResizeAction(action)
        end)
      end,
    })
  end

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

historyWindowFilter:subscribe(hs.window.filter.windowDestroyed, function(win)
  local ok, windowId = pcall(function()
    return win:id()
  end)
  if ok and windowId then
    frameHistory[windowId] = nil
  end
end)

WindowManager.windowMode = hs.hotkey.modal.new()
windowMode = WindowManager.windowMode

function windowMode:entered()
  local targetWindow = getModalHomeWindow()
  local frameOk, initialFrame = pcall(function()
    return targetWindow and copyFrame(targetWindow:frame()) or nil
  end)
  modalState.active = true
  modalState.screen = "home"
  modalState.targetWindow = targetWindow
  modalState.sessionInitialFrame = frameOk and initialFrame or nil
  modalState.sessionInitialScreen = targetWindow and windowScreenSnapshot(targetWindow) or nil
  startModalTimer()
  startModalKeyGuard()
  renderModal()
end

function windowMode:exited()
  stopModalTimer()
  stopModalRefreshTimer()
  stopModalKeyGuard()
  closeModalOverlay()
  modalState.active = false
  modalState.screen = "home"
  modalState.targetWindow = nil
  modalState.sessionInitialFrame = nil
  modalState.sessionInitialScreen = nil
end

WindowManager.entryHotkey = hs.hotkey.bind(CONFIG.modalHotkey.modifiers, CONFIG.modalHotkey.key, function()
  windowMode:enter()
end)
