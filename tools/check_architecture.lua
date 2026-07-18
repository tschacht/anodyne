local Checker = {}

local expectedPaths = {
  "Anodyne/init.lua",
  "Anodyne/config.lua",
  "Anodyne/window_actions.lua",
  "Anodyne/controller.lua",
  "Anodyne/view.lua",
  "Anodyne/core/geometry.lua",
  "Anodyne/core/history.lua",
  "Anodyne/core/keymap.lua",
  "Anodyne/adapter/hammerspoon.lua",
}

local function join(root, path)
  return root:gsub("/$", "") .. "/" .. path
end

local function shellQuote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function read(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local contents = file:read("*a")
  file:close()
  return contents
end

local function moduleName(path)
  local name = path:gsub("%.lua$", ""):gsub("/init$", ""):gsub("/", ".")
  return name
end

local function add(errors, message)
  errors[#errors + 1] = message
end

local function lexicalSource(source, removeStrings)
  local output, index, length = {}, 1, #source
  local function append(value)
    output[#output + 1] = value
  end
  while index <= length do
    local character = source:sub(index, index)
    local nextTwo = source:sub(index, index + 1)
    if nextTwo == "--" then
      local equals = source:sub(index + 2):match("^%[(=*)%[")
      if equals then
        local close = "]" .. equals .. "]"
        local finish = source:find(close, index + 4 + #equals, true)
        local consumed = finish and (finish + #close - index) or (length - index + 1)
        append(source:sub(index, index + consumed - 1):gsub("[^\n]", " "))
        index = index + consumed
      else
        local finish = source:find("\n", index + 2, true) or (length + 1)
        append(string.rep(" ", finish - index))
        index = finish
      end
    elseif character == '"' or character == "'" then
      local quote, finish = character, index + 1
      while finish <= length do
        local current = source:sub(finish, finish)
        if current == "\\" then
          finish = finish + 2
        elseif current == quote then
          finish = finish + 1
          break
        else
          finish = finish + 1
        end
      end
      local value = source:sub(index, finish - 1)
      append(removeStrings and value:gsub("[^\n]", " ") or value)
      index = finish
    else
      local equals = source:sub(index):match("^%[(=*)%[")
      if equals then
        local close = "]" .. equals .. "]"
        local finish = source:find(close, index + 2 + #equals, true)
        local consumed = finish and (finish + #close - index) or (length - index + 1)
        local value = source:sub(index, index + consumed - 1)
        append(removeStrings and value:gsub("[^\n]", " ") or value)
        index = index + consumed
      else
        append(character)
        index = index + 1
      end
    end
  end
  return table.concat(output)
end

local function longBracket(source, index)
  local equals = source:sub(index):match("^%[(=*)%[")
  if equals == nil then
    return nil
  end
  local contentStart = index + #equals + 2
  local close = "]" .. equals .. "]"
  local closeStart = source:find(close, contentStart, true)
  if not closeStart then
    return nil, #source + 1
  end
  local value = source:sub(contentStart, closeStart - 1)
  if value:sub(1, 2) == "\r\n" then
    value = value:sub(3)
  elseif value:sub(1, 1) == "\n" or value:sub(1, 1) == "\r" then
    value = value:sub(2)
  end
  return value, closeStart + #close
end

local function shortString(source, index)
  local quote = source:sub(index, index)
  if quote ~= '"' and quote ~= "'" then
    return nil
  end
  local finish = index + 1
  while finish <= #source do
    local character = source:sub(finish, finish)
    if character == "\\" then
      finish = finish + 2
    elseif character == quote then
      local literal = source:sub(index, finish)
      local chunk = load("return " .. literal, "architecture require literal", "t", {})
      if not chunk then
        return nil, finish + 1
      end
      local ok, value = pcall(chunk)
      return ok and type(value) == "string" and value or nil, finish + 1
    else
      finish = finish + 1
    end
  end
  return nil, #source + 1
end

local function skipSpaceAndComments(source, index)
  while index <= #source do
    local whitespace = source:sub(index):match("^%s+")
    if whitespace then
      index = index + #whitespace
    elseif source:sub(index, index + 1) == "--" then
      local _, afterLong = longBracket(source, index + 2)
      if afterLong then
        index = afterLong
      else
        index = source:find("\n", index + 2, true) or (#source + 1)
      end
    else
      break
    end
  end
  return index
end

local function requireLiteral(source, index)
  local cursor = skipSpaceAndComments(source, index)
  local depth = 0
  while source:sub(cursor, cursor) == "(" do
    depth = depth + 1
    cursor = skipSpaceAndComments(source, cursor + 1)
  end

  local value, after = shortString(source, cursor)
  if not after then
    value, after = longBracket(source, cursor)
  end
  if not after then
    return nil, cursor, false
  end
  if depth == 0 then
    return value, after, true
  end

  cursor = skipSpaceAndComments(source, after)
  for _ = 1, depth do
    if source:sub(cursor, cursor) ~= ")" then
      return nil, cursor, false
    end
    cursor = skipSpaceAndComments(source, cursor + 1)
  end
  return value, cursor, true
end

local function extractRequires(source)
  local dependencies, index, previousToken = {}, 1, nil
  while index <= #source do
    if source:sub(index, index + 1) == "--" then
      index = skipSpaceAndComments(source, index)
    else
      local _, afterLong = longBracket(source, index)
      local _, afterShort = shortString(source, index)
      if afterLong then
        previousToken = "string"
        index = afterLong
      elseif afterShort then
        previousToken = "string"
        index = afterShort
      else
        local identifier = source:sub(index):match("^([%a_][%w_]*)")
        if identifier then
          local finish = index + #identifier
          if identifier == "require" and previousToken ~= "." and previousToken ~= ":" then
            local value, after, literalOnly = requireLiteral(source, finish)
            local internal = value == "Anodyne" or (value and value:match("^Anodyne%."))
            if internal and literalOnly then
              dependencies[value] = true
            end
            previousToken = literalOnly and "string" or identifier
            index = after > finish and after or finish
          else
            previousToken = identifier
            index = finish
          end
        else
          local character = source:sub(index, index)
          if not character:match("%s") then
            previousToken = character
          end
          index = index + 1
        end
      end
    end
  end
  return dependencies
end

local function hasNativeHsIdentifier(source)
  local sanitized = lexicalSource(source, true)
  local index = 1
  while true do
    local first, last = sanitized:find("%f[%w_]hs%f[^%w_]", index)
    if not first then
      return false
    end
    local previous = sanitized:sub(1, first - 1):match("(%S)%s*$")
    local following = sanitized:sub(last + 1):match("^%s*(.)")
    local property = previous == "." or previous == ":"
    local tableKey = following == "=" and (previous == "{" or previous == ",")
    if not property and not tableKey then
      return true
    end
    index = last + 1
  end
end

local function checkRootMigration(root, errors)
  local source = read(join(root, "init.lua"))
  if not source then
    add(errors, "missing root init.lua")
    return
  end
  local previous = source:find('rawget%(_G, "Anodyne"%)', 1) and source:find('rawget%(_G, "WindowManager"%)', 1)
  local replacement = source:find('require%("Anodyne"%).replace', 1)
  local finalAssignment = source:find("_G%.Anodyne,%s*_G%.WindowManager%s*=%s*nextInstance,%s*nil", 1)
  if not previous or not replacement or not finalAssignment or not (previous < replacement and replacement < finalAssignment) then
    add(errors, "root init.lua must capture both prior globals, replace, then publish Anodyne and clear WindowManager")
  end
end

local function checkCoverageConfiguration(root, errors)
  local source = read(join(root, ".luacov"))
  if not source then
    add(errors, "missing .luacov")
    return
  end
  if not source:find("includeuntestedfiles%s*=%s*true") or not source:find('include%s*=%s*{%s*"%^Anodyne/%.%*%$"') then
    add(errors, ".luacov must count every Anodyne source, including untested files")
  end
end

local function discoverProduction(root)
  local prefix = root:gsub("/$", "") .. "/"
  local scan = io.popen("find " .. shellQuote(join(root, "Anodyne")) .. " -type f -name '*.lua' -print 2>/dev/null", "r")
  if not scan then
    return nil, "could not start production scanner"
  end
  local paths = {}
  for absolute in scan:lines() do
    paths[#paths + 1] = absolute:sub(1, #prefix) == prefix and absolute:sub(#prefix + 1) or absolute
  end
  local ok, reason, code = scan:close()
  if ok ~= true then
    return nil, "production scanner failed: " .. tostring(reason) .. " " .. tostring(code)
  end
  return paths
end

function Checker.check(root, options)
  root = root or "."
  options = options or {}
  local paths = options.expectedPaths or expectedPaths
  local errors, sources, modules, discovered = {}, {}, {}, {}
  local discoveredPaths, discoveryError = (options.discover or discoverProduction)(root)
  if type(discoveredPaths) ~= "table" then
    add(errors, discoveryError or "production scanner returned no path list")
    discoveredPaths = {}
  end
  if #discoveredPaths == 0 then
    add(errors, "production scanner discovered zero Lua sources")
  end
  for _, path in ipairs(discoveredPaths) do
    if path:match("^Anodyne/.*%.lua$") then
      discovered[path] = true
      local source = read(join(root, path))
      if not source then
        add(errors, "discovered production module could not be read: " .. path)
      else
        sources[path] = source
        modules[moduleName(path)] = path
      end
    else
      add(errors, "production scanner returned an invalid path: " .. tostring(path))
    end
  end
  for _, path in ipairs(paths) do
    if not discovered[path] or not sources[path] then
      add(errors, "expected production module was not discovered and analyzed: " .. path)
    end
  end

  if not options.skipRootMigration then
    checkRootMigration(root, errors)
  end
  if not options.skipCoverageConfiguration then
    checkCoverageConfiguration(root, errors)
  end

  local graph = {}
  for module, path in pairs(modules) do
    graph[module] = {}
    local source = sources[path]
    if source:find("_G", 1, true) or source:find("WindowManager", 1, true) then
      add(errors, path .. ": production modules must not access globals or the transitional alias")
    end
    if path ~= "Anodyne/adapter/hammerspoon.lua" and hasNativeHsIdentifier(source) then
      add(errors, path .. ": native hs identifiers are restricted to Anodyne/adapter/hammerspoon.lua")
    end
    for dependency in pairs(extractRequires(source)) do
      graph[module][#graph[module] + 1] = dependency
      if not modules[dependency] then
        add(errors, path .. ": missing required production module " .. dependency)
      end
      if path:match("^Anodyne/core/") and not dependency:match("^Anodyne%.core%.") then
        add(errors, path .. ": core may depend only on other core modules")
      end
    end
  end

  local visiting, visited = {}, {}
  local function visit(module, trail)
    if visiting[module] then
      add(errors, "require cycle: " .. table.concat(trail, " -> ") .. " -> " .. module)
      return
    end
    if visited[module] then
      return
    end
    visiting[module] = true
    trail[#trail + 1] = module
    for _, dependency in ipairs(graph[module] or {}) do
      if graph[dependency] then
        visit(dependency, trail)
      end
    end
    trail[#trail] = nil
    visiting[module] = nil
    visited[module] = true
  end
  for module in pairs(graph) do
    visit(module, {})
  end

  return #errors == 0, errors
end

if ... == "tools.check_architecture" then
  return Checker
end

local ok, errors = Checker.check(arg[1] or ".")
if not ok then
  for _, message in ipairs(errors) do
    io.stderr:write("architecture: " .. message .. "\n")
  end
  os.exit(1)
end
io.write("Anodyne architecture: PASS\n")
