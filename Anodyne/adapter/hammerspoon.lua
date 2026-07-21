local Adapter = {}
Adapter.__index = Adapter

local History = require("Anodyne.core.history")
local WindowActions = require("Anodyne.window_actions")
local Keymap = require("Anodyne.core.keymap")
local View = require("Anodyne.view")
local Controller = require("Anodyne.controller")
local ObsCropController = require("Anodyne.obs_crop_controller")

local cleanupStages = {
  { "modalTimer", "stop" },
  { "modalRefreshTimer", "stop" },
  { "menuFailureTimer", "stop" },
  { "modalKeyGuard", "stop" },
  { "compositionResultTimer", "stop" },
  { "entryHotkey", "delete" },
  { "compositionEntryHotkey", "delete" },
  { "windowMode", "delete" },
  { "compositionMode", "delete" },
  { "modalCanvas", "hide" },
  { "modalCanvas", "delete" },
  { "compositionCanvas", "hide" },
  { "compositionCanvas", "delete" },
  { "compositionStatusCanvas", "hide" },
  { "compositionStatusCanvas", "delete" },
  { "menu", "delete" },
  { "windowFilter", "unsubscribeAll" },
  { "historyWindowFilter", "unsubscribeAll" },
}

local function appendError(errors, context, value)
  errors[#errors + 1] = context .. ": " .. tostring(value)
end

local function cleanup(owner, progress)
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
      local isCanvas = field == "modalCanvas" or field == "compositionCanvas" or field == "compositionStatusCanvas"
      local blockedByHide = isCanvas and method == "delete" and not record.done.hide
      if not record.done[method] and not blockedByHide then
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
      local needsStop = field == "modalTimer"
        or field == "modalRefreshTimer"
        or field == "menuFailureTimer"
        or field == "modalKeyGuard"
        or field == "compositionResultTimer"
      local needsHide = isCanvas
      local needsDelete = field == "entryHotkey"
        or field == "compositionEntryHotkey"
        or field == "windowMode"
        or field == "compositionMode"
        or isCanvas
        or field == "menu"
      local needsUnsubscribe = field == "windowFilter" or field == "historyWindowFilter"
      local complete = (not needsStop or record.done.stop)
        and (not needsHide or record.done.hide)
        and (not needsDelete or record.done.delete)
        and (not needsUnsubscribe or record.done.unsubscribeAll)
      if complete then
        if rawget(owner, field) == object then
          rawset(owner, field, nil)
        end
        progress[field] = nil
      end
    end
  end
  return #errors > 0 and errors or nil
end

function Adapter.new(options)
  return setmetatable({
    owner = options.owner,
    hs = options.hs,
    config = options.config,
    geometry = options.geometry,
    metadata = options.metadata,
    currentGeneration = options.currentGeneration,
    cleanupProgress = {},
  }, Adapter)
end

function Adapter:start()
  local owner = self.owner
  local hs = self.hs
  local config = self.config
  local geometry = self.geometry
  local metadata = self.metadata
  local currentGeneration = self.currentGeneration
  local windowMode
  local compositionMode
  local cropController
  local compositionGeneration
  local compositionHelp
  local compositionExitPending = false
  local compositionLinger = false
  local compositionTeardownPending = false
  local exitCompositionMode
  local dismissCompositionPresentation
  local startCompositionLinger

  local function compositionPresentationPending()
    return compositionTeardownPending
      or compositionLinger
      or compositionExitPending
      or compositionGeneration ~= nil
      or owner.compositionResultTimer ~= nil
      or owner.compositionCanvas ~= nil
      or owner.compositionStatusCanvas ~= nil
  end

  owner.modalState = {
    active = false,
    screen = "home",
    targetWindow = nil,
    sessionInitialFrame = nil,
    sessionInitialScreen = nil,
  }
  local modalState = owner.modalState
  owner.frameHistory = {}
  local history = History.new({
    entries = owner.frameHistory,
    depth = config.undoDepth,
    copyFrame = geometry.copyFrame,
    framesEqual = geometry.framesEqual,
  })

  owner.menu = hs.menubar.new()
  local menu = owner.menu
  if not menu then
    error("Failed to create menu bar item")
  end

  owner.windowFilter = hs.window.filter.new()
  local windowFilter = owner.windowFilter
  if not windowFilter then
    error("Failed to create focused-window filter")
  end
  owner.historyWindowFilter = hs.window.filter.new(true)
  local historyWindowFilter = owner.historyWindowFilter
  if not historyWindowFilter then
    error("Failed to create history window filter")
  end
  owner.lastFocusedWindow = hs.window.frontmostWindow()

  local function closeModalOverlay()
    local canvas = owner.modalCanvas
    if not canvas then
      return true
    end
    local hidden, hideError = pcall(function()
      canvas:hide()
    end)
    if not hidden then
      return false, hideError
    end
    local deleted, deleteError = pcall(function()
      canvas:delete()
    end)
    if deleted then
      owner.modalCanvas = nil
      return true
    end
    return false, deleteError
  end

  local function closeCompositionGuide()
    local canvas = owner.compositionCanvas
    if not canvas then
      return true
    end
    local hidden, hideError = pcall(function()
      canvas:hide()
    end)
    if not hidden then
      return false, hideError
    end
    local deleted, deleteError = pcall(function()
      canvas:delete()
    end)
    if deleted then
      owner.compositionCanvas = nil
      return true
    end
    return false, deleteError
  end

  local function closeCompositionStatus()
    local canvas = owner.compositionStatusCanvas
    if not canvas then
      return true
    end
    local hidden, hideError = pcall(function()
      canvas:hide()
    end)
    if not hidden then
      return false, hideError
    end
    local deleted, deleteError = pcall(function()
      canvas:delete()
    end)
    if deleted then
      owner.compositionStatusCanvas = nil
      return true
    end
    return false, deleteError
  end

  local function stopCompositionResultTimer()
    local timer = owner.compositionResultTimer
    if not timer then
      return true
    end
    local stopped, stopError = pcall(function()
      timer:stop()
    end)
    if stopped then
      owner.compositionResultTimer = nil
      return true
    end
    return false, stopError
  end

  local function stopMenuFailureTimer()
    local timer = owner.menuFailureTimer
    if not timer then
      return true
    end
    local stopped, stopError = pcall(function()
      timer:stop()
    end)
    if stopped then
      owner.menuFailureTimer = nil
      return true
    end
    return false, stopError
  end

  local function stopModalKeyGuard()
    local guard = owner.modalKeyGuard
    if not guard then
      return true
    end
    local stopped, stopError = pcall(function()
      guard:stop()
    end)
    if stopped then
      owner.modalKeyGuard = nil
      return true
    end
    return false, stopError
  end

  local function modalAlert(message)
    local timerStopped, timerError = stopMenuFailureTimer()
    if not timerStopped then
      error(timerError, 0)
    end
    local overlayClosed, overlayError = closeModalOverlay()
    if not overlayClosed then
      error(overlayError, 0)
    end

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
    if not canvas then
      error("Failed to create modal canvas")
    end
    owner.modalCanvas = canvas
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
  end

  local function showWindowFailure(message)
    modalAlert(message)
    local timer
    local created, timerOrError = pcall(function()
      return hs.timer.doAfter(config.menuFailureDuration, function()
        if not currentGeneration() or owner.menuFailureTimer ~= timer then
          return
        end
        owner.menuFailureTimer = nil
        closeModalOverlay()
      end)
    end)
    if created then
      timer = timerOrError
    end
    if not created or not timer then
      local closed, closeError = closeModalOverlay()
      if not closed then
        error(closeError, 0)
      end
      error(created and "Failed to create timer" or timerOrError, 0)
    end
    owner.menuFailureTimer = timer
    return true
  end

  local function compositionStatus(message)
    local closed, closeError = closeCompositionStatus()
    if not closed then
      return false, closeError
    end

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
    if not canvas then
      error("Failed to create composition status canvas")
    end
    owner.compositionStatusCanvas = canvas
    canvas:level(hs.canvas.windowLevels.overlay)
    canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    canvas:mouseCallback(nil)
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
    return true
  end

  local ports = {
    focusedWindow = function()
      return hs.window.focusedWindow()
    end,
    frontmostWindow = function()
      return hs.window.frontmostWindow()
    end,
    allScreens = function()
      return hs.screen.allScreens()
    end,
    windowId = function(window)
      return window:id()
    end,
    windowScreen = function(window)
      return window:screen()
    end,
    windowFrame = function(window)
      return window:frame()
    end,
    setWindowFrame = function(window, frame)
      window:setFrameWithWorkarounds(frame, 0)
    end,
    screenIdentity = function(screen)
      return screen:getUUID() or tostring(screen:id())
    end,
    screenFullFrame = function(screen)
      return screen:fullFrame()
    end,
    screenFrame = function(screen)
      return screen:frame()
    end,
  }
  local actions = WindowActions.new({
    owner = owner,
    modalState = modalState,
    config = config,
    geometry = geometry,
    history = history,
    ports = ports,
    cornerLabels = metadata.cornerLabelByName,
  })
  local view = View.new(config, metadata)
  local keymap = Keymap.new(metadata)
  local controller
  local requestWindowMode
  local requestCompositionMode

  local function startModalKeyGuard()
    local stopped, stopError = stopModalKeyGuard()
    if not stopped then
      error(stopError, 0)
    end
    owner.modalKeyGuard = hs.eventtap.new({
      hs.eventtap.event.types.keyDown,
      hs.eventtap.event.types.keyUp,
      hs.eventtap.event.types.flagsChanged,
    }, function(event)
      local eventType = event:getType()
      local eventKind = "other"
      if eventType == hs.eventtap.event.types.keyDown then
        eventKind = "keyDown"
      elseif eventType == hs.eventtap.event.types.keyUp then
        eventKind = "keyUp"
      elseif eventType == hs.eventtap.event.types.flagsChanged then
        eventKind = "flagsChanged"
      end
      local keyName
      local flags = {}
      if eventKind == "keyDown" then
        keyName = hs.keycodes.map[event:getKeyCode()]
        flags = event:getFlags()
      end
      return controller:handleEvent(eventKind, keyName, flags)
    end)
    if not owner.modalKeyGuard then
      error("Failed to create modal key guard")
    end
    owner.modalKeyGuard:start()
  end

  controller = Controller.new({
    owner = owner,
    state = modalState,
    config = config,
    metadata = metadata,
    actions = actions,
    keymap = keymap,
    view = view,
    ports = {
      currentGeneration = currentGeneration,
      schedule = function(delay, callback)
        local timer = hs.timer.doAfter(delay, callback)
        if not timer then
          error("Failed to create timer")
        end
        return timer
      end,
      stopTimer = function(timer)
        timer:stop()
      end,
      exitMode = function()
        if windowMode then
          windowMode:exit()
        end
      end,
      currentSize = function()
        local win = actions:getModalHomeWindow()
        if not win then
          return nil
        end
        local frame = win:frame()
        return { width = geometry.round(frame.w), height = geometry.round(frame.h) }
      end,
      renderModal = modalAlert,
      renderFailure = modalAlert,
      closeOverlay = closeModalOverlay,
      startKeyGuard = startModalKeyGuard,
      stopKeyGuard = stopModalKeyGuard,
    },
  })

  cropController = ObsCropController.new({
    config = config,
    view = view,
    ports = {
      currentGeneration = currentGeneration,
      selectWindow = function()
        return actions:getModalHomeWindow()
      end,
      windowId = ports.windowId,
      windowFrame = ports.windowFrame,
      windowScreen = ports.windowScreen,
      screenIdentity = ports.screenIdentity,
      screenFullFrame = ports.screenFullFrame,
      screenScale = function(screen)
        return screen:currentMode().scale
      end,
      renderGuide = function(_, fullFrame, guideFrame, help)
        if owner.compositionCanvas then
          local closed, closeError = closeCompositionGuide()
          if not closed then
            error(closeError, 0)
          end
        end
        local canvas = hs.canvas.new(fullFrame)
        if not canvas then
          error("Failed to create composition canvas")
        end
        owner.compositionCanvas = canvas
        canvas:level(hs.canvas.windowLevels.overlay)
        canvas:mouseCallback(nil)
        canvas[1] = {
          type = "rectangle",
          action = "stroke",
          strokeColor = { red = 1, green = 0.5, blue = 0, alpha = 1 },
          strokeWidth = config.obsCrop.guideStrokeWidth,
          frame = {
            x = guideFrame.x - fullFrame.x,
            y = guideFrame.y - fullFrame.y,
            w = guideFrame.w,
            h = guideFrame.h,
          },
        }
        canvas:show()
        local rendered, renderError = compositionStatus(help)
        if rendered then
          compositionHelp = help
        end
        return rendered, renderError
      end,
      copy = function(value)
        return hs.pasteboard.setContents(value)
      end,
      close = closeCompositionGuide,
      alert = function(message, duration)
        if cropController:isActive() then
          return compositionStatus((compositionHelp and (compositionHelp .. "\n") or "") .. "Status: " .. message)
        end
        return startCompositionLinger(message, duration or config.obsCrop.resultDuration)
      end,
    },
  })

  local function buildMenuItems()
    local items = controller:menuItems()
    for _, item in ipairs(items) do
      if item.intent then
        local intent = item.intent
        item.intent = nil
        item.fn = function()
          if intent.type == "composition" then
            requestCompositionMode()
          else
            controller:runMenu(intent)
          end
        end
      end
    end
    return items
  end

  menu:setTitle(config.menuTitle)
  menu:setTooltip(view:tooltip())
  menu:setMenu(buildMenuItems)

  windowFilter:subscribe(hs.window.filter.windowFocused, function(win)
    controller:onFocused(win)
  end)
  historyWindowFilter:subscribe(hs.window.filter.windowDestroyed, function(win)
    controller:onDestroyed(win)
    local state = cropController:currentState()
    local closed = cropController:onDestroyed(win, state.generation)
    if closed and not cropController:isActive() and compositionGeneration ~= nil and not compositionLinger then
      dismissCompositionPresentation()
    end
  end)

  owner.windowMode = hs.hotkey.modal.new()
  windowMode = owner.windowMode
  if not windowMode then
    error("Failed to create window modal")
  end
  function windowMode:entered()
    local targetWindow = actions:getModalHomeWindow()
    local frameOk, initialFrame = pcall(function()
      return targetWindow and geometry.copyFrame(targetWindow:frame()) or nil
    end)
    controller:enter(targetWindow, frameOk and initialFrame or nil, targetWindow and actions:windowScreenSnapshot(targetWindow) or nil)
  end
  function windowMode:exited()
    controller:exit()
  end

  owner.compositionMode = hs.hotkey.modal.new()
  compositionMode = owner.compositionMode
  if not compositionMode then
    error("Failed to create composition modal")
  end
  exitCompositionMode = function()
    compositionExitPending = true
    local exited = pcall(function()
      compositionMode:exit()
    end)
    if not exited then
      compositionLinger = true
      pcall(compositionStatus, "Composition Mode could not close; retry entry")
      return false
    end
    compositionExitPending = false
    compositionGeneration = nil
    return true
  end
  dismissCompositionPresentation = function()
    compositionTeardownPending = true
    local timerStopped = stopCompositionResultTimer()
    if not timerStopped then
      return false
    end
    local guideClosed = closeCompositionGuide()
    if not guideClosed then
      return false
    end
    local statusClosed = closeCompositionStatus()
    if not statusClosed then
      return false
    end
    if not exitCompositionMode() then
      return false
    end
    compositionLinger = false
    compositionHelp = nil
    compositionTeardownPending = false
    return true
  end
  startCompositionLinger = function(message, duration)
    local timerStopped, timerError = stopCompositionResultTimer()
    if not timerStopped then
      return false, timerError
    end
    compositionLinger = true
    local rendered, renderError = compositionStatus(message)
    if not rendered then
      return false, renderError
    end
    local timer
    timer = hs.timer.doAfter(duration, function()
      if not currentGeneration() or owner.compositionResultTimer ~= timer or not compositionLinger then
        return
      end
      owner.compositionResultTimer = nil
      dismissCompositionPresentation()
    end)
    if not timer then
      error("Failed to create composition result timer")
    end
    owner.compositionResultTimer = timer
    return true
  end
  function compositionMode:entered()
    local entered, generation = cropController:enter()
    if entered then
      compositionGeneration = generation
    elseif not compositionLinger then
      exitCompositionMode()
    end
  end
  function compositionMode:exited()
    if cropController:isActive() then
      cropController:cancel(compositionGeneration)
    end
    if not cropController:isActive() then
      if not compositionExitPending then
        compositionGeneration = nil
      end
    end
  end

  requestWindowMode = function()
    if not currentGeneration() then
      return
    end
    if cropController:isActive() then
      if not cropController:crossMode(compositionGeneration) then
        return
      end
    end
    if compositionPresentationPending() then
      if not dismissCompositionPresentation() then
        return
      end
    end
    windowMode:enter()
  end

  requestCompositionMode = function()
    if not currentGeneration() then
      return
    end
    if cropController:isActive() then
      return
    end
    if compositionPresentationPending() then
      if not dismissCompositionPresentation() then
        return
      end
    end
    local function windowResourcesRemain()
      return owner.modalTimer ~= nil
        or owner.modalRefreshTimer ~= nil
        or owner.menuFailureTimer ~= nil
        or owner.modalKeyGuard ~= nil
        or owner.modalCanvas ~= nil
    end
    if modalState.active or windowResourcesRemain() then
      local exited = pcall(function()
        windowMode:exit()
      end)
      if not exited or modalState.active or windowResourcesRemain() then
        pcall(function()
          controller:exit()
        end)
      end
      if modalState.active or windowResourcesRemain() then
        pcall(showWindowFailure, "Window Mode could not close; Composition Mode was not started")
        return
      end
    end
    compositionMode:enter()
  end

  owner.compositionEntryHotkey = hs.hotkey.bind(config.compositionHotkey.modifiers, config.compositionHotkey.key, function()
    requestCompositionMode()
  end)
  if not owner.compositionEntryHotkey then
    error("Failed to create/enable composition entry hotkey")
  end
  local finishBinding = compositionMode:bind({}, "return", function()
    if currentGeneration() and cropController:isActive() then
      local finished = cropController:finish(compositionGeneration)
      return finished
    end
  end)
  if not finishBinding then
    error("Failed to create Composition Finish/Copy binding")
  end
  local cancelBinding = compositionMode:bind({}, "escape", function()
    if currentGeneration() and cropController:isActive() then
      local cancelled = cropController:cancel(compositionGeneration)
      if cancelled then
        dismissCompositionPresentation()
      end
    elseif currentGeneration() and compositionPresentationPending() then
      dismissCompositionPresentation()
    end
  end)
  if not cancelBinding then
    error("Failed to create Composition Cancel binding")
  end
  owner.entryHotkey = hs.hotkey.bind(config.modalHotkey.modifiers, config.modalHotkey.key, function()
    requestWindowMode()
  end)
  if not owner.entryHotkey then
    error("Failed to create/enable entry hotkey")
  end
end

function Adapter:stop()
  return cleanup(self.owner, self.cleanupProgress)
end

return Adapter
