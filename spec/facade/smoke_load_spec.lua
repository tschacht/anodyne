local function quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function run(mode)
  local marker = os.tmpname()
  os.remove(marker)
  local output = marker .. "-output"
  local command = table.concat({
    "ANODYNE_SMOKE_TEST_MODE=" .. quote(mode),
    "ANODYNE_SMOKE_STATUS_PATH=" .. quote(marker),
    "sh tools/smoke_load.sh .",
    ">" .. quote(output) .. " 2>&1",
  }, " ")
  local ok, reason, code = os.execute(command)
  local markerFile = assert(io.open(marker, "r"))
  local status = markerFile:read("*a")
  markerFile:close()
  local outputFile = assert(io.open(output, "r"))
  local message = outputFile:read("*a")
  outputFile:close()
  os.remove(marker)
  os.remove(output)
  return ok, reason, code, status, message
end

describe("Milestone 3 smoke wrapper classification", function()
  it("leaves preflight deferral non-failing before the marker is armed", function()
    local ok, _, code, status, message = run("preflight-deferred")
    assert.is_true(ok)
    assert.are.equal(0, code)
    assert.are.equal('{"status":"DEFERRED-ENVIRONMENT"}\n', status)
    assert.matches("DEFERRED%-ENVIRONMENT", message)
  end)

  it("leaves an armed timeout failed and exits nonzero", function()
    local ok, reason, code, status, message = run("armed-timeout")
    assert.is_nil(ok)
    assert.are.equal("exit", reason)
    assert.are.equal(1, code)
    assert.are.equal('{"status":"FAIL"}\n', status)
    assert.matches("FAIL", message)
  end)

  it("accepts PASS only after the successful-restoration hook overwrites armed FAIL", function()
    local ok, _, code, status, message = run("success-restoration")
    assert.is_true(ok)
    assert.are.equal(0, code)
    assert.are.equal('{"status":"PASS"}\n', status)
    assert.matches("PASS", message)
  end)

  it("converts an invalid attempted-execution marker to FAIL", function()
    local ok, reason, code, status, message = run("invalid-marker")
    assert.is_nil(ok)
    assert.are.equal("exit", reason)
    assert.are.equal(1, code)
    assert.are.equal('{"status":"FAIL"}\n', status)
    assert.matches("missing or invalid status marker", message)
  end)
end)
