local History = {}
History.__index = History

function History.new(options)
  return setmetatable({
    entries = options.entries,
    depth = options.depth,
    copyFrame = options.copyFrame,
    framesEqual = options.framesEqual,
  }, History)
end

local function copyScreen(self, screen)
  if not screen then
    return nil
  end
  return { identity = screen.identity, frame = self.copyFrame(screen.frame) }
end

function History:record(windowId, beforeFrame, afterFrame, beforeScreen)
  local entries = self.entries[windowId] or {}
  if #entries > 0 and not self.framesEqual(entries[#entries].after, beforeFrame) then
    entries = {}
  end

  table.insert(entries, {
    before = self.copyFrame(beforeFrame),
    after = self.copyFrame(afterFrame),
    beforeScreen = copyScreen(self, beforeScreen),
  })
  while #entries > self.depth do
    table.remove(entries, 1)
  end
  self.entries[windowId] = entries
end

function History:last(windowId)
  local entries = self.entries[windowId]
  return entries and entries[#entries] or nil
end

function History:clear(windowId)
  self.entries[windowId] = nil
end

function History:acceptRestore(windowId, actualFrame)
  local entries = self.entries[windowId]
  table.remove(entries)
  if #entries == 0 or not self.framesEqual(entries[#entries].after, actualFrame) then
    self:clear(windowId)
  end
end

return History
