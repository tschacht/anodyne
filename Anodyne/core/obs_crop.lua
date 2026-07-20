local ObsCrop = {}

-- Native frame values can differ by tiny floating-point residues. This tolerance
-- is used only when deciding containment; crop conversion remains integer exact.
ObsCrop.POINT_TOLERANCE = 0.01

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function failure(code, details)
  local err = { code = code }
  for key, value in pairs(details or {}) do
    err[key] = value
  end
  return { ok = false, error = err }
end

local function round(value)
  return math.floor(value + 0.5)
end

function ObsCrop.validateRect(rect, name)
  local rectName = name or "rect"
  if type(rect) ~= "table" then
    return failure("invalid_rect", { rect = rectName })
  end

  for _, field in ipairs({ "x", "y", "w", "h" }) do
    if not isFiniteNumber(rect[field]) then
      return failure("invalid_rect", { rect = rectName, field = field })
    end
  end

  if rect.w <= 0 then
    return failure("invalid_rect", { rect = rectName, field = "w" })
  end
  if rect.h <= 0 then
    return failure("invalid_rect", { rect = rectName, field = "h" })
  end

  return { ok = true }
end

function ObsCrop.validateScale(scale)
  if not isFiniteNumber(scale) or scale <= 0 then
    return failure("invalid_scale")
  end
  return { ok = true }
end

function ObsCrop.contain(finalRect, guideRect)
  local finalValidation = ObsCrop.validateRect(finalRect, "final")
  if not finalValidation.ok then
    return finalValidation
  end
  local guideValidation = ObsCrop.validateRect(guideRect, "guide")
  if not guideValidation.ok then
    return guideValidation
  end

  local tolerance = ObsCrop.POINT_TOLERANCE
  local finalRight = finalRect.x + finalRect.w
  local finalBottom = finalRect.y + finalRect.h
  local guideRight = guideRect.x + guideRect.w
  local guideBottom = guideRect.y + guideRect.h

  if guideRect.x < finalRect.x - tolerance then
    return failure("outside_final", { edge = "left" })
  end
  if guideRect.y < finalRect.y - tolerance then
    return failure("outside_final", { edge = "top" })
  end
  if guideRight > finalRight + tolerance then
    return failure("outside_final", { edge = "right" })
  end
  if guideBottom > finalBottom + tolerance then
    return failure("outside_final", { edge = "bottom" })
  end

  local contained = { x = guideRect.x, y = guideRect.y, w = guideRect.w, h = guideRect.h }
  if contained.x < finalRect.x then
    contained.x = finalRect.x
  elseif contained.x + contained.w > finalRight then
    contained.x = finalRight - contained.w
  end
  if contained.y < finalRect.y then
    contained.y = finalRect.y
  elseif contained.y + contained.h > finalBottom then
    contained.y = finalBottom - contained.h
  end

  return { ok = true, rect = contained }
end

function ObsCrop.toPixelRect(rect, scale)
  local rectValidation = ObsCrop.validateRect(rect)
  if not rectValidation.ok then
    return rectValidation
  end
  local scaleValidation = ObsCrop.validateScale(scale)
  if not scaleValidation.ok then
    return scaleValidation
  end

  return {
    ok = true,
    rect = {
      x = round(rect.x * scale),
      y = round(rect.y * scale),
      w = round(rect.w * scale),
      h = round(rect.h * scale),
    },
  }
end

function ObsCrop.calculate(finalRect, guideRect, scale)
  local scaleValidation = ObsCrop.validateScale(scale)
  if not scaleValidation.ok then
    return scaleValidation
  end

  local containment = ObsCrop.contain(finalRect, guideRect)
  if not containment.ok then
    return containment
  end

  local guide = containment.rect
  local sourceWidth = round(finalRect.w * scale)
  local sourceHeight = round(finalRect.h * scale)
  local resultWidth = round(guide.w * scale)
  local resultHeight = round(guide.h * scale)
  if resultWidth > sourceWidth then
    return failure("outside_final", { edge = guide.x < finalRect.x and "left" or "right" })
  end
  if resultHeight > sourceHeight then
    return failure("outside_final", { edge = guide.y < finalRect.y and "top" or "bottom" })
  end

  local left = round((guide.x - finalRect.x) * scale)
  local top = round((guide.y - finalRect.y) * scale)
  if left < 0 then
    return failure("outside_final", { edge = "left" })
  end
  if top < 0 then
    return failure("outside_final", { edge = "top" })
  end
  if left + resultWidth > sourceWidth then
    return failure("outside_final", { edge = "right" })
  end
  if top + resultHeight > sourceHeight then
    return failure("outside_final", { edge = "bottom" })
  end

  return {
    ok = true,
    left = left,
    top = top,
    right = sourceWidth - left - resultWidth,
    bottom = sourceHeight - top - resultHeight,
    sourceWidth = sourceWidth,
    sourceHeight = sourceHeight,
    resultWidth = resultWidth,
    resultHeight = resultHeight,
    scale = scale,
  }
end

return ObsCrop
