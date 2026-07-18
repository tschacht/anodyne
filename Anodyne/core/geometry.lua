local Geometry = {}

function Geometry.round(value)
  return math.floor(value + 0.5)
end

function Geometry.clamp(value, minimum, maximum)
  if maximum < minimum then
    return minimum
  end
  return math.max(minimum, math.min(value, maximum))
end

function Geometry.copyFrame(frame)
  return { x = frame.x, y = frame.y, w = frame.w, h = frame.h }
end

function Geometry.framesEqual(first, second)
  return Geometry.round(first.x) == Geometry.round(second.x)
    and Geometry.round(first.y) == Geometry.round(second.y)
    and Geometry.round(first.w) == Geometry.round(second.w)
    and Geometry.round(first.h) == Geometry.round(second.h)
end

function Geometry.clampFrameToScreen(frame, screenFrame, minimumWidth, minimumHeight, allowBelowMinimum)
  local screenWidth = Geometry.round(screenFrame.w)
  local screenHeight = Geometry.round(screenFrame.h)
  local requestedMinimumWidth = allowBelowMinimum and 1 or minimumWidth
  local requestedMinimumHeight = allowBelowMinimum and 1 or minimumHeight
  local actualMinimumWidth = math.min(requestedMinimumWidth, screenWidth)
  local actualMinimumHeight = math.min(requestedMinimumHeight, screenHeight)
  local width = Geometry.clamp(Geometry.round(frame.w), actualMinimumWidth, screenWidth)
  local height = Geometry.clamp(Geometry.round(frame.h), actualMinimumHeight, screenHeight)
  local maxX = Geometry.round(screenFrame.x + screenFrame.w - width)
  local maxY = Geometry.round(screenFrame.y + screenFrame.h - height)
  return {
    x = Geometry.clamp(Geometry.round(frame.x), Geometry.round(screenFrame.x), maxX),
    y = Geometry.clamp(Geometry.round(frame.y), Geometry.round(screenFrame.y), maxY),
    w = width,
    h = height,
  }
end

function Geometry.aspectTarget(frame, screenFrame, preset, minimumWidth, minimumHeight)
  local ratio = preset.width / preset.height
  local minimumWidthForRatio = math.max(minimumWidth, minimumHeight * ratio)
  local maximumWidthForRatio = math.min(screenFrame.w, screenFrame.h * ratio)
  local targetWidth
  if maximumWidthForRatio < minimumWidthForRatio then
    targetWidth = maximumWidthForRatio
  else
    targetWidth = Geometry.clamp(frame.w, minimumWidthForRatio, maximumWidthForRatio)
  end
  return { x = frame.x, y = frame.y, w = targetWidth, h = targetWidth / ratio }
end

function Geometry.cornerTarget(frame, screenFrame, corner)
  local target = Geometry.copyFrame(frame)
  if corner == "topleft" then
    target.x, target.y = screenFrame.x, screenFrame.y
  elseif corner == "centertop" then
    target.x, target.y = screenFrame.x + (screenFrame.w - frame.w) / 2, screenFrame.y
  elseif corner == "topright" then
    target.x, target.y = screenFrame.x + screenFrame.w - frame.w, screenFrame.y
  elseif corner == "bottomleft" then
    target.x, target.y = screenFrame.x, screenFrame.y + screenFrame.h - frame.h
  elseif corner == "centerbottom" then
    target.x = screenFrame.x + (screenFrame.w - frame.w) / 2
    target.y = screenFrame.y + screenFrame.h - frame.h
  elseif corner == "bottomright" then
    target.x = screenFrame.x + screenFrame.w - frame.w
    target.y = screenFrame.y + screenFrame.h - frame.h
  else
    return nil
  end
  return target
end

function Geometry.resizeTarget(frame, deltaWidth, deltaHeight)
  return { x = frame.x, y = frame.y, w = frame.w + deltaWidth, h = frame.h + deltaHeight }
end

function Geometry.snapPosition(origin, current, step, direction)
  local relative = current - origin
  if direction == "left" or direction == "up" then
    return origin + (math.ceil(relative / step) - 1) * step
  elseif direction == "right" or direction == "down" then
    return origin + (math.floor(relative / step) + 1) * step
  end
  return nil
end

function Geometry.stepTarget(frame, screenFrame, step, direction)
  local target = Geometry.copyFrame(frame)
  if direction == "left" or direction == "right" then
    target.x = Geometry.snapPosition(screenFrame.x, frame.x, step, direction)
  elseif direction == "up" or direction == "down" then
    target.y = Geometry.snapPosition(screenFrame.y, frame.y, step, direction)
  else
    return nil
  end
  return target
end

return Geometry
