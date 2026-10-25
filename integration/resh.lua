local executable = os.getenv("HOME") .. "/Library/Application Support/resh/resh"

rex.action{
  name = "resh",
  title = "Open resh Session Manager",
  description = "Find a folder or switch to a named Rex session.",
  category = "Session",
  run = function(ctx)
    local arguments = { executable, "--client", ctx.client_id }
    if ctx.session_id then
      table.insert(arguments, "--current-session")
      table.insert(arguments, ctx.session_id)
    end
    local handle, err = rex.exec.start(arguments,
      { detach = true, stdout = false, stderr = false })
    if not handle then error(tostring(err)) end
  end,
}

rex.action{
  name = "resh_last",
  title = "resh: Previous Session",
  description = "Toggle between the last two sessions opened through resh.",
  category = "Session",
  run = function(ctx)
    local arguments = { executable, "--last", "--client", ctx.client_id }
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
