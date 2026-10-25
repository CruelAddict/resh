# resh

A native macOS project launcher for [Rex](https://www.superlogical.com/), inspired
by [sesh](https://github.com/joshmedeski/sesh). Find a directory and open it as a
named session in a few keystrokes.

- Jump to frequently visited directories with zoxide, or find a folder with fd.
- Save project shortcuts with commands to open your editor or start a dev server.
- Search local and remote sessions and directories together.
- Add your own folder lists and customize keyboard shortcuts.

## Install

Requires macOS 15+ and Rex. One-command installation is planned for the public release.

Enable **Rex Settings → Rex Server → Remote Control** to allow session switching.
For directory search, install zoxide and fd:

```sh
brew install zoxide fd
```

Set up [zoxide in your shell](https://github.com/ajeetdsouza/zoxide#installation) to
track the directories you visit. You can skip these tools if you only want sessions
and configured projects.

## Using resh

Press ⌘S in Rex to open the session list. From there, choose **Recent** to find a
directory you've visited, **Find** to search for another folder, or **Projects** to
open a saved project. Selecting a directory creates a named session there, or
returns to the one you opened through resh before.

### Default shortcuts

| Key | Action |
| --- | --- |
| ⌘S | Open or close resh |
| ⌘E | Sessions — switch to an open session |
| ⌘R | Recent — open a zoxide directory as a session |
| ⌘F | Find — search directories under your home folder with fd |
| ⌘P | Projects — open a configured project |
| ⌘A | All — search sessions and project directories together |
| ⌘1–9 | Open by number |
| ⌘⇧P | Pin or unpin the selected session |
| ⌘⇧N | Create a session named after the search text |
| ⌘⇧D | Close the selected session and its programs (without confirmation) |
| ↑ / ↓, Tab / Shift-Tab, ⌃P / ⌃N | Move through the list |
| Return | Open the selection |
| Esc / ⌃[ | Close the picker |
| Not bound | [Switch to the previous session](examples/config/rex.lua) |

Hold ⌘ to show shortcut hints.

## Configuration

Put settings in `~/.config/resh/config.toml` (or
`$XDG_CONFIG_HOME/resh/config.toml`). Edits apply without restarting.

### Project commands

Save a directory with a name and a command to run when opening a new session:

```toml
[[session]]
name = "Backend"
path = "~/work/backend"
startup_command = "nvim"
```

[More project options](examples/config/projects.toml).

### Custom folder lists

Add a tab that finds your work repositories:

```toml
[[sources]]
id = "work"
title = "Work"
type = "command"
cwd = "~/work"
command = ["fd", "-t", "d", "-d", "2", ".", "."]
```

[Source options and examples](examples/config/sources.toml).

### Custom shortcuts

```toml
[keymap]
"ctrl+j" = "next"
"ctrl+k" = "previous"
"cmd+a" = "none"
```

[Shortcut options and a Ctrl preset](examples/config/keymap.toml).
See [config examples](examples/config) for annotated settings.

## Remote hosts

Your Rex hosts' sessions appear automatically; switching between them needs no
remote resh installation. **Recent** and **Find** also work on remote directories.
With zoxide and fd installed there, run the folder-source adapter installer from
a copy of this checkout on that host:

```sh
bash install.sh --remote
```

## License

[MIT](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution.
