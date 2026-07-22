local Config = {}

local DEFAULTS = {
  menuTitle = "WI",
  menuFailureDuration = 2,
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
  compositionHotkey = {
    modifiers = { "ctrl", "alt", "cmd" },
    key = "c",
  },
  obsCrop = {
    scaleOverride = 0,
    resultDuration = 4,
    dimAlpha = 0.45,
    guideStrokeWidth = 1,
    liveRefreshInterval = 0.1,
  },
  exactPresets = {
    { width = 2560, height = 1440 },
    { width = 1920, height = 1080 },
  },
  aspectPresets = {
    { label = "16:9", width = 16, height = 9 },
    { label = "4:3", width = 4, height = 3 },
    { label = "3:2", width = 3, height = 2 },
    { label = "2:1", width = 2, height = 1 },
    { label = "3:1", width = 3, height = 1 },
  },
  widthPresets = { 1000, 1200, 1400, 1600, 1800, 2000, 2200, 2400 },
  heightPresets = { 600, 700, 800, 1000, 1200, 1400, 1500, 1600 },
  growStep = 50,
  moveStep = 50,
  shortMoveStep = 5,
  undoDepth = 3,
}

local function isList(value)
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      return false
    end
    count = count + 1
  end
  return count == #value
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
end

local merge

local function validateList(value, expected, path)
  if not isList(value) then
    error("invalid config type for " .. path .. ": expected list", 4)
  end
  local exemplar = expected[1]
  for index, child in ipairs(value) do
    if exemplar ~= nil and type(child) ~= type(exemplar) then
      error("invalid config type for " .. path .. "[" .. index .. "]: expected " .. type(exemplar), 4)
    end
    if type(exemplar) == "table" and not isList(exemplar) then
      merge(exemplar, child, path .. "[" .. index .. "]")
    end
  end
end

merge = function(defaults, overrides, path)
  local result = copy(defaults)
  if overrides == nil then
    return result
  end
  for key, value in pairs(overrides) do
    local expected = defaults[key]
    local name = path == "" and tostring(key) or (path .. "." .. tostring(key))
    if expected == nil then
      error("unknown config key: " .. name, 3)
    end
    if type(value) ~= type(expected) then
      error("invalid config type for " .. name .. ": expected " .. type(expected), 3)
    end
    if type(expected) == "table" and not isList(expected) then
      result[key] = merge(expected, value, name)
    else
      if type(expected) == "table" then
        validateList(value, expected, name)
      end
      result[key] = copy(value)
    end
  end
  return result
end

local function freeze(value)
  if type(value) ~= "table" then
    return value
  end
  local backing = {}
  for key, child in pairs(value) do
    backing[key] = freeze(child)
  end
  return setmetatable({}, {
    __index = backing,
    __newindex = function()
      error("configuration is immutable", 2)
    end,
    __len = function()
      return #backing
    end,
    __pairs = function()
      return next, backing, nil
    end,
    __metatable = false,
  })
end

local function metadata(config)
  local modes = {
    { key = "e", screen = "exact", label = "Exact pixels" },
    { key = "a", screen = "aspect", label = "Aspect" },
    { key = "w", screen = "width", label = "Width" },
    { key = "h", screen = "height", label = "Height" },
    { key = "m", screen = "move", label = "Move" },
    { key = "r", screen = "resize", label = "Resize" },
  }
  local modeByKey = {}
  for _, selector in ipairs(modes) do
    modeByKey[selector.key] = selector.screen
  end
  local moveActions = {
    { key = "left", direction = "left", label = "Move Left", symbol = config.symbols.left },
    { key = "right", direction = "right", label = "Move Right", symbol = config.symbols.right },
    { key = "up", direction = "up", label = "Move Up", symbol = config.symbols.up },
    { key = "down", direction = "down", label = "Move Down", symbol = config.symbols.down },
  }
  local corners = {
    { key = "left", shifted = true, screen = "move", corner = "topleft", label = "Top Left", shortcut = config.symbols.shift .. " + " .. config.symbols.left },
    { key = "c", screen = "move", corner = "centertop", label = "Center Top", shortcut = "C" },
    {
      key = "right",
      shifted = true,
      screen = "move",
      corner = "topright",
      label = "Top Right",
      shortcut = config.symbols.shift .. " + " .. config.symbols.right,
    },
    { key = "left", screen = "move_bottom", corner = "bottomleft", label = "Bottom Left", shortcut = config.symbols.left },
    { key = "c", screen = "move_bottom", corner = "centerbottom", label = "Center Bottom", shortcut = "C" },
    { key = "right", screen = "move_bottom", corner = "bottomright", label = "Bottom Right", shortcut = config.symbols.right },
  }
  local cornerLabelByName = {}
  for _, action in ipairs(corners) do
    cornerLabelByName[action.corner] = action.label
  end
  local step = config.growStep
  local resizeActions = {
    { key = "right", label = "Grow Width", prompt = "grow width", shortcut = config.symbols.right, deltaWidth = step, deltaHeight = 0 },
    { key = "down", label = "Grow Height", prompt = "grow height", shortcut = config.symbols.down, deltaWidth = 0, deltaHeight = step },
    { key = "left", label = "Shrink Width", prompt = "shrink width", shortcut = config.symbols.left, deltaWidth = -step, deltaHeight = 0 },
    { key = "up", label = "Shrink Height", prompt = "shrink height", shortcut = config.symbols.up, deltaWidth = 0, deltaHeight = -step },
    { key = "g", label = "Grow Width + Height", prompt = "grow width + height", shortcut = "G", deltaWidth = step, deltaHeight = step },
    { key = "s", label = "Shrink Width + Height", prompt = "shrink width + height", shortcut = "S", deltaWidth = -step, deltaHeight = -step },
  }
  return freeze({
    modeSelectors = modes,
    modeByKey = modeByKey,
    moveStepActions = moveActions,
    cornerActions = corners,
    cornerLabelByName = cornerLabelByName,
    resizeActions = resizeActions,
    screenTitles = {
      home = "Window mode",
      exact = "Exact pixels",
      aspect = "Aspect preset",
      width = "Width preset",
      height = "Height preset",
      move = "Move",
      move_bottom = "Move bottom positions",
      resize = "Resize",
    },
  })
