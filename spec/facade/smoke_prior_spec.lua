local Prior = require("tools.smoke_prior")

describe("Milestone 3 smoke prior-state safety", function()
  local function prior(initial, reported)
    local state = initial
    local calls = { start = 0, stop = 0, state = 0 }
    local instance = {}
    function instance:isRunning()
      calls.state = calls.state + 1
      if type(reported) == "function" then
        return reported()
      end
      if reported ~= nil then
        return reported
      end
      return state
    end
    function instance:start()
      calls.start = calls.start + 1
      state = true
      return self
    end
    function instance:stop()
      calls.stop = calls.stop + 1
      state = false
      return self, nil
    end
    return instance, calls
  end

  it("captures, stops, and restores an exactly running prior instance", function()
    local instance, calls = prior(true)
    local snapshot = assert(Prior.snapshot(instance))
    assert.is_true(snapshot.running)
    assert.is_true(Prior.stop(snapshot))
    assert.are.equal(1, calls.stop)
    assert.is_true(Prior.restore(snapshot))
    assert.are.equal(1, calls.start)
    assert.is_true(instance:isRunning())
  end)

  it("preserves an exactly stopped prior instance without starting or stopping it", function()
    local instance, calls = prior(false)
    local snapshot = assert(Prior.snapshot(instance))
    assert.is_false(snapshot.running)
    assert.is_true(Prior.stop(snapshot))
    assert.is_true(Prior.restore(snapshot))
    assert.are.equal(0, calls.stop)
    assert.are.equal(0, calls.start)
    assert.is_false(instance:isRunning())
  end)

  it("defers unprovable state before invoking any mutating lifecycle method", function()
    local nonboolean, nonbooleanCalls = prior(true, "yes")
    assert.is_nil(Prior.snapshot(nonboolean))
    assert.are.equal(0, nonbooleanCalls.stop)
    assert.are.equal(0, nonbooleanCalls.start)

    local throwing, throwingCalls = prior(true, function()
      error("state failure")
    end)
    assert.is_nil(Prior.snapshot(throwing))
    assert.are.equal(0, throwingCalls.stop)
    assert.are.equal(0, throwingCalls.start)

    local incomplete = {
      stop = function()
        error("must not run")
      end,
    }
    assert.is_nil(Prior.snapshot(incomplete))
  end)

  it("rejects a post-mutation restoration defect", function()
    local instance = { running = true }
    function instance:isRunning()
      return self.running
    end
    function instance:stop()
      self.running = false
      return self, nil
    end
    function instance:start()
      return self
    end
    local snapshot = assert(Prior.snapshot(instance))
    assert.is_true(Prior.stop(snapshot))
    local ok, message = Prior.restore(snapshot)
    assert.is_false(ok)
    assert.are.equal("prior state restoration is unprovable", message)
  end)
end)
