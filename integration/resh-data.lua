-- Read-only, persistent CLI connection for the native panel. Every line requests
-- a NEW snapshot; there is no retained session list and no polling timer.
local function reply(value)
  io.stdout:write(assert(rex.json.encode(value)), "\n")
  io.stdout:flush()
end

reply({ ready = true })
for line in io.lines() do
  local request, decode_err = rex.json.decode(line)
  local ok, result = pcall(function()
    if not request then error(decode_err) end
    local clients, client_err = rex.call("client.list", { kinds = { "app" } })
    if not clients then error(client_err) end
    local selected
    for _, client in ipairs(clients.clients or {}) do
      if client.info and client.info.platform == "macos" and client.principal
          and client.principal.pid == request.pid then selected = client end
    end
    if not selected then error("The active Rex app is not connected to its local server.") end
    local listed, list_err = rex.call("session.list", {})
    if not listed then error(list_err) end
    local response = { client = selected.client_id }
    -- Lua's empty table encodes as an object, so omit an empty optional array.
    if listed.sessions and #listed.sessions > 0 then response.sessions = listed.sessions end
    return response
  end)
  reply(ok and result or { error = tostring(result) })
end
