local Anodyne = {}

local DefaultConfig = require("Anodyne.config")
local DefaultGeometry = require("Anodyne.core.geometry")
local HammerspoonAdapter = require("Anodyne.adapter.hammerspoon")

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

local private = setmetatable({}, { __mode = "k" })
local Instance = {}
Instance.__index = Instance

local function appendError(errors, context, value)
  errors[#errors + 1] = context .. ": " .. tostring(value)
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
  local generation = {
    current = function()
      return data.generation == token
    end,
  }
  local ok, startupError
  if data.runtimeFactory then
    ok, startupError = pcall(data.runtimeFactory, self, data.hs, data.config, generation, data.geometry, data.metadata)
  else
    data.adapter = HammerspoonAdapter.new({
      owner = self,
      hs = data.hs,
      config = data.config,
      geometry = data.geometry,
      metadata = data.metadata,
      currentGeneration = generation.current,
    })
    ok, startupError = pcall(data.adapter.start, data.adapter)
  end
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
  if not data.adapter then
    data.adapter = HammerspoonAdapter.new({ owner = self })
  end
  local errors = data.adapter:stop()
  if errors then
    data.state = "faulted"
    return self, errors
  end
  data.state = "stopped"
  data.adapter = nil
  return self, nil
end

function Anodyne.new(options)
  validateOptions("new", options, { hs = true, config = true, modules = true })
  if options.modules ~= nil and type(options.modules) ~= "table" then
    error("new.modules must be a table", 2)
  end
  local runtimeFactory
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
    adapter = nil,
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
    local legacyErrors = HammerspoonAdapter.cleanupLegacy(legacy)
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
