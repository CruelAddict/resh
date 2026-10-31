-- Read-only activity stream. Kept alive to retain task provenance when programs
-- clear completed reports. No polling, output parsing, focus changes or receipts.
local terminal = "com.superlogical.terminal"
local sessions = {}
local previous

local function fail(err)
  io.stdout:write(assert(rex.json.encode({ error = tostring(err) })), "\n")
  io.stdout:flush()
  error(err, 0)
end

local function publish()
  local records = {}
  for session_id, blocks in pairs(sessions) do
    for block_id, block in pairs(blocks) do
      for _, record in ipairs(block.records) do
        -- Keep working/idle programs for Agents. Swift derives unread dots from
        -- these same records using Rex's own read receipts.
        table.insert(records, { session_id = session_id, block_id = block_id,
          record_id = record.id, state = record.state, updated_at = record.updated_at,
          app = record.effective_app or record.app, title = record.title,
          terminal_title = block.title, window_id = block.window_id,
          window_index = block.window_index, pane_index = block.pane_index })
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
  if not result then fail(err) end
  return result.records or {}
end

local function scan(session_id)
  local listed, err = rex.call("session.view", { session_id = session_id })
  if not listed then
    if tostring(err):find("session_not_found", 1, true) then sessions[session_id] = nil; return end
    fail(err)
  end
  local blocks, previous_blocks = {}, sessions[session_id] or {}
  for window_index, window in ipairs(listed.windows or {}) do
    local pane_index = 0
    for _, layer in ipairs(window.layers or {}) do
      local metadata = {}
      for _, block in ipairs(layer.blocks or {}) do metadata[block.block_id] = block end
      local function visit(node)
        if not node then return end
        if node.split then visit(node.split.before); visit(node.split.after); return end
        if not node.block_id then return end
        pane_index = pane_index + 1
        local block = metadata[node.block_id]
        if not block or block.creator_name ~= terminal then return end
        local entry = previous_blocks[block.block_id]
        if not entry then
          entry = { records = statuses(session_id, block.block_id) }
          if #entry.records > 0 then
            local result, err = rex.call(terminal .. ".title", {
              session_id = session_id, block_id = block.block_id, args = {},
            })
            if not result then fail(err) end
            entry.title = result.title
          end
        end
        entry.window_id = window.window_id
        entry.window_index = window_index
        entry.pane_index = pane_index
        blocks[block.block_id] = entry
      end
      visit(layer.layout)
    end
  end
  sessions[session_id] = blocks
end

local function status_changed(ctx, ev)
  local blocks = sessions[ctx.session_id]
  if blocks and blocks[ev.block_id] then
    local block = blocks[ev.block_id]
    block.records = statuses(ctx.session_id, ev.block_id)
    if not block.title and #block.records > 0 then
      local result, err = rex.call(terminal .. ".title", {
        session_id = ctx.session_id, block_id = ev.block_id, args = {},
      })
      if not result then fail(err) end
      block.title = result.title
    end
  else
    scan(ctx.session_id)
  end
  publish()
end

rex.on("terminal.program_status_changed", status_changed)
rex.on("terminal.program_status_removed", status_changed)
rex.on("terminal.title_changed", function(ctx, ev)
  local blocks = sessions[ctx.session_id]
  if blocks and blocks[ev.block_id] then
    blocks[ev.block_id].title = ev.title
    publish()
  end
end)
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
if not listed then fail(err) end
for _, session in ipairs(listed.sessions or {}) do scan(session.session_id) end
publish()

-- launchd sends SIGTERM to the old process group when the UI crashes, but
-- does not promise escalation for a child ignoring it. A quiet event stream
-- must also notice its stdout reader disappeared. No RPC/terminal polling;
-- this timer exists only for the lifetime of the activity stream.
rex.every(10, function()
  local written = io.stdout:write('{"heartbeat":true}\n')
  if not written then rex.stop(0) end
  local flushed = io.stdout:flush()
  if not flushed then rex.stop(0) end
end)
