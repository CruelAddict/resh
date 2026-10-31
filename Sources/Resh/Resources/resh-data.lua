-- Persistent supported CLI bridge. Requests are processed one at a time;
-- snapshots are fresh and mutations are never replayed by the native client.
local function reply(value)
  io.stdout:write(assert(rex.json.encode(value)), "\n")
  io.stdout:flush()
end

reply({ ready = true })
for line in io.lines() do
  local request, decode_err = rex.json.decode(line)
  local ok, result = pcall(function()
    if not request then error(decode_err, 0) end
    if request.method then
      local result, err = rex.call(request.method, request.args or {})
      if err then error(err, 0) end
      return { result = result }
    end
    local clients, client_err = rex.call("client.list", { kinds = { "app" } })
    if not clients then error(client_err, 0) end
    local selected
    for _, client in ipairs(clients.clients or {}) do
      if client.info and client.info.platform == "macos" and client.principal then
        if request.client then
          if client.client_id == request.client then selected = client end
        elseif client.principal.pid == request.rex_app_pid then
          selected = client
        end
      end
    end
    if not selected then error("Cannot find the requested Rex app. Open resh from the active Rex window.", 0) end
    local listed, list_err = rex.call("session.list", {})
    if not listed then error(list_err, 0) end
    local response = { client = selected.client_id, rex_app_pid = selected.principal.pid }
    -- Lua's empty table encodes as an object, so omit an empty optional array.
    if listed.sessions and #listed.sessions > 0 then response.sessions = listed.sessions end
    return response
  end)
  reply(ok and result or { error = tostring(result) })
end
