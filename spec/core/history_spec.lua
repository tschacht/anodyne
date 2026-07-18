local Geometry = require("Anodyne.core.geometry")
local History = require("Anodyne.core.history")

local function frame(value)
  return { x = value, y = value, w = value + 100, h = value + 50 }
end

describe("Milestone 5 bounded per-window history", function()
  local entries, history

  before_each(function()
    entries = {}
    history = History.new({ entries = entries, depth = 2, copyFrame = Geometry.copyFrame, framesEqual = Geometry.framesEqual })
  end)

  it("copies frames and screen snapshots when recording", function()
    local before, after = frame(1), frame(2)
    local screen = { identity = "screen", frame = frame(3) }
    history:record(7, before, after, screen)
    before.x, after.x, screen.frame.x = 99, 99, 99
    assert.same(frame(1), history:last(7).before)
    assert.same(frame(2), history:last(7).after)
    assert.same(frame(3), history:last(7).beforeScreen.frame)
  end)

  it("bounds each window independently", function()
    history:record(7, frame(1), frame(2), nil)
    history:record(7, frame(2), frame(3), nil)
    history:record(7, frame(3), frame(4), nil)
    history:record(8, frame(8), frame(9), nil)
    assert.are.equal(2, #entries[7])
    assert.same(frame(2), entries[7][1].before)
    assert.same(frame(9), history:last(8).after)
  end)

  it("replaces a discontinuous history before recording", function()
    history:record(7, frame(1), frame(2), nil)
    history:record(7, frame(8), frame(9), nil)
    assert.are.equal(1, #entries[7])
    assert.same(frame(8), history:last(7).before)
  end)

  it("clears an individual window", function()
    history:record(7, frame(1), frame(2), nil)
    history:record(8, frame(1), frame(2), nil)
    history:clear(7)
    assert.is_nil(history:last(7))
    assert.is_not_nil(history:last(8))
  end)

  it("removes a restored tail and retains a matching predecessor", function()
    history:record(7, frame(1), frame(2), nil)
    history:record(7, frame(2), frame(3), nil)
    history:acceptRestore(7, frame(2))
    assert.are.equal(1, #entries[7])
  end)

  it("clears after restoring the only entry or a nonmatching predecessor", function()
    history:record(7, frame(1), frame(2), nil)
    history:acceptRestore(7, frame(1))
    assert.is_nil(entries[7])
    history:record(7, frame(1), frame(2), nil)
    history:record(7, frame(2), frame(3), nil)
    history:acceptRestore(7, frame(9))
    assert.is_nil(entries[7])
  end)
end)
