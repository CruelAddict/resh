-- Optional remote tool overrides: save as ~/.config/resh/tools.lua on that host
-- (or $XDG_CONFIG_HOME/resh/tools.lua), then reload its Rex config.
-- Omit fields to discover tools automatically; false disables a tool.
return {
  -- Explicit paths must be absolute.
  fd = "/custom/bin/fd",
  zoxide = false,
  -- Git supplies repository information for automatic session naming.
  git = "/custom/bin/git",
}
