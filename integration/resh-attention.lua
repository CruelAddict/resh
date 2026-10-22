-- Read-only activity stream. Started after the panel is visible and stopped on
-- dismissal. No polling, terminal output parsing, focus changes or read receipts.
local terminal = "com.superlogical.terminal"
local sessions = {}
local previous

local function publish()
  local records = {}
  for session_id, blocks in pairs(sessions) do
    for block_id, statuses in pairs(blocks) do
      for _, record in ipairs(statuses) do
        -- Rex can retain a completion announcement for an idle agent. Swift
        -- matches it against Rex's own ledger; plain idle still shows no dot.
        if record.state == "done" or record.state == "blocked" or record.state == "error" or record.state == "idle" then
          table.insert(records, { session_id = session_id, block_id = block_id,
            record_id = record.id, state = record.state, updated_at = record.updated_at })
        end
      end
    end
  end
  table.sort(records, function(a, b)
    if a.session_id ~= b.session_id then return a.session_id < b.session_id end
    if a.block_id ~= b.block_id then return a.block_id < b.block_id end
    return (a.record_id or "") < (b.record_id or "")
  end)
  -- Empty Lua tables encode as objects; omit the optional array instead.
  local value = #records > 0 and { records = records } or {}
  local encoded = assert(rex.json.encode(value))
  if encoded ~= previous then
    io.stdout:write(encoded, "\n")
    io.stdout:flush()
    previous = encoded
  end
end

local function statuses(session_id, block_id)
  local result, err = rex.call(terminal .. ".program_status", {
    session_id = session_id, block_id = block_id, args = {},
  })
  -- Old servers may not implement program_status. That must not break the picker.
  if not result then
    if tostring(err):find("method_not_found", 1, true) or tostring(err):find("not_found", 1, true) then return {} end
    error(err)
  end
  return result.records or {}
end

local function scan(session_id)
  local listed, err = rex.call("session.list_blocks", { session_id = session_id })
  if not listed then
    if tostring(err):find("session_not_found", 1, true) then sessions[session_id] = nil; return end
    error(err)
  end
  local blocks = {}
  for _, block in ipairs(listed.blocks or {}) do
    if block.creator_name == terminal and block.placement == "placed" and block.block_id then
      blocks[block.block_id] = statuses(session_id, block.block_id)
    end
  end
  sessions[session_id] = blocks
end

local function status_changed(ctx, ev)
  local blocks = sessions[ctx.session_id]
  if blocks and blocks[ev.block_id] then
    blocks[ev.block_id] = statuses(ctx.session_id, ev.block_id)
  else
    scan(ctx.session_id)
  end
  publish()
end

rex.on("terminal.program_status_changed", status_changed)
rex.on("terminal.program_status_removed", status_changed)
rex.on("session_view_changed", function(ctx)
  scan(ctx.session_id)
  publish()
end)
rex.on("block_closed", function(ctx, ev)
  if sessions[ctx.session_id] then sessions[ctx.session_id][ev.block_id] = nil end
  publish()
end)
rex.on("session_created", function(_, ev)
  scan(ev.session.session_id)
  publish()
end)
rex.on("session_destroyed", function(_, ev)
  sessions[ev.session_id] = nil
  publish()
end)

-- rex do establishes its automatic --all event scope only after this top-level
-- script returns. Subscribe BEFORE the initial reads: without it session/block
-- calls fail with "stream is not attached", not "there are no notifications".
local listed, err = rex.call("session.attach_all", { event_scope = "all" })
if not listed then error(err) end
for _, session in ipairs(listed.sessions or {}) do scan(session.session_id) end
publish()
