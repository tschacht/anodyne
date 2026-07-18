local options = {
  report = "coverage/luacov.report.out",
  source_root = "Anodyne",
  summary = "coverage/summary.json",
}
local index = 1
while index <= #arg do
  local option, value = arg[index], arg[index + 1]
  if option == "--milestone" then
    options.milestone = tonumber(value)
  elseif option == "--report" then
    options.report = value
  elseif option == "--source-root" then
    options.source_root = value
  elseif option == "--summary" then
    options.summary = value
  else
    io.stderr:write("unknown or incomplete option: " .. tostring(option) .. "\n")
    os.exit(2)
  end
  index = index + 2
end

local milestone = options.milestone
if not milestone or milestone < 1 or milestone > 7 or milestone % 1 ~= 0 then
  io.stderr:write("usage: check_coverage.lua --milestone N [--report PATH] [--summary PATH] [--source-root PATH]\n")
  os.exit(2)
end

local report_path = options.report
local report = io.open(report_path, "r")
if not report then
  io.stderr:write("coverage report missing: " .. report_path .. "\n")
  os.exit(1)
end
local contents = report:read("*a")
report:close()
if contents == "" then
  io.stderr:write("coverage report is empty\n")
  os.exit(1)
end

local counts = {}
for line in contents:gmatch("[^\n]+") do
  local name, hit, miss = line:match("^%s*(.-%.lua)%s+(%d+)%s+(%d+)%s+[%d.]+%%%s*$")
  if name and name ~= "Total" then
    name = name:gsub("^%./", "")
    counts[name] = { hit = tonumber(hit), miss = tonumber(miss) }
  end
end

local function shell_quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

-- LuaCov should supply these because includeuntestedfiles is enabled. An
-- on-disk production source omitted from its report is a configuration defect,
-- not a zero-line file, and therefore fails every milestone.
local source_scan = io.popen("find " .. shell_quote(options.source_root) .. " -type f -name '*.lua' -print 2>/dev/null", "r")
if source_scan then
  for name in source_scan:lines() do
    local normalized = name:match("(Anodyne/.*%.lua)$")
    if normalized and not counts[normalized] then
      counts[normalized] = { hit = 0, miss = 0, omitted = true }
    end
  end
  source_scan:close()
end

local failed = false
local function require_file(path, floor)
  local value = counts[path]
  if not value then
    io.stderr:write("coverage missing expected production file: " .. path .. "\n")
    failed = true
    return
  end
  local executable = value.hit + value.miss
  local ratio = executable == 0 and 0 or value.hit / executable
  io.write(string.format("%s: %d/%d (raw %.8f)\n", path, value.hit, executable, ratio))
  if value.omitted then
    io.stderr:write("coverage omitted on-disk production file: " .. path .. "\n")
    failed = true
  end
  if floor and ratio < floor then
    io.stderr:write(string.format("coverage below floor for %s: %.8f < %.8f\n", path, ratio, floor))
    failed = true
  end
end

if milestone >= 4 then
  require_file("Anodyne/config.lua", 0.95)
  require_file("Anodyne/core/geometry.lua", 0.95)
end
if milestone >= 5 then
  require_file("Anodyne/core/history.lua", 0.95)
  require_file("Anodyne/window_actions.lua", 0.90)
end
if milestone >= 6 then
  require_file("Anodyne/core/keymap.lua", 0.95)
  require_file("Anodyne/controller.lua", 0.90)
  require_file("Anodyne/view.lua", 0.85)
end
if milestone >= 7 then
  require_file("Anodyne/adapter/hammerspoon.lua", 0.75)
end

local names = {}
for name in pairs(counts) do
  if name == "init.lua" or name:match("^Anodyne/.*%.lua$") then
    table.insert(names, name)
  end
end
table.sort(names)

local total_hit, total_executable = 0, 0
local anodyne_hit, anodyne_executable = 0, 0
for _, name in ipairs(names) do
  local value = counts[name]
  total_hit = total_hit + value.hit
  total_executable = total_executable + value.hit + value.miss
  if name:match("^Anodyne/") then
    anodyne_hit = anodyne_hit + value.hit
    anodyne_executable = anodyne_executable + value.hit + value.miss
  end
end

if milestone >= 7 then
  local overall = anodyne_executable == 0 and 0 or anodyne_hit / anodyne_executable
  io.write(string.format("Anodyne/**: %d/%d (raw %.8f)\n", anodyne_hit, anodyne_executable, overall))
  if overall < 0.85 then
    io.stderr:write(string.format("overall Anodyne coverage below floor: %.8f < 0.85000000\n", overall))
    failed = true
  end
end

local function json_string(value)
  return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
end

for _, name in ipairs(names) do
  if counts[name].omitted then
    io.stderr:write("coverage omitted on-disk production file: " .. name .. "\n")
    failed = true
  end
end

local summary = assert(io.open(options.summary, "w"))
summary:write('{"milestone":', milestone, ',"files":{')
for index, name in ipairs(names) do
  local value = counts[name]
  local executable = value.hit + value.miss
  local ratio = executable == 0 and 0 or value.hit / executable
  if index > 1 then
    summary:write(",")
  end
  summary:write(json_string(name), ':{"hit":', value.hit, ',"missed":', value.miss, ',"ratio":', string.format("%.17g", ratio), "}")
end
summary:write(
  '},"totals":{"hit":',
  total_hit,
  ',"executable":',
  total_executable,
  '},"anodyne":{"hit":',
  anodyne_hit,
  ',"executable":',
  anodyne_executable,
  "}}\n"
)
summary:close()

os.exit(failed and 1 or 0)
