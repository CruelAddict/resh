-- Rex action adapter. Opening and data loading belong to the resident app.
local executable = os.getenv("HOME") .. "/Applications/resh.app/Contents/MacOS/resh"

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

-- Startup belongs to Rex's init.lua, alongside any --config argument.
