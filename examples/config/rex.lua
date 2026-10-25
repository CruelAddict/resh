-- Optional: add this line to Rex's init.lua after the installed resh integration,
-- then reload Rex's config. This is not part of resh's TOML [keymap].
-- Previous-session switching has no default shortcut; Cmd+L is just an example.
-- [KeyL] uses the physical key so the binding works across keyboard layouts.
rex.bind("cmd+[KeyL]", "resh_last")
