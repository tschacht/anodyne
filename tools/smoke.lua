local root = assert(..., "Anodyne smoke root is required")
local statusPath = root .. "/coverage/smoke-status.json"
local Status = assert(loadfile(root .. "/tools/smoke_status.lua"))()

local function deferred()
  Status.write(statusPath, "DEFERRED-ENVIRONMENT")
  return "ANODYNE_SMOKE:DEFERRED-ENVIRONMENT"
end

if rawget(_G, "ANODYNE_SMOKE_SAFE") ~= 1 or type(rawget(_G, "hs")) ~= "table" then
  return deferred()
end

local modifiers = { "cmd", "alt", "ctrl", "shift" }
local key = "F20"
local preflightOk, conflict = pcall(function()
  if hs.hotkey.systemAssigned(modifiers, key) or not hs.hotkey.assignable(modifiers, key) then
    return true
  end
  for _, active in ipairs(hs.hotkey.getHotkeys()) do
    if active.idx == "✧F20" then
      return true
    end
  end
  return false
end)
if not preflightOk or conflict then
  return deferred()
end

local priorAnodyne = rawget(_G, "Anodyne")
local Prior = assert(loadfile(root .. "/tools/smoke_prior.lua"))()
local prior = Prior.snapshot(priorAnodyne)
if not prior then
  return deferred()
end

local active
local restored = false
local function restore()
  if active and type(active.stop) == "function" then
    local stopped, _, errors = pcall(function()
      return active:stop()
    end)
    if not stopped or errors ~= nil then
      return false
    end
    local stateOk, running = pcall(function()
      return active:isRunning()
    end)
    if not stateOk or running ~= false then
      return false
    end
    active = nil
  end
  if not Prior.restore(prior) then
    return false
  end
  _G.Anodyne = priorAnodyne
  if rawget(_G, "Anodyne") ~= priorAnodyne then
    return false
  end
  restored = true
  return true
end

-- From this point forward the smoke may mutate prior lifecycle state, globals,
-- or native resources. A timeout or process kill must therefore remain FAIL.
Status.write(statusPath, "FAIL")
local ok, result = xpcall(function()
  local priorStopOk, priorStopError = Prior.stop(prior)
  if not priorStopOk then
    error("prior instance teardown failed: " .. tostring(priorStopError))
  end

  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
  package.loaded.Anodyne = nil
  local facade = require("Anodyne")
  local config = {
    menuTitle = "ANODYNE-SMOKE",
    modalHotkey = { modifiers = modifiers, key = key },
  }
  active = facade.replace({ hs = hs, config = config })
  _G.Anodyne = active
  local first = active
  active = facade.replace({ hs = hs, previous = first, config = config })
  _G.Anodyne = active
  local _, errors = active:stop()
  if errors or active:isRunning() then
    error("replacement instance did not stop cleanly")
  end
  active = nil
  if not restore() then
    error("prior instance restoration failed")
  end
  return true
end, debug.traceback)

if not restored and not restore() then
  ok = false
  result = tostring(result) .. "\nprior instance restoration failed"
end
if not ok then
  error(result)
end
Status.write(statusPath, "PASS")
return "ANODYNE_SMOKE:PASS"
