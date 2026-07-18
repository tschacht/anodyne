local Fake = {}

local function fail(message)
  error("fake_hs: " .. message, 3)
end

local function noExtra(kind, ...)
  if select("#", ...) ~= 0 then
    fail(kind .. " received too many arguments")
  end
end

local function copyFrame(frame)
  if type(frame) ~= "table" then
    fail("frame must be a table")
  end
  for _, key in ipairs({ "x", "y", "w", "h" }) do
    if type(frame[key]) ~= "number" then
      fail("frame." .. key .. " must be a number")
    end
  end
  return { x = frame.x, y = frame.y, w = frame.w, h = frame.h }
end

local function live(state, kind)
  if state.deleted then
    fail(kind .. " used after delete")
  end
end

local function strictObject(kind, methods, state, numeric)
  local object = {}
  local metatable = {
    __index = function(_, key)
      if methods[key] then
        return methods[key]
      end
      if numeric and type(key) == "number" then
        live(state, kind)
        return state.elements[key]
      end
      fail("unknown " .. kind .. " member " .. tostring(key))
    end,
  }
  if numeric then
    metatable.__newindex = function(_, key, value)
      live(state, kind)
      if type(key) ~= "number" or type(value) ~= "table" then
        fail(kind .. " elements require numeric indexes and table values")
      end
      state.elements[key] = value
    end
  end
  return setmetatable(object, metatable)
end

