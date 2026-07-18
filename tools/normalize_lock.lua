local path, provided_lua = arg[1], arg[2]
if not path or not provided_lua then
  io.stderr:write("usage: normalize_lock.lua LOCKFILE PROVIDED_LUA_VERSION\n")
  os.exit(2)
end

local input = assert(io.open(path, "r"))
local contents = input:read("*a")
input:close()

local escaped = provided_lua:gsub("([^%w])", "%%%1")
local normalized, removed = contents:gsub('\n%s+lua = "' .. escaped .. '",', "", 1)
if removed ~= 1 then
  io.stderr:write("expected exactly one VM-provided Lua pin in initial lock\n")
  os.exit(1)
end

local temporary = path .. ".normalize"
local output = assert(io.open(temporary, "w"))
output:write(normalized)
output:close()
assert(os.rename(temporary, path))
