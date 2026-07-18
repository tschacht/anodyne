local Prior = {}

function Prior.snapshot(anodyne, legacy)
  if legacy ~= nil and legacy ~= anodyne then
    return nil, "legacy global differs from modern global"
  end
  if anodyne == nil then
    return { anodyne = nil, legacy = legacy, running = false }
  end
  if type(anodyne.start) ~= "function" or type(anodyne.stop) ~= "function" or type(anodyne.isRunning) ~= "function" then
    return nil, "prior instance lifecycle is incomplete"
  end
  local ok, running = pcall(function()
    return anodyne:isRunning()
  end)
  if not ok or type(running) ~= "boolean" then
    return nil, "prior running state is unprovable"
  end
  return { anodyne = anodyne, legacy = legacy, running = running }
end

function Prior.stop(snapshot)
  if not snapshot.running then
    return true
  end
  local ok, _, errors = pcall(function()
    return snapshot.anodyne:stop()
  end)
  if not ok or errors ~= nil then
    return false, ok and "prior stop returned errors" or tostring(_)
  end
  local stateOk, running = pcall(function()
    return snapshot.anodyne:isRunning()
  end)
  if not stateOk or running ~= false then
    return false, "prior stop state is unprovable"
  end
  return true
end

function Prior.restore(snapshot)
  if snapshot.anodyne == nil then
    return true
  end
  if snapshot.running then
    local ok = pcall(function()
      snapshot.anodyne:start()
    end)
    if not ok then
      return false, "prior start failed"
    end
  end
  local stateOk, running = pcall(function()
    return snapshot.anodyne:isRunning()
  end)
  if not stateOk or running ~= snapshot.running then
    return false, "prior state restoration is unprovable"
  end
  return true
end

return Prior
