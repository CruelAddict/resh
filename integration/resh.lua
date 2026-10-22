-- resh: a native, sesh-inspired project picker. No tmux and no shell-input injection.
local executable = os.getenv("HOME") .. "/Applications/resh.app/Contents/MacOS/resh"

rex.action{
  name = "resh",
  title = "resh: Projects & Sessions",
  description = "Find a folder or switch to a named Rex session in a native macOS panel.",
  category = "Session",
  keywords = "project directory folder fuzzy sesh resh session switch create",
  args = { smoke_test = "string?" },
  run = function(ctx, args)
    if not ctx.client_id then
      error("Open resh from Rex's command palette or press Cmd+S in Rex.")
    end
    local argv = { executable, "--client", ctx.client_id }
    if ctx.session_id then
      table.insert(argv, "--session")
      table.insert(argv, ctx.session_id)
    end
    -- smoke_test is only used by the end-to-end installer verification.
    local smoke_test = args.smoke_test
    if smoke_test then
      table.insert(argv, "--smoke-test")
      table.insert(argv, smoke_test)
    end
    local handle, err = rex.exec.start(argv, {
      detach = not smoke_test,
      stdout = false,
      stderr = false,
    })
    if not handle then error("Could not launch resh: " .. tostring(err)) end
    if smoke_test then
      local result, wait_err = handle:wait(20)
      if not result then error(tostring(wait_err)) end
      if not result.ok then error("resh UI smoke test failed") end
    end
  end,
}

rex.bind("cmd+s", "resh")
