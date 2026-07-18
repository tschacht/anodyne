local inventory = require("spec.behavior_inventory")

describe("Milestone 1 behavior inventory", function()
  for _, contract in ipairs(inventory) do
    it(contract.id .. " records an observable compatibility contract", function()
      assert.matches("^A%-[A-Z]+%-01$", contract.id)
      assert.is_true(#contract.behavior >= 40)
      assert.matches("^init%.lua:", contract.source)
    end)
  end
end)

describe("Milestone 1 coverage checker", function()
  it("fails when an on-disk Anodyne source is omitted from the LuaCov report", function()
    local temporary = os.tmpname()
    os.remove(temporary)
    local summary = temporary .. "-summary.json"
    local output = temporary .. "-output.txt"
    local command = table.concat({
      ".lua/bin/lua tools/check_coverage.lua",
      "--milestone 1",
      "--report spec/fixtures/coverage/luacov-missing.report.out",
      "--summary " .. summary,
      "--source-root spec/fixtures/coverage/Anodyne",
      "> " .. output .. " 2>&1",
    }, " ")
    local ok, reason, code = os.execute(command)
    local result = assert(io.open(output, "r")):read("*a")
    os.remove(summary)
    os.remove(output)

    assert.is_nil(ok)
    assert.are.equal("exit", reason)
    assert.are.equal(1, code)
    assert.matches("coverage omitted on%-disk production file: Anodyne/missing.lua", result)
  end)
end)

describe("Milestone 1 environment provenance", function()
  local temporary = os.tmpname()
  os.remove(temporary)
  local output = temporary .. "-output.txt"
  local missing = temporary .. "-missing.manifest"
  local mismatch = temporary .. "-mismatch.manifest"

  local function validate(marker)
    os.remove(output)
    local command = table.concat({
      "python3 tools/environment_manifest.py validate",
      ".",
      marker,
      "> " .. output .. " 2>&1",
    }, " ")
    local ok, reason, code = os.execute(command)
    local result = assert(io.open(output, "r")):read("*a")
    os.remove(output)
    return ok, reason, code, result
  end

  it("rejects an existing environment with no completion marker", function()
    os.remove(missing)
    local ok, reason, code, result = validate(missing)
    assert.is_nil(ok)
    assert.are.equal("exit", reason)
    assert.are.equal(1, code)
    assert.matches("marker missing", result)
    assert.matches("quarantine %.lua", result)
  end)

  it("rejects an existing environment with mismatched provenance", function()
    local marker = assert(io.open(mismatch, "w"))
    marker:write("schema=1\ncompletion=complete\n")
    marker:close()
    local ok, reason, code, result = validate(mismatch)
    os.remove(mismatch)
    assert.is_nil(ok)
    assert.are.equal("exit", reason)
    assert.are.equal(1, code)
    assert.matches("marker mismatch", result)
    assert.matches("quarantine %.lua", result)
  end)
end)
