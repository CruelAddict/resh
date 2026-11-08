-- ~/.config/resh/tools.lua on a specific host might be used to override tools discovery
-- $XDG_CONFIG_HOME/resh/tools.lua is also supported
-- Apply with `rex config reload`
-- nil = autodetect; false = disable; an absolute executable path = override binary location
return {
	fd = nil, -- also detects fdfind
	zoxide = nil,
	git = nil,
}
