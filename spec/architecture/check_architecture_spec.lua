local Checker = require("tools.check_architecture")

local expected = {
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

local function quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function write(path, contents)
  local file = assert(io.open(path, "w"))
  file:write(contents)
  file:close()
end

local function fixture()
  local root = os.tmpname()
  os.remove(root)
  assert(os.execute("mkdir -p " .. quote(root .. "/Anodyne/adapter") .. " " .. quote(root .. "/Anodyne/core")))
  for _, path in ipairs(expected) do
    write(root .. "/" .. path, "return {}\n")
  end
  return root
end

local function remove(root)
  os.execute("rm -rf " .. quote(root))
end

local function contains(errors, pattern)
  for _, message in ipairs(errors) do
    if message:match(pattern) then
      return true
    end
  end
  return false
end

describe("architecture checker", function()
  it("accepts the production dependency boundary", function()
    local ok, errors = Checker.check(".")
    assert.is_true(ok, table.concat(errors, "\n"))
  end)

  it("rejects native access outside the adapter", function()
    local root = fixture()
    write(root .. "/Anodyne/controller.lua", "return hs.timer.doAfter(1, function() end)\n")
    local ok, errors = Checker.check(root, { skipRootMigration = true, skipCoverageConfiguration = true })
    remove(root)
    assert.is_false(ok)
    assert.is_true(contains(errors, "native hs identifiers"))
  end)

  it("rejects native identifier escape forms without matching strings or comments", function()
    local forms = {
      "return hs\n",
      'return hs["timer"]\n',
      "local native = hs\nreturn native\n",
    }
    for _, form in ipairs(forms) do
      local root = fixture()
      write(root .. "/Anodyne/controller.lua", '-- hs and return hs are documentation only\nlocal text = "hs.timer"\n' .. form)
      local ok, errors = Checker.check(root, { skipRootMigration = true, skipCoverageConfiguration = true })
      remove(root)
      assert.is_false(ok)
      assert.is_true(contains(errors, "native hs identifiers"))
    end
  end)

  it("rejects global compatibility access in production modules", function()
    local root = fixture()
    write(root .. "/Anodyne/view.lua", "return _G.WindowManager\n")
    local ok, errors = Checker.check(root, { skipRootMigration = true, skipCoverageConfiguration = true })
    remove(root)
    assert.is_false(ok)
    assert.is_true(contains(errors, "transitional alias"))
  end)

  it("rejects production require cycles", function()
    local root = fixture()
    write(root .. "/Anodyne/controller.lua", 'return require("Anodyne.view")\n')
    write(root .. "/Anodyne/view.lua", 'return require("Anodyne.controller")\n')
    local ok, errors = Checker.check(root, { skipRootMigration = true, skipCoverageConfiguration = true })
    remove(root)
    assert.is_false(ok)
    assert.is_true(contains(errors, "require cycle"))
  end)

  it("detects cycles written with bare require syntax", function()
    local root = fixture()
    write(root .. "/Anodyne/controller.lua", 'return require "Anodyne.view"\n')
    write(root .. "/Anodyne/view.lua", 'return require "Anodyne.controller"\n')
    local ok, errors = Checker.check(root, { skipRootMigration = true, skipCoverageConfiguration = true })
    remove(root)
    assert.is_false(ok)
    assert.is_true(contains(errors, "require cycle"))
  end)

  it("detects no-space and long-bracket literal require cycles", function()
    local forms = {
      { 'return require"Anodyne.view"\n', 'return require"Anodyne.controller"\n' },
      { "return require[=[Anodyne.view]=]\n", "return require([=[Anodyne.controller]=])\n" },
      { "return require[=[\nAnodyne.view]=]\n", "return require([=[\nAnodyne.controller]=])\n" },
    }
    for _, form in ipairs(forms) do
      local root = fixture()
      write(root .. "/Anodyne/controller.lua", form[1])
      write(root .. "/Anodyne/view.lua", form[2])
      local ok, errors = Checker.check(root, { skipRootMigration = true, skipCoverageConfiguration = true })
      remove(root)
      assert.is_false(ok)
      assert.is_true(contains(errors, "require cycle"))
    end
  end)

  it("detects redundant-parentheses cycles at arbitrary tested depths", function()
    local forms = {
      { 'return require(("Anodyne.view"))\n', 'return require(("Anodyne.controller"))\n' },
      { 'return require(((("Anodyne.view"))))\n', 'return require(((("Anodyne.controller"))))\n' },
      {
        "return require( -- call\n ( -- group\n [=[Anodyne.view]=] -- literal\n ) )\n",
        "return require( -- call\n ( -- group\n [=[Anodyne.controller]=] -- literal\n ) )\n",
      },
    }
    for _, form in ipairs(forms) do
      local root = fixture()
      write(root .. "/Anodyne/controller.lua", form[1])
      write(root .. "/Anodyne/view.lua", form[2])
      local ok, errors = Checker.check(root, { skipRootMigration = true, skipCoverageConfiguration = true })
      remove(root)
      assert.is_false(ok)
      assert.is_true(contains(errors, "require cycle"))
    end
  end)

  it("rejects non-literal and incompletely grouped require arguments", function()
    local invalid = {
      'require(("Anodyne.missing" .. suffix))\n',
      'require(("Anodyne.missing", other))\n',
      'require((factory("Anodyne.missing")))\n',
      'require(("Anodyne.missing")())\n',
      'require((("Anodyne.missing"))\n',
    }
    for _, source in ipairs(invalid) do
      local root = fixture()
      write(root .. "/Anodyne/controller.lua", source)
      local ok, errors = Checker.check(root, { skipRootMigration = true, skipCoverageConfiguration = true })
      remove(root)
      assert.is_true(ok, table.concat(errors, "\n"))
    end
  end)

  it("retains require edges when the completed call result has postfix use", function()
    local forms = {
      { 'return require(("Anodyne.view")).new()\n', 'return require(("Anodyne.controller")).new()\n' },
      { 'return require(("Anodyne.view")):start()\n', 'return require(("Anodyne.controller")):start()\n' },
      { 'return require(("Anodyne.view"))[key]\n', 'return require(("Anodyne.controller"))[key]\n' },
      { 'return require(("Anodyne.view"))()\n', 'return require(("Anodyne.controller"))()\n' },
    }
    for _, form in ipairs(forms) do
      local root = fixture()
      write(root .. "/Anodyne/controller.lua", form[1])
      write(root .. "/Anodyne/view.lua", form[2])
      local ok, errors = Checker.check(root, { skipRootMigration = true, skipCoverageConfiguration = true })
      remove(root)
      assert.is_false(ok)
      assert.is_true(contains(errors, "require cycle"))
    end
  end)

  it("ignores require-like text outside global require calls", function()
    local root = fixture()
    write(
      root .. "/Anodyne/controller.lua",
      [=[
local short = "require(\"Anodyne.missing\")"
local long = [==[require("Anodyne.missing")]==]
-- require("Anodyne.missing")
--[==[ require "Anodyne.missing" ]==]
local object = { require = function() end }
object.require("Anodyne.missing")
object:require("Anodyne.missing")
local function xrequire() end
xrequire("Anodyne.missing")
require "AnodyneTools"
return { short, long }
]=]
    )
    local ok, errors = Checker.check(root, { skipRootMigration = true, skipCoverageConfiguration = true })
    remove(root)
    assert.is_true(ok, table.concat(errors, "\n"))
  end)

  it("does not extract dependencies from malformed or unterminated literals", function()
    local root = fixture()
    write(
      root .. "/Anodyne/controller.lua",
      [=[
local text = "require(\"Anodyne.missing\")"
local broken = "require(\"Anodyne.missing\")
require("Anodyne.missing"
require("Anodyne.missing" .. suffix)
]=]
    )
    local ok, errors = Checker.check(root, { skipRootMigration = true, skipCoverageConfiguration = true })
    remove(root)
    assert.is_true(ok, table.concat(errors, "\n"))
  end)

  it("tracks the previous code token across strings and comments", function()
    local root = fixture()
    write(root .. "/Anodyne/controller.lua", 'local text = "ends."\n-- ends.\nrequire"Anodyne.view"\n')
    write(root .. "/Anodyne/view.lua", 'return require("Anodyne.controller")\n')
    local ok, errors = Checker.check(root, { skipRootMigration = true, skipCoverageConfiguration = true })
    assert.is_false(ok)
    assert.is_true(contains(errors, "require cycle"))

    write(root .. "/Anodyne/controller.lua", 'local object = {}\nobject. -- trailing comment\n require"Anodyne.missing"\nreturn object\n')
    write(root .. "/Anodyne/view.lua", "return {}\n")
    ok, errors = Checker.check(root, { skipRootMigration = true, skipCoverageConfiguration = true })
    remove(root)
    assert.is_true(ok, table.concat(errors, "\n"))
  end)

  it("rejects missing expected production modules", function()
    local root = fixture()
    os.remove(root .. "/Anodyne/core/history.lua")
    local ok, errors = Checker.check(root, { skipRootMigration = true, skipCoverageConfiguration = true })
    remove(root)
    assert.is_false(ok)
    assert.is_true(contains(errors, "not discovered and analyzed"))
  end)

  it("fails closed when the production scanner fails", function()
    local root = fixture()
    local ok, errors = Checker.check(root, {
      skipRootMigration = true,
      skipCoverageConfiguration = true,
      discover = function()
        return nil, "injected scanner failure"
      end,
    })
    remove(root)
    assert.is_false(ok)
    assert.is_true(contains(errors, "injected scanner failure"))
    assert.is_true(contains(errors, "zero Lua sources"))
  end)

  it("fails closed when discovery omits an expected readable module", function()
    local root = fixture()
    local ok, errors = Checker.check(root, {
      skipRootMigration = true,
      skipCoverageConfiguration = true,
      discover = function()
        return { "Anodyne/init.lua" }
      end,
    })
    remove(root)
    assert.is_false(ok)
    assert.is_true(contains(errors, "Anodyne/config.lua"))
    assert.is_true(contains(errors, "not discovered and analyzed"))
  end)
end)
