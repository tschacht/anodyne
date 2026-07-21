local ObsCrop = require("Anodyne.core.obs_crop")

local Controller = {}
Controller.__index = Controller

local captureSources = {
  screen = true,
  window = true,
}

local function copyRect(rect)
  return { x = rect.x, y = rect.y, w = rect.w, h = rect.h }
end

local function sameRect(left, right)
  return left and right and left.x == right.x and left.y == right.y and left.w == right.w and left.h == right.h
end

local function call(port, ...)
  local ok, first, second = pcall(port, ...)
  if not ok or first == false or first == nil then
    return false, second or first
  end
  return true, first, second
end

function Controller.new(options)
  options = options or {}
  return setmetatable({
    config = options.config,
    crop = options.crop or ObsCrop,
    ports = options.ports,
    view = options.view,
    state = { kind = "inactive" },
    nextGeneration = 0,
  }, Controller)
end

function Controller:currentState()
  return self.state
end

function Controller:isActive()
  return self.state.kind == "active"
end

function Controller:isApplicationCurrent()
  local ok, current = pcall(self.ports.currentGeneration)
  return ok and current == true
end

function Controller:isCurrentSession(expectedGeneration)
  return self:isApplicationCurrent() and expectedGeneration ~= nil and self:isActive() and self.state.generation == expectedGeneration
end

function Controller:alert(status, duration, source)
  local text = self.view:statusText(status, source)
  pcall(self.ports.alert, text, duration)
end

function Controller:inactiveFailure(status)
  self:alert(status)
  return false, status
end

function Controller:readScreen(screen)
  local identityOk, identity = call(self.ports.screenIdentity, screen)
  local frameOk, fullFrame = call(self.ports.screenFullFrame, screen)
  if not identityOk or not frameOk or not self.crop.validateRect(fullFrame, "screen").ok then
    return nil, "screen"
  end
  local scaleOk, screenScale = call(self.ports.screenScale, screen)
  if not scaleOk or not self.crop.validateScale(screenScale).ok then
    return nil, "scale"
  end
  return { identity = identity, fullFrame = copyRect(fullFrame), scale = screenScale }
end

function Controller:enter()
  if not self:isApplicationCurrent() then
    return false, { kind = "stale-generation" }
  end
  if self:isActive() then
    return false, { kind = "already-active" }, self.state.generation
  end

  local selectedOk, window = call(self.ports.selectWindow)
  if not selectedOk then
    return self:inactiveFailure({ kind = "target-unavailable" })
  end
  local idOk, windowId = call(self.ports.windowId, window)
  local frameOk, frame = call(self.ports.windowFrame, window)
  local screenOk, screen = call(self.ports.windowScreen, window)
  if not idOk or not frameOk or not screenOk then
    return self:inactiveFailure({ kind = "target-unavailable" })
  end
  local frameValidation = self.crop.validateRect(frame, "guide")
  if not frameValidation.ok then
    self:alert(frameValidation.error)
    return false, frameValidation.error
  end
  local screenSnapshot = self:readScreen(screen)
  if not screenSnapshot then
    return self:inactiveFailure({ kind = "stale-geometry" })
  end

  local override = self.config.obsCrop.scaleOverride
  local chosenScale = override > 0 and override or screenSnapshot.scale
  local scaleValidation = self.crop.validateScale(chosenScale)
  if not scaleValidation.ok then
    self:alert(scaleValidation.error)
    return false, scaleValidation.error
  end

  local guideFrame = copyRect(frame)
  local captureSource = "screen"
  local help = self.view:compositionHelpText({ width = guideFrame.w, height = guideFrame.h }, nil, captureSource)
  local rendered = call(self.ports.renderGuide, screen, screenSnapshot.fullFrame, guideFrame, help)
  if not rendered then
    self:alert("Composition Mode could not start")
    return false, { kind = "render-failed" }
  end

  self.nextGeneration = self.nextGeneration + 1
  self.state = {
    kind = "active",
    window = window,
    windowId = windowId,
    guideFrame = guideFrame,
    screenIdentity = screenSnapshot.identity,
    screenFullFrame = screenSnapshot.fullFrame,
    screenScale = screenSnapshot.scale,
    scale = chosenScale,
    captureSource = captureSource,
    generation = self.nextGeneration,
  }
  return true, self.state.generation
