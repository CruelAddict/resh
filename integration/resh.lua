local executable = os.getenv("HOME") .. "/Library/Application Support/resh/resh"

rex.action{
  name = "resh",
  title = "Open resh Session Manager",
  description = "Find a folder or switch to a named Rex session.",
  category = "Session",
  run = function(ctx)
    local handle, err = rex.exec.start({ executable, "--client", ctx.client_id },
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
    local result, err = rex.exec({ executable, "--last", "--client", ctx.client_id },
      { timeout = 15 })
    if not result then rex.log("debug", tostring(err))
    elseif not result.ok then rex.log("debug", result.stderr) end
  end,
}
