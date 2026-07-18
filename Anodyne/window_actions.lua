local WindowActions = {}
WindowActions.__index = WindowActions

local function failure(message)
  return false, message
end

function WindowActions.new(options)
  return setmetatable(options, WindowActions)
end

function WindowActions:getValidWindow(candidate)
  if not candidate then
    return nil
  end
  local idOk, windowId = pcall(self.ports.windowId, candidate)
  if not idOk or not windowId then
    return nil
  end
  local screenOk, screen = pcall(self.ports.windowScreen, candidate)
  if not screenOk or not screen then
    return nil
  end
  return candidate, screen
end

function WindowActions:rememberFocused(candidate)
  local window = self:getValidWindow(candidate)
  if window then
    self.owner.lastFocusedWindow = window
  end
  return window
end

function WindowActions:getFocusedWindow()
  if self.modalState.active then
    local window = self:getValidWindow(self.modalState.targetWindow)
    if window then
      return window
    end
    return nil, "Modal target window is no longer available"
  end

  local window = self:rememberFocused(self.ports.focusedWindow())
  if window then
    return window
  end
  window = self:getValidWindow(self.owner.lastFocusedWindow)
  if window then
    return window
  end
  window = self:rememberFocused(self.ports.frontmostWindow())
  if not window then
    return nil, "No focused window"
  end
  return window
end

function WindowActions:getModalHomeWindow()
  if self.modalState.active then
    return self:getValidWindow(self.modalState.targetWindow)
  end
  local window = self:rememberFocused(self.ports.focusedWindow())
  if window then
    return window
  end
  window = self:getValidWindow(self.owner.lastFocusedWindow)
  if window then
    return window
  end
  return self:rememberFocused(self.ports.frontmostWindow())
end

function WindowActions:screenSnapshot(screen)
  local identityOk, identity = pcall(self.ports.screenIdentity, screen)
  local frameOk, frame = pcall(self.ports.screenFullFrame, screen)
  if not identityOk or not identity or not frameOk or not frame then
    return nil
  end
  return { identity = identity, frame = self.geometry.copyFrame(frame) }
end

function WindowActions:windowScreenSnapshot(window)
  local ok, screen = pcall(self.ports.windowScreen, window)
  if not ok or not screen then
    return nil
  end
  return self:screenSnapshot(screen)
end

function WindowActions:screenSnapshotIsCurrent(snapshot)
  if not snapshot then
    return false
  end
  for _, screen in ipairs(self.ports.allScreens()) do
    local current = self:screenSnapshot(screen)
    if current and current.identity == snapshot.identity and self.geometry.framesEqual(current.frame, snapshot.frame) then
      return true
    end
  end
  return false
end

function WindowActions:setFrameAndRead(window, frame)
  local setOk = pcall(self.ports.setWindowFrame, window, frame)
  if not setOk then
    return nil, "The window could not be changed", false
  end
  local frameOk, actualFrame = pcall(self.ports.windowFrame, window)
  if not frameOk or not actualFrame then
    return nil, "The window frame could not be verified", true
  end
  return self.geometry.copyFrame(actualFrame), nil, false
end

function WindowActions:setFrameExactly(window, targetFrame, currentFrame, description)
  local actualFrame, message, invalidated = self:setFrameAndRead(window, targetFrame)
  if not actualFrame then
    return nil, message, invalidated
  end
  if self.geometry.framesEqual(currentFrame, actualFrame) then
    return nil, "The window did not accept " .. description, false
  end
  if self.geometry.framesEqual(actualFrame, targetFrame) then
    return actualFrame, nil, false
  end
  local rollbackFrame = self:setFrameAndRead(window, currentFrame)
  if not rollbackFrame or not self.geometry.framesEqual(rollbackFrame, currentFrame) then
    return nil, "The window changed but could not restore " .. description .. " exactly", true
  end
  return nil, "The window could not restore " .. description .. " exactly", false
end

function WindowActions:applyFrame(window, frame, label, options)
  local idOk, windowId = pcall(self.ports.windowId, window)
  if not idOk or not windowId then
    return failure("The target window is no longer available")
  end
  local currentScreen = self:windowScreenSnapshot(window)
  if not currentScreen then
    return failure("The window screen could not be verified")
  end
  local frameOk, currentFrame = pcall(self.ports.windowFrame, window)
  if not frameOk or not currentFrame then
    return failure("The target window is no longer available")
  end

  local targetFrame
  if options and options.clampToScreen == false then
    targetFrame = self.geometry.copyFrame(frame)
  else
    local screenOk, screen = pcall(self.ports.windowScreen, window)
    local screenFrameOk, screenFrame = false, nil
    if screenOk then
      screenFrameOk, screenFrame = pcall(self.ports.screenFrame, screen)
    end
    if not screenFrameOk or not screenFrame then
      return failure("The window screen could not be verified")
    end
    targetFrame =
      self.geometry.clampFrameToScreen(frame, screenFrame, self.config.minimumWidth, self.config.minimumHeight, options and options.allowBelowMinimum)
  end

  local actualFrame, changed = currentFrame, false
  if not self.geometry.framesEqual(currentFrame, targetFrame) then
    local message, invalidated
    if options and options.requireExact then
      actualFrame, message, invalidated = self:setFrameExactly(window, targetFrame, currentFrame, options.frameDescription or "the requested frame")
    else
      actualFrame, message, invalidated = self:setFrameAndRead(window, targetFrame)
    end
    if invalidated then
      self.history:clear(windowId)
    end
    if not actualFrame then
      return failure(message)
    end
    if self.geometry.framesEqual(currentFrame, actualFrame) then
      return failure("The window did not accept that change")
    end
    self.history:record(windowId, currentFrame, actualFrame, currentScreen)
    changed = true
  end

  local status = label
  if options and options.showSize then
    status = string.format("%s (%d x %d)", label, self.geometry.round(actualFrame.w), self.geometry.round(actualFrame.h))
  end
  if not changed then
    status = "No change — " .. status
  end
  return true, nil, status
