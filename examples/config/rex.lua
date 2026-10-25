-- Optional: add these lines to Rex's init.lua after the installed resh integration,
-- then reload Rex's config. This is not part of resh's TOML [keymap].
-- Rebind the default Cmd+L previous-session shortcut to Cmd+Shift+L.
-- [KeyL] uses the physical key so the binding works across keyboard layouts.
rex.unbind("cmd+[KeyL]", "resh_last")
rex.bind("cmd+shift+[KeyL]", "resh_last")
