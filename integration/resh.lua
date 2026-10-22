-- Rex action adapter. Opening and data loading belong to the resident app.
local executable = os.getenv("HOME") .. "/Applications/resh.app/Contents/MacOS/resh"

rex.action{
  name = "resh",
  title = "resh: Sessions & Folders",
  description = "Find a folder or switch to a named Rex session.",
  category = "Session",
  run = function()
    local handle, err = rex.exec.start({ executable },
      { detach = true, stdout = false, stderr = false })
    if not handle then error(tostring(err)) end
  end,
}

rex.exec.start({ executable, "--warmup" }, { detach = true, stdout = false, stderr = false })
