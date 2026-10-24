-- Persistent, read-only catalog. No terminal scans or periodic API requests.
local function reply(value)
  local written = io.stdout:write(assert(rex.json.encode(value)), "\n")
  if not written then rex.stop(0) end
  io.stdout:flush()
end

local function call(method, args)
  local result, err = rex.call(method, args or {})
  if not result then
    reply({ error = tostring(err) })
    error(err, 0)
  end
  return result
end

local function publish_sessions(listed)
  listed = listed or call("session.list")
  local value = { type = "sessions" }
  if listed.sessions and #listed.sessions > 0 then value.sessions = listed.sessions end
  reply(value)
end

local app_clients = {}
local function publish_clients()
  local clients = {}
  app_clients = {}
  for _, client in ipairs(call("client.list", { kinds = { "app" } }).clients or {}) do
    if client.info and client.info.platform == "macos" and client.principal and client.principal.pid then
      table.insert(clients, { client = client.client_id, rex_app_pid = client.principal.pid })
      app_clients[client.client_id] = true
    end
  end
  local value = { type = "clients" }
  if #clients > 0 then value.clients = clients end
  reply(value)
end

rex.on("session_created", function(_, ev)
  reply({ type = "created", session_id = ev.session.session_id })
  publish_sessions()
end)
rex.on("session_destroyed", function(_, ev)
  reply({ type = "destroyed", session_id = ev.session_id })
  publish_sessions()
end)
rex.on("session_label_changed", function() publish_sessions() end)
rex.on("client_joined", function(_, ev)
  if ev.client.info and ev.client.info.kind == "app" then publish_clients() end
end)
rex.on("client_left", function(_, ev)
  if app_clients[ev.client_id] then publish_clients() end
end)
rex.on("client_changed", function(_, ev)
  if ev.client.info and ev.client.info.kind == "app" then publish_clients() end
end)
rex.on("hosts_changed", function() reply({ type = "hosts" }) end)
rex.on("keymap_changed", function() reply({ type = "capabilities" }) end)

-- Attach before the initial reads so events cover changes during initialization.
local listed = call("session.attach_all", { event_scope = "all" })
publish_clients()
publish_sessions(listed)

-- Only detects a vanished stdout reader; never polls Rex state.
rex.every(10, function() reply({ heartbeat = true }) end)
