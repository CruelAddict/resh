-- Rex action adapter. Opening and data loading belong to the resident helper.
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
    if not result then error(tostring(err), 0) end
    if not result.ok then error(result.timed_out and "resh: session switch timed out" or result.stderr, 0) end
  end,
}

-- Startup belongs to Rex's init.lua, alongside any --config argument.