end

function Controller:selectSource(source, expectedGeneration)
  if not captureSources[source] then
    return false, { code = "invalid-source", source = source }
  end
  if not self:isCurrentSession(expectedGeneration) then
    return false, { kind = "stale-generation" }
  end
  if self.state.captureSource == source then
    return true
  end

  local state = self.state
  local help = self.view:compositionHelpText({ width = state.guideFrame.w, height = state.guideFrame.h }, nil, source)
  local presented = call(self.ports.refreshPresentation, help)
  if not presented then
    return false, { kind = "presentation-failed" }
  end
  state.captureSource = source
  return true
end

function Controller:teardown(status, successText)
  local closed = call(self.ports.close)
  if not closed then
    self:alert("Composition Mode could not close; retry the action")
    return false, { kind = "teardown-failed" }
  end
  self.state = { kind = "inactive" }
  if successText then
    self:alert(successText, self.config.obsCrop.resultDuration)
  elseif status then
    self:alert(status)
  end
  return true
end

function Controller:cancel(expectedGeneration, status)
  if not self:isCurrentSession(expectedGeneration) then
    return false, { kind = "stale-generation" }
  end
  return self:teardown(status)
end

function Controller:crossMode(expectedGeneration)
  if not self:isApplicationCurrent() then
    return false, { kind = "stale-generation" }
  end
  if not self:isActive() then
    return true
  end
  if expectedGeneration ~= nil and expectedGeneration ~= self.state.generation then
    return false, { kind = "stale-generation" }
  end
  return self:teardown()
end

function Controller:onDestroyed(window, expectedGeneration)
  if not self:isCurrentSession(expectedGeneration) or window ~= self.state.window then
    return false
  end
  return self:teardown({ kind = "stale-target" })
end

function Controller:cancelStale(status)
  return self:teardown(status)
end

function Controller:finish(expectedGeneration)
  if not self:isCurrentSession(expectedGeneration) then
    return false, { kind = "stale-generation" }
  end
  local state = self.state
  local idOk, windowId = call(self.ports.windowId, state.window)
  if not idOk or windowId ~= state.windowId then
    return self:cancelStale({ kind = "stale-target" })
  end
  local finalFrame
  if state.captureSource == "window" then
    local frameOk
    frameOk, finalFrame = call(self.ports.windowFrame, state.window)
    if not frameOk then
      return self:cancelStale({ kind = "stale-target" })
    end
  end
  local screenOk, screen = call(self.ports.windowScreen, state.window)
  if not screenOk then
    return self:cancelStale({ kind = "stale-target" })
  end
  local currentScreen, staleKind = self:readScreen(screen)
  if staleKind == "scale" then
    return self:cancelStale({ kind = "stale-scale" })
  end
  if not currentScreen or currentScreen.identity ~= state.screenIdentity or not sameRect(currentScreen.fullFrame, state.screenFullFrame) then
    return self:cancelStale({ kind = "stale-screen" })
  end
  if currentScreen.scale ~= state.screenScale then
    return self:cancelStale({ kind = "stale-scale" })
  end

  local sourceFrame = state.captureSource == "screen" and state.screenFullFrame or finalFrame
  local result = self.crop.calculate(sourceFrame, state.guideFrame, state.scale)
  if not result.ok then
    if result.error.code == "outside_final" then
      self:alert(result.error, nil, state.captureSource)
      return false, result.error
    end
    return self:cancelStale(result.error)
  end

  local output = self.view:cropClipboardText(result)
  local copied = call(self.ports.copy, output)
  if not copied then
    self:alert({ kind = "copy-failed" })
    return false, { kind = "copy-failed" }
  end
  return self:teardown(nil, self.view:cropResultText(result, state.captureSource))
end

return Controller