end

function Config.build(overrides)
  if overrides ~= nil and type(overrides) ~= "table" then
    error("config overrides must be a table", 2)
  end
  local values = merge(DEFAULTS, overrides, "")
  if #values.exactPresets < 1 or #values.exactPresets > 9 then
    error("CONFIG.exactPresets must contain between 1 and 9 presets", 2)
  end
  for index, preset in ipairs(values.exactPresets) do
    for _, dimension in ipairs({ "width", "height" }) do
      local value = preset[dimension]
      if type(value) ~= "number" or value < 1 or value > math.maxinteger or value ~= value or value ~= math.floor(value) then
        error(string.format("CONFIG.exactPresets[%d].%s must be a positive integer", index, dimension), 2)
      end
    end
  end
  if values.undoDepth < 1 or values.undoDepth ~= math.floor(values.undoDepth) then
    error("CONFIG.undoDepth must be a positive integer", 2)
  end
  if values.growStep < 1 or values.growStep == math.huge or values.growStep ~= math.floor(values.growStep) then
    error("CONFIG.growStep must be a positive integer", 2)
  end
  for _, name in ipairs({ "moveStep", "shortMoveStep" }) do
    local value = values[name]
    if value < 1 or value > math.maxinteger or value ~= math.floor(value) then
      error("CONFIG." .. name .. " must be a positive integer", 2)
    end
  end
  if values.compositionHotkey.key == "" then
    error("CONFIG.compositionHotkey.key must not be empty", 2)
  end
  local seenModifiers = {}
  local validModifiers = { ctrl = true, alt = true, cmd = true, shift = true, fn = true }
  for _, modifier in ipairs(values.compositionHotkey.modifiers) do
    if not validModifiers[modifier] or seenModifiers[modifier] then
      error("CONFIG.compositionHotkey.modifiers must contain unique valid modifiers", 2)
    end
    seenModifiers[modifier] = true
  end
  local scaleOverride = values.obsCrop.scaleOverride
  if scaleOverride < 0 or scaleOverride == math.huge or scaleOverride ~= scaleOverride then
    error("CONFIG.obsCrop.scaleOverride must be zero or a finite positive number", 2)
  end
  local resultDuration = values.obsCrop.resultDuration
  if resultDuration <= 0 or resultDuration == math.huge or resultDuration ~= resultDuration then
    error("CONFIG.obsCrop.resultDuration must be a finite positive number", 2)
  end
  local dimAlpha = values.obsCrop.dimAlpha
  if dimAlpha <= 0 or dimAlpha > 1 or dimAlpha ~= dimAlpha then
    error("CONFIG.obsCrop.dimAlpha must be greater than zero and at most one", 2)
  end
  local guideStrokeWidth = values.obsCrop.guideStrokeWidth
  if guideStrokeWidth <= 0 or guideStrokeWidth == math.huge or guideStrokeWidth ~= guideStrokeWidth then
    error("CONFIG.obsCrop.guideStrokeWidth must be a finite positive number", 2)
  end
  local liveRefreshInterval = values.obsCrop.liveRefreshInterval
  if liveRefreshInterval <= 0 or liveRefreshInterval == math.huge or liveRefreshInterval ~= liveRefreshInterval then
    error("CONFIG.obsCrop.liveRefreshInterval must be a finite positive number", 2)
  end
  local frozen = freeze(values)
  return frozen, metadata(frozen)
end

return Config
