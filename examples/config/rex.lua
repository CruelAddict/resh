-- Optional: add these lines to Rex's init.lua after the installed resh integration,
-- then reload Rex's config.
-- Rebind the default Cmd+L previous-session shortcut to Cmd+Shift+L.
rex.unbind("cmd+[KeyL]", "resh_last")
rex.bind("cmd+shift+[KeyL]", "resh_last")
