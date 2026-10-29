# resh

A macOS session manager for [Rex](https://www.superlogical.com/), inspired by
[sesh](https://github.com/joshmedeski/sesh). Focused on blazingly fast session
creation and switching across multiple projects. Designed to feel native to
Rex's stunning UI.

- Fuzzy-find and open frequently visited directories with `zoxide`
- Find other directories with `fd`
- Configure projects with a session name, directory, and startup command (e.g. open
  an editor or start a dev server)
- Switch between local and remote Rex sessions
- Add custom views populated by directory lists or commands
- Customize keyboard shortcuts. Make them tmux-style if that's where you're
  coming from.

## Install

Requires macOS 15+ and Rex. Rex is currently in closed beta and does not provide
a proper API for a plugin such as resh, so things might and will likely break.

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
`$XDG_CONFIG_HOME/resh/config.toml`).

After changing the config, apply the new version with `resh service restart`.

### Projects

A project is a pre-configured session shortcut, e.g.:

```toml
[[session]]
name = "Backend"
path = "~/work/backend"
startup_command = "nvim"
```

[See more in examples](examples/config/projects.toml).

### Custom views

Specify your own command to supply candidates for the picker.

```toml
[[sources]]
id = "work"
title = "Work"
type = "command"
cwd = "~/work"
command = ["fd", "-t", "d", "-d", "2", ".", "."]
```

[See more in examples](examples/config/sources.toml).

### Custom shortcuts

```toml
[keymap]
"ctrl+j" = "next"
"ctrl+k" = "previous"
"cmd+a" = "none"
```

[See more in examples](examples/config/keymap.toml).

## Remote hosts

resh shows the same local and remote sessions you see in Rex.

To have `Recent` and `Find` discover directories on a remote host,
install the remote resh adapter on it:

```sh
bash install.sh --remote
```

The remote machine also needs to have `zoxide` and `fd` configured.

## License

[MIT](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution.