end

function WindowActions:resetSessionFrame()
  local state = self.modalState
  if not state.active or not state.sessionInitialFrame or not state.sessionInitialScreen then
    return failure("No active window session to reset")
  end
  if not self:screenSnapshotIsCurrent(state.sessionInitialScreen) then
    return failure("The screen configuration changed; session reset is unavailable")
  end
  local window, message = self:getFocusedWindow()
  if not window then
    return failure(message)
  end
  return self:applyFrame(window, self.geometry.copyFrame(state.sessionInitialFrame), "Reset session", {
    showSize = true,
    clampToScreen = false,
    requireExact = true,
    frameDescription = "the session frame",
  })
end

function WindowActions:undoLastFrame()
  local window, message = self:getFocusedWindow()
  if not window then
    return failure(message)
  end
  local idOk, windowId = pcall(self.ports.windowId, window)
  if not idOk or not windowId then
    return failure("The target window is no longer available")
  end
  local entry = self.history:last(windowId)
  if not entry then
    return failure("Nothing to undo for this window")
  end
  local frameOk, currentFrame = pcall(self.ports.windowFrame, window)
  if not frameOk or not currentFrame then
    self.history:clear(windowId)
    return failure("The target window is no longer available")
  end
  if not self.geometry.framesEqual(currentFrame, entry.after) then
    self.history:clear(windowId)
    return failure("Undo history was reset because the window changed outside WI")
  end
  if not self:screenSnapshotIsCurrent(entry.beforeScreen) then
    return failure("The screen configuration changed; the previous frame is unavailable")
  end
  local restoredFrame = self.geometry.copyFrame(entry.before)
  if self.geometry.framesEqual(currentFrame, restoredFrame) then
    self.history:clear(windowId)
    return failure("The previous window position is no longer available")
  end
  local actualFrame, failureMessage, invalidated = self:setFrameExactly(window, restoredFrame, currentFrame, "the previous frame")
  if invalidated then
    self.history:clear(windowId)
  end
  if not actualFrame then
    return failure(failureMessage)
  end
  self.history:acceptRestore(windowId, actualFrame)
  return true, nil, string.format("Undid last action (%d x %d)", self.geometry.round(actualFrame.w), self.geometry.round(actualFrame.h))
end

function WindowActions:applyAspectPreset(preset)
  local window, message = self:getFocusedWindow()
  if not window then
    return failure(message)
  end
  local currentFrame = self.ports.windowFrame(window)
  local screen = self.ports.windowScreen(window)
  local target = self.geometry.aspectTarget(currentFrame, self.ports.screenFrame(screen), preset, self.config.minimumWidth, self.config.minimumHeight)
  return self:applyFrame(window, target, "Aspect " .. preset.label, { showSize = true, allowBelowMinimum = true })
end

function WindowActions:applyWidthPreset(width)
  local window, message = self:getFocusedWindow()
  if not window then
    return failure(message)
  end
  local currentFrame = self.ports.windowFrame(window)
  return self:applyFrame(window, { x = currentFrame.x, y = currentFrame.y, w = width, h = currentFrame.h }, string.format("Width %d px", width), {
    showSize = true,
  })
end

function WindowActions:applyHeightPreset(height)
  local window, message = self:getFocusedWindow()
  if not window then
    return failure(message)
  end
  local frame = self.ports.windowFrame(window)
  return self:applyFrame(window, { x = frame.x, y = frame.y, w = frame.w, h = height }, string.format("Height %d px", height), {
    showSize = true,
  })
end

function WindowActions:moveToCorner(corner)
  local window, message = self:getFocusedWindow()
  if not window then
    return failure(message)
  end
  local frame = self.ports.windowFrame(window)
  local screen = self.ports.windowScreen(window)
  local target = self.geometry.cornerTarget(frame, self.ports.screenFrame(screen), corner)
  if not target then
    return failure("Unknown corner: " .. tostring(corner))
  end
  return self:applyFrame(window, target, "Move to " .. string.lower(self.cornerLabels[corner] or corner))
end

function WindowActions:resize(deltaWidth, deltaHeight, label)
  local window, message = self:getFocusedWindow()
  if not window then
    return failure(message)
  end
  local frame = self.ports.windowFrame(window)
  return self:applyFrame(window, self.geometry.resizeTarget(frame, deltaWidth, deltaHeight), label, { showSize = true })
end

function WindowActions:moveByStep(direction)
  local window, message = self:getFocusedWindow()
  if not window then
    return failure(message)
  end
  local frame = self.ports.windowFrame(window)
  local screen = self.ports.windowScreen(window)
  local target = self.geometry.stepTarget(frame, self.ports.screenFrame(screen), self.config.moveStep, direction)
  if not target then
    return failure("Unknown move direction: " .. tostring(direction))
  end
  return self:applyFrame(window, target, string.format("Move %s %d px", direction, self.config.moveStep))
end

function WindowActions:forgetWindow(window)
  local ok, windowId = pcall(self.ports.windowId, window)
  if ok and windowId then
    self.history:clear(windowId)
  end
end

return WindowActions
