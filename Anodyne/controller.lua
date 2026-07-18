local Controller = {}
Controller.__index = Controller

function Controller.new(options)
  return setmetatable(options, Controller)
end

function Controller:isCurrent()
  return self.ports.currentGeneration()
end

function Controller:stopTimer(field)
  local timer = self.owner[field]
  if timer then
    pcall(self.ports.stopTimer, timer)
    self.owner[field] = nil
  end
end

function Controller:startModalTimer()
  self:stopTimer("modalTimer")
  local timer
  timer = self.ports.schedule(self.config.modalDuration, function()
    if not self:isCurrent() or self.owner.modalTimer ~= timer or not self.state.active then
      return
    end
    self.owner.modalTimer = nil
    self.ports.exitMode()
  end)
  self.owner.modalTimer = timer
end

function Controller:render(status)
  self.ports.renderModal(self.view:modalText(self.state, self.ports.currentSize(), status))
end

function Controller:transition(screen, status)
  self:stopTimer("modalRefreshTimer")
  if not self.metadata.screenTitles[screen] then
    self:render({ kind = "unknown-mode", screen = screen })
    return
  end
  self.state.screen = screen
  self:render(status)
end

function Controller:completeAction(success, failureMessage, successMessage, successScreen)
  if not success then
    self:render(failureMessage or { kind = "target-unavailable" })
    return
  end
  if successScreen then
    self:transition(successScreen, successMessage)
    return
  end
  self:stopTimer("modalRefreshTimer")
  local timer
  timer = self.ports.schedule(0.05, function()
    if not self:isCurrent() or self.owner.modalRefreshTimer ~= timer or not self.state.active then
      return
    end
    self.owner.modalRefreshTimer = nil
    self:render(successMessage)
  end)
  self.owner.modalRefreshTimer = timer
end

function Controller:perform(intent)
  local action = intent.action
  if action == "undo" then
    return self.actions:undoLastFrame()
  elseif action == "reset" then
    return self.actions:resetSessionFrame()
  elseif action == "aspect" then
    return self.actions:applyAspectPreset(intent.value)
  elseif action == "width" then
    return self.actions:applyWidthPreset(intent.value)
  elseif action == "height" then
    return self.actions:applyHeightPreset(intent.value)
  elseif action == "move" then
    return self.actions:moveByStep(intent.value)
  elseif action == "corner" then
    return self.actions:moveToCorner(intent.value)
  elseif action == "resize" then
    local value = intent.value
    return self.actions:resize(value.deltaWidth, value.deltaHeight, self.view:resizeLabel(value))
  end
  return false, { kind = "unknown-action", action = action }
end

function Controller:dispatch(intent)
  if intent.type == "exit" then
    self.ports.exitMode()
  elseif intent.type == "transition" then
    self:transition(intent.screen, intent.status)
  elseif intent.type == "status" then
    self:render(intent.status)
  elseif intent.type == "preset" then
    local screen = self.state.screen
    local values = screen == "aspect" and self.config.aspectPresets
      or screen == "width" and self.config.widthPresets
      or screen == "height" and self.config.heightPresets
    if not values then
      self:render({ kind = "numbers-unavailable", screen = screen })
    elseif not values[intent.index] then
      self:render({ kind = "missing-preset", screen = screen, index = intent.index })
    else
      local action = screen == "aspect" and "aspect" or screen
      local success, failureMessage, successMessage = self:perform({ type = "action", action = action, value = values[intent.index] })
      self:completeAction(success, failureMessage, successMessage)
    end
  elseif intent.type == "action" then
    local success, failureMessage, successMessage = self:perform(intent)
    self:completeAction(success, failureMessage, successMessage, intent.successScreen)
  end
end

function Controller:handleKey(key, flags)
  self:stopTimer("modalRefreshTimer")
  local intent, consumed = self.keymap:interpret(self.state.screen, key, flags)
  self:dispatch(intent)
  return consumed
end

function Controller:handleEvent(eventType, key, flags)
  if not self:isCurrent() or not self.state.active then
    return false
  end
  if eventType == "flagsChanged" then
    return false
  end
  if eventType == "keyUp" then
    return true
  end
  if eventType ~= "keyDown" then
    return true
  end
  self:startModalTimer()
  return self:handleKey(key, flags)
end

function Controller:showMenuFailure(message)
  self.ports.renderFailure(self.view:failureText(message))
  local timer
  timer = self.ports.schedule(self.config.menuFailureDuration, function()
    if not self:isCurrent() or self.owner.menuFailureTimer ~= timer or self.state.active then
      return
    end
    self.owner.menuFailureTimer = nil
    self.ports.closeOverlay()
  end)
  self.owner.menuFailureTimer = timer
end

function Controller:runMenu(intent)
  if not self:isCurrent() then
    return
  end
  if self.state.active then
    self:stopTimer("modalRefreshTimer")
    self:startModalTimer()
  else
    self:stopTimer("menuFailureTimer")
    self.ports.closeOverlay()
  end
  local success, failureMessage, successMessage = self:perform(intent)
  if self.state.active then
    self:completeAction(success, failureMessage, successMessage, intent.successScreen)
  elseif not success then
    self:showMenuFailure(failureMessage)
  end
end

function Controller:menuItems()
  local snapshot = self.state.active and self.state.sessionInitialFrame and self.state.sessionInitialScreen
  local changed = snapshot and not self.actions:screenSnapshotIsCurrent(self.state.sessionInitialScreen)
  return self.view:menuItems(self.state, changed)
end

function Controller:enter(targetWindow, initialFrame, initialScreen)
  if not self:isCurrent() then
    return
  end
  self.state.active = true
  self.state.screen = "home"
  self.state.targetWindow = targetWindow
  self.state.sessionInitialFrame = initialFrame
  self.state.sessionInitialScreen = initialScreen
  self:startModalTimer()
  self.ports.startKeyGuard()
  self:render()
end

function Controller:exit()
  if not self:isCurrent() then
    return
  end
  self:stopTimer("modalTimer")
  self:stopTimer("modalRefreshTimer")
  self:stopTimer("menuFailureTimer")
  self.ports.stopKeyGuard()
  self.ports.closeOverlay()
  self.state.active = false
  self.state.screen = "home"
  self.state.targetWindow = nil
  self.state.sessionInitialFrame = nil
  self.state.sessionInitialScreen = nil
end

function Controller:onFocused(window)
  if self:isCurrent() then
    self.actions:rememberFocused(window)
  end
end

function Controller:onDestroyed(window)
  if self:isCurrent() then
    self.actions:forgetWindow(window)
  end
end

return Controller
