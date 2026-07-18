local lock_path = assert(arg[1], "usage: check_lock.lua LOCKFILE")
local chunk, load_error = loadfile(lock_path, "t", {})
if not chunk then
  io.stderr:write("invalid lockfile: " .. tostring(load_error) .. "\n")
  os.exit(1)
end

local ok, lock = pcall(chunk)
if not ok or type(lock) ~= "table" then
  io.stderr:write("invalid lockfile contents\n")
  os.exit(1)
end

local expected = {}
for _, group in ipairs({ "dependencies", "build_dependencies", "test_dependencies" }) do
  for name, version in pairs(lock[group] or {}) do
    if name ~= "lua" then
      expected[name] = version
    end
  end
end

local installed = {}
for line in io.lines() do
  local name, version = line:match("^(%S+)%s+(%S+)")
  if name and name ~= "anodyne-test-tools" then
    installed[name] = version
  end
end

local failed = false
for name, version in pairs(expected) do
  if installed[name] ~= version then
    io.stderr:write(string.format("locked rock mismatch: %s expected %s, installed %s\n", name, version, installed[name] or "missing"))
    failed = true
  end
end
for name, version in pairs(installed) do
  if not expected[name] then
    io.stderr:write(string.format("installed rock is not locked: %s %s\n", name, version))
    failed = true
  end
end

os.exit(failed and 1 or 0)
