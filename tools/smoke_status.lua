local Status = {}

function Status.write(path, value)
  if value ~= "PASS" and value ~= "FAIL" and value ~= "DEFERRED-ENVIRONMENT" then
    error("invalid smoke status: " .. tostring(value), 2)
  end
  local token = tostring({}):gsub("[^%w]", "")
  local temporary = path .. ".tmp-" .. token
  local file = assert(io.open(temporary, "w"))
  file:write('{"status":"', value, '"}\n')
  assert(file:close())
  local renamed, message = os.rename(temporary, path)
  if not renamed then
    os.remove(temporary)
    error("unable to publish smoke status: " .. tostring(message), 2)
  end
end

return Status
