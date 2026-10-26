# resh

A macOS session manager for [Rex](https://www.superlogical.com/), inspired by
[sesh](https://github.com/joshmedeski/sesh). Fuzzy-find sessions and project
directories.

- Open frequently visited directories with `zoxide`.
- Find other directories with `fd`.
- Configure projects with a session name, directory, and startup command (e.g. open
  an editor or start a dev server).
- Switch between local and remote Rex sessions.
- Add custom views populated by directory lists or commands.
- Customize keyboard shortcuts.

## Install

Requires macOS 15+ and Rex. Rex is currently in closed beta; compatibility may
change between builds.

Enable **Rex Settings → Rex Server → Remote Control** to allow session switching.

To find directories with `Recent` and `Find`, install the optional dependencies
`zoxide` and `fd`:

```sh
brew install zoxide fd
```

Set up [`zoxide` in your shell](https://github.com/ajeetdsouza/zoxide#installation) to
track the directories you visit.

## Using resh

Press `⌘S` in Rex to open resh. Choose the `Sessions` view to switch to an open
session, `Recent` to find a directory you've visited, `Find` to discover another
directory, or `Projects` to open a configured project. Selecting a directory creates
a session there, or returns to the one you opened through resh before.

### Default shortcuts

| Key | Action |
| --- | --- |
| `⌘S` | Open or close resh in Rex |
| `⌘L` | Switch to the previous session in Rex |
| `⌘E` | `Sessions` — switch to an open session |
| `⌘R` | `Recent` — open a `zoxide` directory as a session |
| `⌘F` | `Find` — search directories under your home folder with `fd` |
| `⌘P` | `Projects` — open a configured project |
| `⌘A` | `All` — sessions, configured projects, and recently visited directories |
| `⌘1–9` | Open by number |
| `⌘⇧P` | Pin or unpin the selected session |
| `⌘⇧N` | Create a session named after the search text |
| `⌘⇧D` | Immediately close the selected session and its programs |
| `↑` / `↓`, `⌃P` / `⌃N` | Move through the list |
| `Enter` | Open the selection |
| `Esc` / `⌃[` | Close the picker |

## Configuration

Put settings in `~/.config/resh/config.toml` (or
`$XDG_CONFIG_HOME/resh/config.toml`). Edits apply without restarting.

### Projects

Configure a project's session name, directory, and optional startup command:

```toml
[[session]]
name = "Backend"
path = "~/work/backend"
startup_command = "nvim"
```

[Project configuration](examples/config/projects.toml).

### Custom views

Add a `Work` view that finds directories under `~/work`:

```toml
[[sources]]
id = "work"
title = "Work"
type = "command"
cwd = "~/work"
command = ["fd", "-t", "d", "-d", "2", ".", "."]
```

[View configuration](examples/config/sources.toml).

### Custom shortcuts

```toml
[keymap]
"ctrl+j" = "next"
"ctrl+k" = "previous"
"cmd+a" = "none"
```

[Shortcut configuration](examples/config/keymap.toml).
See [all configuration examples](examples/config).

## Remote hosts

resh shows the same local and remote sessions you see in Rex.

To also use `Recent` and `Find` to discover directories on a remote host, install
`zoxide` and `fd` there, set up `zoxide` in that host's shell, and install the source
adapter from a copy of this checkout on that host:

```sh
bash install.sh --remote
```

## License

[MIT](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution.
