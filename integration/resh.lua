local executable = os.getenv("HOME") .. "/Library/Application Support/resh/resh"

local function with_client(arguments, ctx)
  local client = ctx.client_id
  if ctx.origin ~= "key" and ctx.origin ~= "palette" then
    -- A CLI invocation's ctx.client_id identifies the CLI connection, not Rex.app.
    local clients = assert(rex.call("client.list", { kinds = { "app" } })).clients or {}
    local matched = false
    for _, app in ipairs(clients) do
      if app.client_id == client then matched = true; break end
    end
    if not matched then
      assert(#clients == 1, "Run this action from Rex, or select an app with resh --client CLIENT_ID.")
      client = clients[1].client_id
    end
  end
  if client then
    table.insert(arguments, "--client")
    table.insert(arguments, client)
  end
  return arguments
end

-- These are real actions: they can also control an open picker from rex do.
-- Key presses inside the picker execute the same actions locally, without IPC.
for _, definition in ipairs({
  { "resh_next", "Next Result", true },
  { "resh_previous", "Previous Result", true },
  { "resh_open", "Open Result", false, {
    type = "object", additionalProperties = false,
    properties = { number = { type = "integer", minimum = 1, maximum = 9 } },
  } },
  { "resh_source", "Select Source", false, {
    type = "object", additionalProperties = false, required = { "name" },
    properties = { name = { type = "string", minLength = 1 } },
  } },
  { "resh_next_source", "Next Source", true },
  { "resh_previous_source", "Previous Source", true },
  { "resh_create", "Create Session" },
  { "resh_pin", "Pin or Unpin Session" },
  { "resh_delete", "Close Selected Session" },
  { "resh_dismiss", "Close Picker" },
}) do
  local name = definition[1]
  rex.action{
    name = name,
    title = "resh: " .. definition[2],
    category = "resh",
    repeats = definition[3] or false,
    args = definition[4] or { type = "object", additionalProperties = false },
    run = function(ctx, args)
      local arguments = with_client({ executable, "--action", name, "--args", assert(rex.json.encode(args)) }, ctx)
      local result, err = rex.exec(arguments, { timeout = 4 })
      if not result then error(tostring(err)) end
      if not result.ok then error(result.stderr) end
    end,
  }
end

rex.action{
  name = "resh",
  title = "Open resh Session Manager",
  description = "Find a folder or switch to a Rex session.",
  category = "Session",
  args = { type = "object", additionalProperties = false },
  run = function(ctx)
    local arguments = with_client({ executable }, ctx)
    if ctx.session_id then
      table.insert(arguments, "--current-session")
      table.insert(arguments, ctx.session_id)
    end
    local handle, err = rex.exec.start(arguments,
      { detach = true, stdout = false, stderr = false })
    if not handle then error(tostring(err)) end
  end,
}

rex.bind("cmd+[KeyS]", "resh")

rex.action{
  name = "resh_last",
  title = "resh: Previous Session",
  description = "Toggle between the last two sessions opened through resh.",
  category = "Session",
  args = { type = "object", additionalProperties = false },
  run = function(ctx)
    local arguments = with_client({ executable, "--last" }, ctx)
    if ctx.session_id then
      table.insert(arguments, "--current-session")
      table.insert(arguments, ctx.session_id)
    end
    local result, err = rex.exec(arguments, { timeout = 15 })
    if not result then rex.log("debug", tostring(err))
    elseif not result.ok then rex.log("debug", result.stderr) end
  end,
}

rex.bind("cmd+[KeyL]", "resh_last")
