local Anodyne = {}

local DefaultConfig = require("Anodyne.config")
local DefaultGeometry = require("Anodyne.core.geometry")
local History = require("Anodyne.core.history")
local WindowActions = require("Anodyne.window_actions")
local Keymap = require("Anodyne.core.keymap")
local View = require("Anodyne.view")
local Controller = require("Anodyne.controller")

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

  local round = geometry.round
  local copyFrame = geometry.copyFrame
  local CORNER_LABEL_BY_NAME = metadata.cornerLabelByName

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
  local history = History.new({
    entries = frameHistory,
    depth = CONFIG.undoDepth,
    copyFrame = geometry.copyFrame,
    framesEqual = geometry.framesEqual,
  })

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
      window:setFrame(frame, 0)
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
    owner = WindowManager,
    modalState = modalState,
    config = CONFIG,
    geometry = geometry,
    history = history,
    ports = ports,
    cornerLabels = CORNER_LABEL_BY_NAME,
  })
  local view = View.new(CONFIG, metadata)
  local keymap = Keymap.new(metadata)
  local controller

  local function startModalKeyGuard()
    stopModalKeyGuard()

    WindowManager.modalKeyGuard = hs.eventtap.new({
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

    WindowManager.modalKeyGuard:start()
  end

  local function buildMenuItems()
    local items = controller:menuItems()
    for _, item in ipairs(items) do
      if item.intent then
        local intent = item.intent
        item.intent = nil
        item.fn = function()
          controller:runMenu(intent)
        end
      end
    end
    return items
  end

  menu:setTitle(CONFIG.menuTitle)
  menu:setTooltip(view:tooltip())
  menu:setMenu(buildMenuItems)

  controller = Controller.new({
    owner = WindowManager,
    state = modalState,
    config = CONFIG,
    metadata = metadata,
    actions = actions,
    keymap = keymap,
    view = view,
    ports = {
      currentGeneration = currentGeneration,
      schedule = function(delay, callback)
        return hs.timer.doAfter(delay, callback)
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
        return { width = round(frame.w), height = round(frame.h) }
      end,
      renderModal = modalAlert,
      renderFailure = modalAlert,
      closeOverlay = closeModalOverlay,
      startKeyGuard = startModalKeyGuard,
      stopKeyGuard = stopModalKeyGuard,
    },
  })

  windowFilter:subscribe(hs.window.filter.windowFocused, function(win)
    controller:onFocused(win)
  end)

  historyWindowFilter:subscribe(hs.window.filter.windowDestroyed, function(win)
    controller:onDestroyed(win)
  end)

  WindowManager.windowMode = hs.hotkey.modal.new()
  windowMode = WindowManager.windowMode

  function windowMode:entered()
    local targetWindow = actions:getModalHomeWindow()
    local frameOk, initialFrame = pcall(function()
      return targetWindow and copyFrame(targetWindow:frame()) or nil
    end)
    controller:enter(targetWindow, frameOk and initialFrame or nil, targetWindow and actions:windowScreenSnapshot(targetWindow) or nil)
  end

  function windowMode:exited()
    controller:exit()
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