function Fake.new(options)
  options = options or {}
  local runtime = {
    timers = {},
    menus = {},
    hotkeys = {},
    modals = {},
    filters = {},
    taps = {},
    canvases = {},
    screens = {},
    windows = {},
    now = 0,
    callLog = {},
    lifecycleFaults = {},
    invocationCounts = {},
  }

  local function lifecycle(operation)
    local invocation = (runtime.invocationCounts[operation] or 0) + 1
    runtime.invocationCounts[operation] = invocation
    table.insert(runtime.callLog, operation .. "#" .. invocation)
    local fault = runtime.lifecycleFaults[operation]
    if fault and fault.invocation == invocation then
      error(fault.message or ("injected " .. operation .. " failure"))
    end
  end

  local screenMethods = {}
  function screenMethods:id(...)
    noExtra("screen:id", ...)
    live(self._state, "screen")
    if self._state.faults.invalidId then
      return nil
    end
    return self._state.id
  end
  function screenMethods:getUUID(...)
    noExtra("screen:getUUID", ...)
    live(self._state, "screen")
    if self._state.faults.invalidId then
      return nil
    end
    return self._state.uuid
  end
  function screenMethods:frame(...)
    noExtra("screen:frame", ...)
    live(self._state, "screen")
    if self._state.faults.invalidFrame then
      return nil
    end
    return copyFrame(self._state.frame)
  end
  function screenMethods:fullFrame(...)
    noExtra("screen:fullFrame", ...)
    live(self._state, "screen")
    if self._state.faults.fullFrameThrows then
      error("injected fullFrame failure")
    end
    if self._state.faults.invalidFullFrame then
      return nil
    end
    return copyFrame(self._state.fullFrame)
  end

  local function addScreen(spec)
    spec = spec or {}
    local state = {
      id = spec.id or (#runtime.screens + 1),
      uuid = spec.uuid or ("screen-" .. (#runtime.screens + 1)),
      frame = copyFrame(spec.frame or { x = 0, y = 0, w = 1920, h = 1080 }),
      fullFrame = copyFrame(spec.fullFrame or spec.frame or { x = 0, y = 0, w = 1920, h = 1080 }),
      faults = {},
    }
    local screen = strictObject("screen", screenMethods, state)
    rawset(screen, "_state", state)
    table.insert(runtime.screens, screen)
    return screen
  end

  local windowMethods = {}
  function windowMethods:id(...)
    noExtra("window:id", ...)
    live(self._state, "window")
    if self._state.faults.invalidId then
      return nil
    end
    return self._state.id
  end
  function windowMethods:screen(...)
    noExtra("window:screen", ...)
    live(self._state, "window")
    if self._state.faults.invalidScreen then
      return nil
    end
    return self._state.screen
  end
  function windowMethods:frame(...)
    noExtra("window:frame", ...)
    live(self._state, "window")
    if self._state.faults.readThrows or (self._state.faults.readThrowsAfterSet and self._state.writeCount > 0) then
      error("injected frame readback failure")
    end
    if self._state.faults.invalidFrame then
      return nil
    end
    local result = copyFrame(self._state.frame)
    table.insert(self._state.frameReads, result)
    return result
  end
  function windowMethods:setFrame(frame, duration, ...)
    noExtra("window:setFrame", ...)
    live(self._state, "window")
    frame = copyFrame(frame)
    if duration ~= 0 then
      fail("window:setFrame duration must be zero")
    end
    local faults = self._state.faults
    self._state.writeCount = self._state.writeCount + 1
    if faults.setThrows then
      error("injected setFrame failure")
    end
    if faults.rollbackFails and self._state.writeCount > 1 then
      return self
    end
    if faults.ignoreWrite then
      return self
    end
    if faults.coerceWrite and self._state.writeCount == 1 then
      frame.w = frame.w + (faults.coerceBy or 1)
    end
    self._state.frame = frame
    return self
  end

  local function addWindow(spec)
    spec = spec or {}
    local state = {
      id = spec.id or (#runtime.windows + 1),
      frame = copyFrame(spec.frame or { x = 100, y = 100, w = 800, h = 600 }),
      screen = spec.screen or runtime.screens[1],
      faults = {},
      writeCount = 0,
      frameReads = {},
    }
    local window = strictObject("window", windowMethods, state)
    rawset(window, "_state", state)
    table.insert(runtime.windows, window)
    return window
  end

  addScreen(options.screen)
  if options.window ~= false then
    runtime.focused = addWindow(options.window)
    runtime.frontmost = runtime.focused
  end

  local timerMethods = {}
  function timerMethods:stop(...)
    noExtra("timer:stop", ...)
    lifecycle("timer.stop")
    live(self._state, "timer")
    self._state.active = false
    return self
  end
  function timerMethods:delete(...)
    noExtra("timer:delete", ...)
    lifecycle("timer.delete")
    live(self._state, "timer")
    self._state.active = false
    self._state.deleted = true
  end

  local menuMethods = {}
  function menuMethods:setTitle(title, ...)
    noExtra("menubar:setTitle", ...)
    lifecycle("menubar.setTitle")
    live(self._state, "menubar")
    if type(title) ~= "string" then
      fail("menubar title must be a string")
    end
    self._state.title = title
    return self
  end
  function menuMethods:setTooltip(value, ...)
    noExtra("menubar:setTooltip", ...)
    lifecycle("menubar.setTooltip")
    live(self._state, "menubar")
    if type(value) ~= "string" then
      fail("menubar tooltip must be a string")
    end
    self._state.tooltip = value
    return self
  end
  function menuMethods:setMenu(value, ...)
    noExtra("menubar:setMenu", ...)
    lifecycle("menubar.setMenu")
    live(self._state, "menubar")
    if type(value) ~= "function" and type(value) ~= "table" then
      fail("menubar menu must be a function or table")
    end
    self._state.menu = value
    return self
  end
  function menuMethods:delete(...)
    noExtra("menubar:delete", ...)
    lifecycle("menubar.delete")
    live(self._state, "menubar")
    self._state.deleted = true
  end

  local hotkeyMethods = {}
  function hotkeyMethods:delete(...)
    noExtra("hotkey:delete", ...)
    lifecycle("hotkey.delete")
    live(self._state, "hotkey")
    self._state.deleted = true
    self._state.active = false
  end

  local modalMethods = {}
  function modalMethods:enter(...)
    noExtra("modal:enter", ...)
    lifecycle("modal.enter")
    live(self._state, "modal")
    if self._state.active then
      fail("modal entered twice")
    end
    self._state.active = true
    if self.entered then
      self:entered()
    end
  end
  function modalMethods:exit(...)
    noExtra("modal:exit", ...)
    lifecycle("modal.exit")
    live(self._state, "modal")
    if not self._state.active then
      return
    end
    self._state.active = false
    if self.exited then
      self:exited()
    end
  end
  function modalMethods:delete(...)
    noExtra("modal:delete", ...)
    lifecycle("modal.delete")
    live(self._state, "modal")
    if self._state.active then
      self:exit()
    end
    self._state.deleted = true
  end

  local filterMethods = {}
  function filterMethods:subscribe(event, callback, ...)
    noExtra("filter:subscribe", ...)
    lifecycle("filter.subscribe")
    live(self._state, "filter")
    if type(event) ~= "string" or type(callback) ~= "function" then
      fail("filter subscription requires event and callback")
    end
    if self._state.callbacks[event] then
      fail("filter event registered twice")
    end
    self._state.callbacks[event] = callback
    return self
  end
  function filterMethods:unsubscribeAll(...)
    noExtra("filter:unsubscribeAll", ...)
    lifecycle("filter.unsubscribeAll")
    live(self._state, "filter")
    self._state.callbacks = {}
    return self
  end

  local tapMethods = {}
  function tapMethods:start(...)
    noExtra("eventtap:start", ...)
    lifecycle("eventtap.start")
    live(self._state, "eventtap")
    if self._state.active then
      fail("eventtap started twice")
    end
    self._state.active = true
    return self
  end
  function tapMethods:stop(...)
    noExtra("eventtap:stop", ...)
    lifecycle("eventtap.stop")
    live(self._state, "eventtap")
    self._state.active = false
    return self
  end
  function tapMethods:delete(...)
    noExtra("eventtap:delete", ...)
    lifecycle("eventtap.delete")
    live(self._state, "eventtap")
    self._state.active = false
    self._state.deleted = true
  end

  local canvasMethods = {}
  function canvasMethods:level(value, ...)
    noExtra("canvas:level", ...)
    lifecycle("canvas.level")
    if value ~= "overlay" then
      fail("canvas level is invalid")
    end
    live(self._state, "canvas")
    self._state.level = value
    return self
  end
  function canvasMethods:behavior(value, ...)
    noExtra("canvas:behavior", ...)
    lifecycle("canvas.behavior")
    if value ~= "canJoinAllSpaces" then
      fail("canvas behavior is invalid")
    end
    live(self._state, "canvas")
    self._state.behavior = value
    return self
  end
  function canvasMethods:show(...)
    noExtra("canvas:show", ...)
    lifecycle("canvas.show")
    live(self._state, "canvas")
    self._state.visible = true
    return self
  end
  function canvasMethods:hide(...)
    noExtra("canvas:hide", ...)
    lifecycle("canvas.hide")
    live(self._state, "canvas")
    self._state.visible = false
    return self
  end
  function canvasMethods:delete(...)
    noExtra("canvas:delete", ...)
    lifecycle("canvas.delete")
    live(self._state, "canvas")
    self._state.visible = false
    self._state.deleted = true
  end

  local hs = {
    window = { filter = { windowFocused = "windowFocused", windowDestroyed = "windowDestroyed" } },
    screen = {},
    timer = {},
    menubar = {},
    hotkey = { modal = {} },
    eventtap = { event = { types = {
      keyDown = 10,
      keyUp = 11,
      flagsChanged = 12,
    } } },
    keycodes = { map = {} },
    canvas = {
      windowLevels = { overlay = "overlay" },
      windowBehaviors = { canJoinAllSpaces = "canJoinAllSpaces" },
    },
    fnutils = {},
  }

  function hs.window.focusedWindow(...)
    if select("#", ...) ~= 0 then
      fail("window.focusedWindow takes no arguments")
    end
    return runtime.focused
  end
  function hs.window.frontmostWindow(...)
    if select("#", ...) ~= 0 then
      fail("window.frontmostWindow takes no arguments")
    end
    lifecycle("window.frontmostWindow")
    return runtime.frontmost
  end
  function hs.window.filter.new(...)
    if select("#", ...) > 1 then
      fail("window.filter.new takes at most one argument")
    end
    lifecycle("filter.new")
    local global = ...
    if global ~= nil and global ~= true then
      fail("window.filter.new accepts only true or no argument")
    end
    local state = { global = global == true, callbacks = {} }
    local filter = strictObject("window filter", filterMethods, state)
    rawset(filter, "_state", state)
    table.insert(runtime.filters, filter)
    return filter
  end
  function hs.screen.mainScreen(...)
    if select("#", ...) ~= 0 then
      fail("screen.mainScreen takes no arguments")
    end
    return runtime.screens[1]
  end
  function hs.screen.allScreens(...)
    if select("#", ...) ~= 0 then
      fail("screen.allScreens takes no arguments")
    end
    local result = {}
    for _, screen in ipairs(runtime.screens) do
      if not screen._state.removed then
        table.insert(result, screen)
      end
    end
    return result
  end
  function hs.timer.doAfter(delay, callback, ...)
    noExtra("timer.doAfter", ...)
    lifecycle("timer.doAfter")
    if type(delay) ~= "number" or delay < 0 or type(callback) ~= "function" then
      fail("timer.doAfter requires nonnegative delay and callback")
    end
    local state = { due = runtime.now + delay, callback = callback, active = true }
    local timer = strictObject("timer", timerMethods, state)
    rawset(timer, "_state", state)
    table.insert(runtime.timers, timer)
    return timer
  end
  function hs.menubar.new(...)
    if select("#", ...) ~= 0 then
      fail("menubar.new takes no arguments")
    end
    lifecycle("menubar.new")
    local state = {}
    local menu = strictObject("menubar", menuMethods, state)
    rawset(menu, "_state", state)
    table.insert(runtime.menus, menu)
    return menu
  end
  function hs.hotkey.bind(modifiers, key, callback, ...)
    noExtra("hotkey.bind", ...)
    lifecycle("hotkey.bind")
    if type(modifiers) ~= "table" or type(key) ~= "string" or type(callback) ~= "function" then
      fail("hotkey.bind requires modifiers, key, callback")
    end
    local state = { modifiers = modifiers, key = key, callback = callback, active = true }
    local hotkey = strictObject("hotkey", hotkeyMethods, state)
    rawset(hotkey, "_state", state)
    table.insert(runtime.hotkeys, hotkey)
    return hotkey
  end
  function hs.hotkey.modal.new(...)
    if select("#", ...) ~= 0 then
      fail("hotkey.modal.new takes no arguments")
    end
    lifecycle("modal.new")
    local state = { active = false }
    local modal = strictObject("modal", modalMethods, state)
    rawset(modal, "_state", state)
    table.insert(runtime.modals, modal)
    return modal
  end
  function hs.eventtap.new(events, callback, ...)
    noExtra("eventtap.new", ...)
    lifecycle("eventtap.new")
    if type(events) ~= "table" or type(callback) ~= "function" then
      fail("eventtap.new requires events and callback")
    end
    local allowed = {
      [hs.eventtap.event.types.keyDown] = true,
      [hs.eventtap.event.types.keyUp] = true,
      [hs.eventtap.event.types.flagsChanged] = true,
    }
    local eventCount = #events
    local suppliedCount = 0
    for key in pairs(events) do
      suppliedCount = suppliedCount + 1
      if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > eventCount then
        fail("eventtap.new events must be a dense array")
      end
    end
    if suppliedCount ~= eventCount then
      fail("eventtap.new events must be a dense array")
    end
    local registered = {}
    for _, eventType in ipairs(events) do
      if not allowed[eventType] then
        fail("eventtap.new received an invalid event type")
      end
      if registered[eventType] then
        fail("eventtap.new received a duplicate event type")
      end
      registered[eventType] = true
    end
    if #events == 0 then
      fail("eventtap.new requires at least one event type")
    end
    local copiedEvents = {}
    for index, eventType in ipairs(events) do
      copiedEvents[index] = eventType
    end
    local state = { events = copiedEvents, registered = registered, callback = callback, active = false, deliveries = 0 }
    local tap = strictObject("eventtap", tapMethods, state)
    rawset(tap, "_state", state)
    table.insert(runtime.taps, tap)
    return tap
  end
  function hs.canvas.new(frame, ...)
    noExtra("canvas.new", ...)
    lifecycle("canvas.new")
    local state = { frame = copyFrame(frame), elements = {}, visible = false }
    local canvas = strictObject("canvas", canvasMethods, state, true)
    rawset(canvas, "_state", state)
    table.insert(runtime.canvases, canvas)
    return canvas
  end
  function hs.fnutils.split(value, separator, ...)
    noExtra("fnutils.split", ...)
    if type(value) ~= "string" or type(separator) ~= "string" or separator == "" then
      fail("fnutils.split requires strings")
    end
    local result, start = {}, 1
    while true do
      local first, last = value:find(separator, start, true)
      if not first then
        table.insert(result, value:sub(start))
        break
      end
      table.insert(result, value:sub(start, first - 1))
      start = last + 1
    end
    return result
  end

  local keyNames = { "a", "w", "h", "m", "r", "u", "escape", "delete", "left", "right", "up", "down", "c", "b", "g", "s" }
  for number = 0, 9 do
    table.insert(keyNames, tostring(number))
  end
  for code, name in ipairs(keyNames) do
    hs.keycodes.map[code] = name
  end

  local function strictNamespace(name, namespace)
    return setmetatable(namespace, {
      __index = function(_, key)
        fail("unknown " .. name .. " API " .. tostring(key))
      end,
    })
  end
  hs.window.filter = strictNamespace("window.filter", hs.window.filter)
  hs.window = strictNamespace("window", hs.window)
  hs.screen = strictNamespace("screen", hs.screen)
  hs.timer = strictNamespace("timer", hs.timer)
  hs.menubar = strictNamespace("menubar", hs.menubar)
  hs.hotkey.modal = strictNamespace("hotkey.modal", hs.hotkey.modal)
  hs.hotkey = strictNamespace("hotkey", hs.hotkey)
  hs.eventtap.event.types = strictNamespace("eventtap.event.types", hs.eventtap.event.types)
  hs.eventtap.event = strictNamespace("eventtap.event", hs.eventtap.event)
  hs.eventtap = strictNamespace("eventtap", hs.eventtap)
  hs.keycodes = strictNamespace("keycodes", hs.keycodes)
  hs.canvas.windowLevels = strictNamespace("canvas.windowLevels", hs.canvas.windowLevels)
  hs.canvas.windowBehaviors = strictNamespace("canvas.windowBehaviors", hs.canvas.windowBehaviors)
  hs.canvas = strictNamespace("canvas", hs.canvas)
  hs.fnutils = strictNamespace("fnutils", hs.fnutils)
  hs = strictNamespace("hs", hs)

  local driver = { hs = hs, runtime = runtime }
  function driver:addScreen(spec)
    return addScreen(spec)
  end
  function driver:addWindow(spec)
    return addWindow(spec)
  end
  function driver:setFocused(window)
    runtime.focused = window
  end
  function driver:setFrontmost(window)
    runtime.frontmost = window
  end
  function driver:setFault(object, name, value)
    object._state.faults[name] = value == nil and true or value
    if name == "coerceWrite" or name == "rollbackFails" or name == "readThrowsAfterSet" then
      object._state.writeCount = 0
    end
  end
  function driver:clearFaults(object)
    object._state.faults = {}
    object._state.writeCount = 0
  end
  function driver:setLifecycleFault(operation, invocation, message)
    if type(operation) ~= "string" or type(invocation) ~= "number" or invocation < 1 then
      fail("driver:setLifecycleFault requires an operation and positive invocation")
    end
    runtime.lifecycleFaults[operation] = { invocation = invocation, message = message }
  end
  function driver:clearLifecycleFaults()
    runtime.lifecycleFaults = {}
  end
  function driver:clearCallLog()
    runtime.callLog = {}
  end
  function driver:callLog()
    local result = {}
    for index, value in ipairs(runtime.callLog) do
      result[index] = value
    end
    return result
  end
  function driver:removeScreen(screen)
    screen._state.removed = true
  end
  function driver:setFullFrame(screen, frame)
    screen._state.fullFrame = copyFrame(frame)
  end
  function driver:setScreenFrame(screen, frame)
    screen._state.frame = copyFrame(frame)
  end
  function driver:setWindowFrame(window, frame)
    window._state.frame = copyFrame(frame)
  end
  function driver:setWindowScreen(window, screen)
    window._state.screen = screen
  end
  function driver:clearFrameReads(window)
    window._state.frameReads = {}
  end
  function driver:frameReads(window)
    local reads = {}
    for index, value in ipairs(window._state.frameReads) do
      reads[index] = value
    end
    return reads
  end
  function driver:destroyWindow(window)
    for _, filter in ipairs(runtime.filters) do
      local callback = filter._state.callbacks.windowDestroyed
      if callback then
        callback(window)
      end
    end
    window._state.deleted = true
  end
  function driver:focus(window)
    runtime.focused = window
    for _, filter in ipairs(runtime.filters) do
      local callback = filter._state.callbacks.windowFocused
      if callback then
        callback(window)
      end
    end
  end
  function driver:menuItems()
    local menu = runtime.menus[#runtime.menus]
    local value = menu._state.menu
    return type(value) == "function" and value() or value
  end
  function driver:menuItem(title)
    for _, item in ipairs(self:menuItems()) do
      if item.title == title then
        return item
      end
    end
    return nil
  end
  function driver:triggerEntry()
    local hotkey = runtime.hotkeys[#runtime.hotkeys]
    live(hotkey._state, "hotkey")
    hotkey._state.callback()
  end
  function driver:key(name, flags, eventType)
    local code
    for candidate, mapped in pairs(hs.keycodes.map) do
      if mapped == name then
        code = candidate
      end
    end
    local eventAliases = {
      keyDown = hs.eventtap.event.types.keyDown,
      keyUp = hs.eventtap.event.types.keyUp,
      flagsChanged = hs.eventtap.event.types.flagsChanged,
    }
    local actualEventType = eventAliases[eventType] or eventType or hs.eventtap.event.types.keyDown
    local event = {}
    function event.getType(self, ...)
      if self ~= event then
        fail("event:getType must be called with colon syntax")
      end
      noExtra("event:getType", ...)
      return actualEventType
    end
    function event.getKeyCode(self, ...)
      if self ~= event then
        fail("event:getKeyCode must be called with colon syntax")
      end
      noExtra("event:getKeyCode", ...)
      return code or 999
    end
    function event.getFlags(self, ...)
      if self ~= event then
        fail("event:getFlags must be called with colon syntax")
      end
      noExtra("event:getFlags", ...)
      return flags or {}
    end
    runtime.lastEvent = event
    for index = #runtime.taps, 1, -1 do
      local tap = runtime.taps[index]
      if tap._state.active and not tap._state.deleted and tap._state.registered[actualEventType] then
        tap._state.deliveries = tap._state.deliveries + 1
        return tap._state.callback(event)
      end
    end
    return false
  end
  function driver:advance(seconds)
    if type(seconds) ~= "number" or seconds < 0 then
      fail("driver:advance requires a nonnegative number")
    end
    local target = runtime.now + seconds
    while true do
      local nextTimer
      for _, timer in ipairs(runtime.timers) do
        local state = timer._state
        if state.active and not state.deleted and state.due <= target then
          if not nextTimer or state.due < nextTimer._state.due then
            nextTimer = timer
          end
        end
      end
      if not nextTimer then
        break
      end
      runtime.now = nextTimer._state.due
      nextTimer._state.active = false
      nextTimer._state.callback()
    end
    runtime.now = target
  end
  function driver:lastMessage()
    for index = #runtime.canvases, 1, -1 do
      local state = runtime.canvases[index]._state
      if not state.deleted and state.visible then
        local textElement = state.elements[2]
        if textElement then
          return textElement.text
        end
        return nil
      end
    end
    return nil
  end
  function driver:activeCounts()
    local counts = { timers = 0, menus = 0, hotkeys = 0, modals = 0, filters = 0, taps = 0, canvases = 0 }
    for _, timer in ipairs(runtime.timers) do
      if timer._state.active and not timer._state.deleted then
        counts.timers = counts.timers + 1
      end
    end
    for _, menu in ipairs(runtime.menus) do
      if not menu._state.deleted then
        counts.menus = counts.menus + 1
      end
    end
    for _, hotkey in ipairs(runtime.hotkeys) do
      if hotkey._state.active and not hotkey._state.deleted then
        counts.hotkeys = counts.hotkeys + 1
      end
    end
    for _, modal in ipairs(runtime.modals) do
      if not modal._state.deleted then
        counts.modals = counts.modals + 1
      end
    end
    for _, filter in ipairs(runtime.filters) do
      if next(filter._state.callbacks) then
        counts.filters = counts.filters + 1
      end
    end
    for _, tap in ipairs(runtime.taps) do
      if tap._state.active and not tap._state.deleted then
        counts.taps = counts.taps + 1
      end
    end
    for _, canvas in ipairs(runtime.canvases) do
      if not canvas._state.deleted then
        counts.canvases = counts.canvases + 1
      end
    end
    return counts
  end
  function driver:load(path)
    _G.hs = hs
    dofile(path or os.getenv("ANODYNE_INIT_UNDER_TEST") or "init.lua")
    return _G.WindowManager
  end
  function driver:shutdown()
    if _G.Anodyne and type(_G.Anodyne.stop) == "function" then
      pcall(function()
        _G.Anodyne:stop()
      end)
    elseif _G.WindowManager then
      local manager = _G.WindowManager
      for _, name in ipairs({ "modalTimer", "modalRefreshTimer", "menuFailureTimer", "modalKeyGuard" }) do
        local object = rawget(manager, name)
        if object and object.stop then
          pcall(function()
            object:stop()
          end)
        end
      end
      for _, name in ipairs({ "entryHotkey", "windowMode", "modalCanvas", "menu" }) do
        local object = rawget(manager, name)
        if object and object.delete then
          pcall(function()
            object:delete()
          end)
        end
      end
      for _, name in ipairs({ "windowFilter", "historyWindowFilter" }) do
        local object = rawget(manager, name)
        if object then
          pcall(function()
            object:unsubscribeAll()
          end)
        end
      end
    end
    _G.Anodyne, _G.WindowManager, _G.hs = nil, nil, nil
  end

  return driver
end

return Fake
