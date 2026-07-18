local root = assert(..., "Anodyne smoke root is required")
local priorFlag = rawget(_G, "ANODYNE_SMOKE_SAFE")
_G.ANODYNE_SMOKE_SAFE = 1
local ok, result = xpcall(function()
  return assert(loadfile(root .. "/tools/smoke.lua"))(root)
end, debug.traceback)
_G.ANODYNE_SMOKE_SAFE = priorFlag
if not ok then
  error(result)
end
return result
