local Anodyne = {}

local DefaultConfig = require("Anodyne.config")
local DefaultGeometry = require("Anodyne.core.geometry")

local function validateOptions(kind, options, allowed)
  if type(options) ~= "table" then
    error(kind .. " options must be a table", 3)
  end
  for key in pairs(options) do
    if not allowed[key] then
      error("unknown " .. kind .. " option: " .. tostring(key), 3)
    end
  end
  if type(options.hs) ~= "table" then
    error(kind .. ".hs must be a table", 3)
  end
  if options.config ~= nil and type(options.config) ~= "table" then
    error(kind .. ".config must be a table", 3)
  end
end

local function startRuntime(WindowManager, hs, CONFIG, generation, geometry, metadata)
  local function currentGeneration()
    return generation.current()
  end

  local undoDepth = CONFIG.undoDepth

  local round = geometry.round
  local clamp = geometry.clamp
  local copyFrame = geometry.copyFrame
  local framesEqual = geometry.framesEqual
  local MODE_SELECTORS = metadata.modeSelectors
  local MODE_BY_KEY = metadata.modeByKey
  local MOVE_STEP_ACTIONS = metadata.moveStepActions
  local CORNER_ACTIONS = metadata.cornerActions
  local CORNER_LABEL_BY_NAME = metadata.cornerLabelByName
  local RESIZE_ACTIONS = metadata.resizeActions

  local windowMode
  WindowManager.modalState = {}
  local modalState = WindowManager.modalState
  modalState.active = false
  modalState.screen = "home"
  modalState.targetWindow = nil
  modalState.sessionInitialFrame = nil
  modalState.sessionInitialScreen = nil
  WindowManager.frameHistory = {}
  local frameHistory = WindowManager.frameHistory

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

  local function stopMenuFailureTimer()
    if WindowManager.menuFailureTimer then
      pcall(function()
        WindowManager.menuFailureTimer:stop()
      end)
      WindowManager.menuFailureTimer = nil
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
    stopMenuFailureTimer()
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

  local function showMenuFailure(message)
    modalAlert("WI action failed\n" .. (message or "The action could not be completed"))

    local timer
    timer = hs.timer.doAfter(CONFIG.menuFailureDuration, function()
      if not currentGeneration() then
        return
      end
      if WindowManager.menuFailureTimer ~= timer then
        return
      end

      WindowManager.menuFailureTimer = nil
      if not modalState.active then
        closeModalOverlay()
      end
    end)
    WindowManager.menuFailureTimer = timer
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

      return nil, "Modal target window is no longer available"
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
      return nil, "No focused window"
    end

    WindowManager.lastFocusedWindow = win
    return win
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

  local function actionFailure(message)
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
      targetFrame = geometry.clampFrameToScreen(frame, screenFrame, CONFIG.minimumWidth, CONFIG.minimumHeight, options and options.allowBelowMinimum)
    end
    local actualFrame = currentFrame
    local changed = false

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
      changed = true
    end

    local statusMessage
    if options and options.showSize then
      statusMessage = string.format("%s (%d x %d)", label, round(actualFrame.w), round(actualFrame.h))
    else
      statusMessage = label
    end
    if not changed then
      statusMessage = "No change — " .. statusMessage
    end

    return true, nil, statusMessage
  end

  local function resetSessionFrame()
    if not modalState.active or not modalState.sessionInitialFrame or not modalState.sessionInitialScreen then
      return actionFailure("No active window session to reset")
    end
    if not screenSnapshotIsCurrent(modalState.sessionInitialScreen) then
      return actionFailure("The screen configuration changed; session reset is unavailable")
    end

    local win, failureMessage = getFocusedWindow()
    if not win then
      return actionFailure(failureMessage)
    end

    return applyFrame(win, copyFrame(modalState.sessionInitialFrame), "Reset session", {
      showSize = true,
      clampToScreen = false,
      requireExact = true,
      frameDescription = "the session frame",
    })
  end

  local function undoLastFrame()
    local win, focusFailureMessage = getFocusedWindow()
    if not win then
      return actionFailure(focusFailureMessage)
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

    return true, nil, string.format("Undid last action (%d x %d)", round(actualFrame.w), round(actualFrame.h))
  end

  local function applyAspectPreset(preset)
    local win, failureMessage = getFocusedWindow()
    if not win then
      return actionFailure(failureMessage)
    end

    local currentFrame = win:frame()
    local screenFrame = win:screen():frame()
    local target = geometry.aspectTarget(currentFrame, screenFrame, preset, CONFIG.minimumWidth, CONFIG.minimumHeight)
    return applyFrame(win, target, "Aspect " .. preset.label, { showSize = true, allowBelowMinimum = true })
  end

  local function applyWidthPreset(width)
    local win, failureMessage = getFocusedWindow()
    if not win then
      return actionFailure(failureMessage)
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
    local win, failureMessage = getFocusedWindow()
    if not win then
      return actionFailure(failureMessage)
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
    local win, failureMessage = getFocusedWindow()
    if not win then
      return actionFailure(failureMessage)
    end

    local currentFrame = win:frame()
    local screenFrame = win:screen():frame()
    local targetFrame = geometry.cornerTarget(currentFrame, screenFrame, corner)
    if not targetFrame then
      return actionFailure("Unknown corner: " .. tostring(corner))
    end

    return applyFrame(win, targetFrame, "Move to " .. string.lower(CORNER_LABEL_BY_NAME[corner] or corner))
  end

  local function growWindow(deltaWidth, deltaHeight, label)
    local win, failureMessage = getFocusedWindow()
    if not win then
      return actionFailure(failureMessage)
    end

    local currentFrame = win:frame()

    return applyFrame(win, geometry.resizeTarget(currentFrame, deltaWidth, deltaHeight), label, { showSize = true })
  end

  local function shrinkWindow(deltaWidth, deltaHeight, label)
    local win, failureMessage = getFocusedWindow()
    if not win then
      return actionFailure(failureMessage)
    end

    local currentFrame = win:frame()

    return applyFrame(win, geometry.resizeTarget(currentFrame, -deltaWidth, -deltaHeight), label, { showSize = true })
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
      if not currentGeneration() then
        return
      end
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

  local function moveByStep(direction)
    local win, failureMessage = getFocusedWindow()
    if not win then
      return actionFailure(failureMessage)
    end

    local currentFrame = win:frame()
    local screenFrame = win:screen():frame()
    local targetFrame = geometry.stepTarget(currentFrame, screenFrame, CONFIG.moveStep, direction)
    if not targetFrame then
      return actionFailure("Unknown move direction: " .. tostring(direction))
    end

    return applyFrame(win, targetFrame, string.format("Move %s %d px", direction, CONFIG.moveStep))
  end

  local SCREEN_TITLES = metadata.screenTitles

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

  local function transitionTo(screen, status)
    stopModalRefreshTimer()
    if not SCREEN_TITLES[screen] then
      renderModal("Unknown mode " .. tostring(screen))
      return
    end

    modalState.screen = screen
    renderModal(status)
  end

  local function completeModalAction(success, failureMessage, successMessage)
    if success then
      stopModalRefreshTimer()
      WindowManager.modalRefreshTimer = hs.timer.doAfter(0.05, function()
        if not currentGeneration() then
          return
        end
        WindowManager.modalRefreshTimer = nil
        if modalState.active then
          renderModal(successMessage)
        end
      end)
    else
      renderModal(failureMessage or "The target window is no longer available")
    end
  end

  local function runMenuAction(actionFn)
    if not currentGeneration() then
      return
    end
    if modalState.active then
      stopModalRefreshTimer()
      startModalTimer()
    else
      stopMenuFailureTimer()
      closeModalOverlay()
    end

    local success, failureMessage, successMessage = actionFn()
    if modalState.active then
      completeModalAction(success, failureMessage, successMessage)
    elseif not success then
      showMenuFailure(failureMessage)
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
      completeModalAction(undoLastFrame())
      return
    end

    if shifted and keyName == "u" then
      completeModalAction(resetSessionFrame())
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
        local success, failureMessage, successMessage = moveToCorner(cornerAction.corner)
        if success then
          transitionTo("move", successMessage)
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
      if not currentGeneration() then
        return false
      end
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
    if not currentGeneration() then
      return
    end
    local validWindow = getValidWindow(win)
    if validWindow then
      WindowManager.lastFocusedWindow = validWindow
    end
  end)

  historyWindowFilter:subscribe(hs.window.filter.windowDestroyed, function(win)
    if not currentGeneration() then
      return
    end
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
    if not currentGeneration() then
      return
    end
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
    if not currentGeneration() then
      return
    end
    stopModalTimer()
    stopModalRefreshTimer()
    stopMenuFailureTimer()
    stopModalKeyGuard()
    closeModalOverlay()
    modalState.active = false
    modalState.screen = "home"
    modalState.targetWindow = nil
    modalState.sessionInitialFrame = nil
    modalState.sessionInitialScreen = nil
  end

  WindowManager.entryHotkey = hs.hotkey.bind(CONFIG.modalHotkey.modifiers, CONFIG.modalHotkey.key, function()
    if currentGeneration() then
      windowMode:enter()
    end
  end)
end

local private = setmetatable({}, { __mode = "k" })
local Instance = {}
Instance.__index = Instance

local cleanupStages = {
  { "modalTimer", "stop" },
  { "modalRefreshTimer", "stop" },
  { "menuFailureTimer", "stop" },
  { "modalKeyGuard", "stop" },
  { "entryHotkey", "delete" },
  { "windowMode", "delete" },
  { "modalTimer", "delete" },
  { "modalRefreshTimer", "delete" },
  { "menuFailureTimer", "delete" },
  { "modalCanvas", "delete" },
  { "modalKeyGuard", "delete" },
  { "menu", "delete" },
  { "windowFilter", "unsubscribeAll" },
  { "historyWindowFilter", "unsubscribeAll" },
}

local function appendError(errors, context, value)
  errors[#errors + 1] = context .. ": " .. tostring(value)
end

local function cleanupFields(owner, progress)
  local errors = {}
  for _, stage in ipairs(cleanupStages) do
    local field, method = stage[1], stage[2]
    local record = progress[field]
    local object = record and record.object or rawget(owner, field)
    if object then
      if not record or record.object ~= object then
        record = { object = object, done = {} }
        progress[field] = record
      end
      if method == "stop" and record.done.delete then
        record.done.stop = true
      end
      if not record.done[method] then
        local memberOk, member = pcall(function()
          return object[method]
        end)
        if not memberOk then
          appendError(errors, field .. "." .. method, member)
        elseif type(member) ~= "function" then
          appendError(errors, field .. "." .. method, "missing method")
        else
          local ok, result = pcall(member, object)
          if ok then
            record.done[method] = true
          else
            appendError(errors, field .. "." .. method, result)
          end
        end
      end
      local needsStop = field == "modalTimer" or field == "modalRefreshTimer" or field == "menuFailureTimer" or field == "modalKeyGuard"
      local needsDelete = field ~= "windowFilter" and field ~= "historyWindowFilter"
      local complete = (not needsStop or record.done.stop) and (not needsDelete or record.done.delete) and (needsDelete or record.done.unsubscribeAll)
      if complete then
        if rawget(owner, field) == object then
          rawset(owner, field, nil)
        end
        progress[field] = nil
      end
    end
  end
  if #errors == 0 then
    return nil
  end
  return errors
end

local function aggregate(label, errors)
  return label .. " failed:\n- " .. table.concat(errors, "\n- ")
end

function Instance:isRunning()
  local data = assert(private[self], "invalid Anodyne instance")
  return data.state ~= "stopped"
end

function Instance:start()
  local data = assert(private[self], "invalid Anodyne instance")
  if data.state == "running" then
    return self
  end
  if data.state == "faulted" then
    error("Anodyne instance is faulted; call stop() until cleanup succeeds", 2)
  end
  if data.state ~= "stopped" then
    error("Anodyne instance cannot start while " .. data.state, 2)
  end

  data.generation = data.generation + 1
  local token = data.generation
  data.state = "starting"
  local ok, startupError = pcall(data.runtimeFactory, self, data.hs, data.config, {
    current = function()
      return data.generation == token
    end,
  }, data.geometry, data.metadata)
  if ok then
    data.state = "running"
    return self
  end

  local _, cleanupErrors = self:stop()
  local errors = { tostring(startupError) }
  for _, value in ipairs(cleanupErrors or {}) do
    errors[#errors + 1] = value
  end
  error(aggregate("Anodyne startup", errors), 2)
end

function Instance:stop()
  local data = assert(private[self], "invalid Anodyne instance")
  if data.state == "stopped" then
    return self, nil
  end
  data.generation = data.generation + 1
  data.state = "stopping"
  local errors = cleanupFields(self, data.cleanup)
  if errors then
    data.state = "faulted"
    return self, errors
  end
  data.state = "stopped"
  return self, nil
end

function Anodyne.new(options)
  validateOptions("new", options, { hs = true, config = true, modules = true })
  if options.modules ~= nil and type(options.modules) ~= "table" then
    error("new.modules must be a table", 2)
  end
  local runtimeFactory = startRuntime
  local configModule = DefaultConfig
  local geometryModule = DefaultGeometry
  if options.modules then
    for key in pairs(options.modules) do
      if key ~= "runtimeFactory" and key ~= "config" and key ~= "geometry" then
        error("unknown new.modules key: " .. tostring(key), 2)
      end
    end
    if options.modules.runtimeFactory ~= nil and type(options.modules.runtimeFactory) ~= "function" then
      error("new.modules.runtimeFactory must be a function", 2)
    end
    runtimeFactory = options.modules.runtimeFactory or runtimeFactory
    if options.modules.config ~= nil then
      configModule = options.modules.config
    end
    if options.modules.geometry ~= nil then
      geometryModule = options.modules.geometry
    end
  end
  if type(configModule) ~= "table" then
    error("new.modules.config must be a table", 2)
  end
  if type(configModule.build) ~= "function" then
    error("new.modules.config.build must be a function", 2)
  end
  for key in pairs(configModule) do
    if key ~= "build" then
      error("unknown new.modules.config key: " .. tostring(key), 2)
    end
  end
  local geometryFunctions = {
    "round",
    "clamp",
    "copyFrame",
    "framesEqual",
    "clampFrameToScreen",
    "aspectTarget",
    "cornerTarget",
    "resizeTarget",
    "snapPosition",
    "stepTarget",
  }
  if type(geometryModule) ~= "table" then
    error("new.modules.geometry must be a table", 2)
  end
  local geometry = {}
  local expectedGeometry = {}
  for _, name in ipairs(geometryFunctions) do
    expectedGeometry[name] = true
    if type(geometryModule[name]) ~= "function" then
      error("new.modules.geometry." .. name .. " must be a function", 2)
    end
    geometry[name] = geometryModule[name]
  end
  for key in pairs(geometryModule) do
    if not expectedGeometry[key] then
      error("unknown new.modules.geometry key: " .. tostring(key), 2)
    end
  end
  local config, metadata = configModule.build(options.config)
  if type(config) ~= "table" or type(metadata) ~= "table" then
    error("new.modules.config.build must return config and metadata tables", 2)
  end
  local instance = setmetatable({ config = config }, Instance)
  private[instance] = {
    hs = options.hs,
    config = instance.config,
    geometry = geometry,
    metadata = metadata,
    runtimeFactory = runtimeFactory,
    state = "stopped",
    generation = 0,
    cleanup = {},
  }
  return instance
end

local function validatePrevious(previous)
  if previous == nil then
    return { anodyne = nil, legacy = nil }
  end
  if type(previous) ~= "table" then
    error("replace.previous must be a table", 3)
  end
  for key in pairs(previous) do
    if key ~= "anodyne" and key ~= "legacy" then
      error("unknown replace.previous key: " .. tostring(key), 3)
    end
  end
  for _, key in ipairs({ "anodyne", "legacy" }) do
    if previous[key] ~= nil and type(previous[key]) ~= "table" then
      error("replace.previous." .. key .. " must be a table", 3)
    end
  end
  return previous
end

local function appendReturnedErrors(errors, context, returned)
  if returned == nil then
    return
  end
  if type(returned) == "table" then
    for _, value in ipairs(returned) do
      appendError(errors, context, value)
    end
  else
    appendError(errors, context, returned)
  end
end

function Anodyne.replace(options)
  validateOptions("replace", options, { hs = true, previous = true, config = true })
  local previous = validatePrevious(options.previous)
  local errors = {}
  local seen = {}

  local modern = previous.anodyne
  if modern then
    seen[modern] = true
    local ok, _, returned = pcall(function()
      return modern:stop()
    end)
    if not ok then
      appendError(errors, "previous.anodyne.stop", _)
    else
      appendReturnedErrors(errors, "previous.anodyne.stop", returned)
    end
  end

  local legacy = previous.legacy
  if legacy and not seen[legacy] then
    local legacyErrors = cleanupFields(legacy, {})
    for _, value in ipairs(legacyErrors or {}) do
      appendError(errors, "previous.legacy", value)
    end
  end

  if #errors > 0 then
    error(aggregate("Anodyne replacement teardown", errors), 2)
  end
  local replacement = Anodyne.new({ hs = options.hs, config = options.config })
  return replacement:start()
end

return Anodyne
