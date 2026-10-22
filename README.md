# resh

A compact native macOS session/folder picker for **Rex**, inspired by **sesh**.
Press **⌘S** in Rex, fuzzy-find a folder, and open it as a named Rex session.
No tmux, fzf, Electron, or Accessibility permission required.

## Build & install

Requires macOS 15+, Xcode 26+ (Swift 6 and the macOS 26 SDK), and Rex with its local server running.
`zoxide` supplies recent/frequent directories; `fd` supplies filesystem search.

```sh
swift test
python3 scripts/install.py
```

Installs `~/Applications/resh.app` and a Lua action in Rex's config. Existing
configuration is preserved and backed up under
`~/Library/Application Support/resh/backups/`. No server restart is necessary.
Enable **Rex Settings → Rex Server → Remote Control** so the helper can ask Rex
to show the selected session. This is a Rex permission, not macOS Accessibility.

## Keyboard

| Key | Action |
| --- | --- |
| ⌘S in Rex | Open the native panel (physical S key, on any keyboard layout) |
| ⌘1 | Existing Rex sessions (initial source, like the original sesh binding) |
| ⌘2 | Sessions + zoxide folders |
| ⌘3 | Recent/frequent folders, in zoxide order |
| ⌘4 | `fd -H -d 2 -t d -E .Trash . ~` |
| ↑ / ↓, Tab / Shift-Tab, ⌃P / ⌃N | Select a result |
| Return / click | Switch or create |
| Esc / click outside | Dismiss without creating a session |
| ⌘⇧Backspace | Close a selected session, **after confirmation** |

The shortcut is scoped to Rex; it intentionally shadows Save inside programs
running in Rex. Native copy, paste, and select-all work in the search field.
Source shortcuts also use physical key positions; ⌘A/C/V/X/Z and ⌘Backspace remain native text
editing shortcuts. The resident helper registers physical Cmd+S with macOS only
while Rex is frontmost. It does not rely on Rex's character/keyboard-layout
matching (or on a Unicode binding, which older Rex parsers reject). Outside Rex
the hotkey is unregistered, so other apps retain their normal Save shortcut.
This uses Carbon's hotkey API, not an Accessibility event tap.
The same physical-key/typed-text distinction is used in
[Ghostty's event handling](https://github.com/ghostty-org/ghostty/blob/f54340ad77814fe319d136e5e915d6a48de8dd23/macos/Sources/Ghostty/NSEvent%2BExtension.swift#L18).
It is one keycode for every language, not a table of keyboard layouts.

### Optional tmux-like Rex shortcuts

The picker keymap below configures **resh**, not Rex's terminals and tabs.
For tmux-style control of **Rex itself**, copy
[`integration/rex-tmux.lua`](integration/rex-tmux.lua) to `~/.config/rex/rex-tmux.lua`
and load it **after** `resh.lua` in Rex's `init.lua`:

```lua
dofile(os.getenv("HOME") .. "/.config/rex/rex-tmux.lua")
```

Then run `rex config check` and use **Reload Config in the Rex app**. From the CLI:

```sh
rex client ls
rex -C CLIENT do client.config.reload
```

Replace `CLIENT` with the app's label or ID from the listing. This explicitly
refreshes the client as well as the server. If `rex keymap` shows new bindings
but keypresses still use the old ones, a server-only `rex config reload` was not
sufficient: reload through the app instead. Both ordinary N/P and held-Ctrl
N/P were verified in the live app, including with the Russian input layout.

This is an opt-in profile;
the resh installer preserves it and never replaces it. Edit the installed Lua
file to change Rex's bindings; edit `~/.config/resh/config.toml` to change the picker.

Press **Ctrl+A**, release it, then press the command:

| After Ctrl+A | Rex action |
| --- | --- |
| c / n / p | New / next / previous tab |
| 0…9 | Tabs 1…10 (tmux's zero-based numbering) |
| % / " | Split right / below |
| h / j / k / l or arrows | Focus a pane |
| o / z / x | Next pane / zoom / close pane |
| s / Shift+S / Shift+K | Select / create / close a session |
| , / $ | Rename tab / session |
| Ctrl+S | Open resh |
| Ctrl+A | Send a literal Ctrl+A to the terminal |

For n/p you can keep Ctrl held after the prefix: Ctrl+A then Ctrl+N/Ctrl+P
also switches tabs, just like tmux. Ctrl+A then Ctrl+S still opens resh.
Escape cancels an unfinished prefix. Physical keys work across input layouts;
Cmd shortcuts remain available. This is not a tmux emulator: copy-mode, tmux
plugins, last-window (`Ctrl+A Ctrl+L`), and hidden-pane join/break scripts are
not ported by this profile.

## Compact UI and fresh data

The panel shows session names and shortened folder paths in a single-line list,
sized to its results (up to 12 rows). It opens on the pointer's display and
accepts keyboard input without deactivating Rex.

The resident helper reuses its AppKit controls and a persistent `rex do`
connection (`resh-data.lua`). Each opening reads a fresh client/session snapshot,
without spawning CLI processes or inspecting individual tabs. The command-palette
action passes its own fresh snapshot through IPC. Hiding clears session and
folder data and the query.

Configuration, filesystem providers and search-index preparation run in the
background. Combined sources show available sessions/projects while providers
load; returning to Sessions is immediate. Search normalizes each list once,
then reuses it for keystrokes until the source changes or the panel closes.

`resh --quit` stops the helper; `resh --warmup` or reloading Rex's config starts
it. `resh --status` reports its state and native hotkey registration. Smoke
reports separate `requestToPanelMs` from one-time application startup.

## Naming and reuse

- Plain directory → its basename.
- Git repository/subdirectory → `repository/relative/path`.
- Worktrees with a shared `.bare` directory → `repository/worktree/path`.
- Resolve symlinks; replace `.` and `:` with `_`, as sesh 2.17.1 does.
- Reuse the same session for a canonical folder, even after `cd` inside it.
- Same names in different directories do **not** collide: use `parent/name`,
  then a stable short path hash when necessary.
- Never infer a session's identity from a tab's current directory: Rex sessions
  do not have one global working directory. Folder reuse uses resh's explicit
  creation records; unregistered sessions remain available by name.
- Never rename or close pre-existing sessions automatically.

## Configuration

Create `~/.config/resh/config.toml` (or `$XDG_CONFIG_HOME/resh/config.toml`).
Use `RESH_CONFIG=/path/to/config.toml` or `resh --config FILE` to choose another file.
`--config` applies to that invocation; native hotkeys use the resident helper's
default configuration path. The default can be set when starting the helper.
No config is required: all existing shortcuts and sources keep working.
The resident panel rereads the file on each opening; no restart or Rex config reload
is needed. Invalid changes show an error and keep the last valid configuration
for that file; switching files starts from the defaults.

```toml
# Optional: order of visible sources. Omitted sources are hidden from the source bar.
source_order = ["sessions", "all", "configs", "work", "repositories"]
initial_source = "sessions"

[keymap]
"ctrl+t" = "source:sessions"
"ctrl+a" = "source:all"
"ctrl+g" = "source:configs"
"ctrl+w" = "source:work"
"ctrl+f" = "source:repositories"
"ctrl+n" = "next"
"ctrl+p" = "previous"
"ctrl+tab" = "next_source"
"ctrl+shift+tab" = "previous_source"
"ctrl+r" = "reload"
# "cmd+1" = "none"  # remove a default binding

[[session]]
name = "Backend"
path = "~/work/backend"
startup_command = "nvim"

[[session]]
name = "Notes"
path = "~/notes"

[[sources]]
id = "work"
title = "Work"
type = "paths"
paths = ["~/work/backend", "~/work/frontend"]

[[sources]]
id = "repositories"
title = "Repositories"
type = "command"
cwd = "~/work"
command = ["fd", "-t", "d", "-d", "2", ".", "."]
format = "paths"
timeout = 5
```

**Keymaps.** Bindings extend the defaults; `"none"` removes a binding. Actions:
`next`, `previous`, `open`, `dismiss`, `delete` (still confirms), `reload`,
`next_source`, `previous_source`, and `source:ID`. Modifiers are `cmd`, `ctrl`,
`alt`/`option`, and `shift`. Keys use US physical positions, so `ctrl+t` also
works with the Russian layout. Modifiers match exactly. Shifted symbols are
written as `shift+5`, not `%`. UI shortcut hints follow the configuration.
Unconfigured keys keep native text editing; binding Ctrl+A or Ctrl+F deliberately
replaces its editing action. The Rex-scoped **Cmd+S launcher** is unchanged;
these bindings apply only inside the picker.

**Sources.** Built-in IDs are `sessions`, `all`, `directories` (zoxide), `find`
(fd), and `configs` (named projects). Projects appear automatically when there
are `[[session]]` entries. Custom sources are appended unless `source_order`
is specified. The source bar scrolls horizontally when necessary.
Supported types: `sessions`, `zoxide`, `find`, `projects`, `paths`, `command`,
and `union`. A union lists member IDs in `sources = ["sessions", "work"]`,
preserving their order and deduplicating paths. Cycles are rejected. Built-in
sources can be redefined by ID. The default `all` combines sessions, named
projects and zoxide; it does not run every custom command.

**Commands.** A command source returns UTF-8 directory paths, one per line.
Relative output paths resolve against `cwd`; config paths and `cwd` resolve
relative to the config file. `~` expands in paths, `cwd`, and the executable,
not in arbitrary command arguments. Commands use an argument array, **not a
shell**: pipes, redirects and variable expansion require an explicitly chosen
shell/script. Sources run asynchronously only when requested, with cancellation,
a 5-second default timeout (configurable up to 60), a 2 MiB output limit and
a 20,000-path limit. Missing folders are skipped. Nothing in the returned list
is executed as a command. Lists are refreshed on each opening and source selection.

**Named projects.** `[[session]]` uses sesh's `name`, `path`, and
`startup_command` fields. `[default_session] startup_command = "nvim"` supplies
a default for folders and projects; an empty per-project command disables it.
A matching project keeps its name and command even when found through zoxide or
a custom list. Startup input is part of creating a **new** Rex terminal; it is
never typed into an existing session, and reconnects do not rerun it. `{}` in a
startup command expands to the shell-quoted project path. Startup commands are
trusted shell code from your config. `resh --connect NAME` also resolves named
projects. This is not a full `sesh.toml` importer: tmux window presets,
tmuxinator/tmuxp, and arbitrary URL/actions are not supported.

Validate without running sources or creating sessions:

```sh
~/Applications/resh.app/Contents/MacOS/resh --check-config
```

See [`integration/config.example.toml`](integration/config.example.toml) for a
sesh/fzf-style Ctrl preset. It is opt-in and is never installed over your config.

## Theme

Each launch reads Rex's selected light/dark theme and interface style.
Built-in palettes are read from Rex's bundled `themes.json`; imported/custom
palettes come from its preferences. UI colors use Rex's bundled semantic tokens,
not the terminal's ANSI blue or text-selection color. Colors and style refresh while
the panel is open. Glass uses native `NSGlassEffectView` on macOS 26+, with an
`NSVisualEffectView` fallback on macOS 15. Classic or Reduce Transparency uses
a solid theme background. This is a matching companion, not a copy of Rex's
private material renderer. If Rex changes its internal formats, resh falls back
to a system palette rather than changing Rex's settings.

## CLI & development

```sh
bash scripts/build.sh
swift test
RESH_UI_TESTS=1 swift test --filter nativePanelInputAndReuse
dist/resh.app/Contents/MacOS/resh --diagnose
dist/resh.app/Contents/MacOS/resh --name ~/personal/resh
dist/resh.app/Contents/MacOS/resh --connect ~/personal/resh --client client:…
dist/resh.app/Contents/MacOS/resh --smoke-test "$PWD/.build/ui-smoke"
python3 scripts/smoke.py
python3 scripts/record-demo.py
```

`--diagnose`, `--name`, and the UI smoke test do not create sessions. The smoke
test saves startup/presentation timings, a `resultsReady` stage and a view snapshot. `scripts/smoke.py`
checks process reuse, fresh synthetic session snapshots and data clearing on
dismissal, using an isolated configuration. The opt-in AppKit test checks physical
shortcuts, native editing, navigation and panel reuse without connecting to Rex.
`--native-hotkey-smoke PATH` exercises the Carbon callback and full live data path
while Rex is frontmost; it does not synthesize a physical OS keypress or require
Accessibility. Real keyboard testing is a separate check.

`scripts/record-demo.py` records the same AppKit test with FFmpeg (no audio),
using synthetic input and session data. It requires screen-recording permission,
but not Accessibility or a Rex connection. Only the video and JSON report are
retained in `~/Movies/resh`; temporary folders are removed.
`--connect` is deliberately state-changing. `--once --smoke-test PATH` runs an
isolated, short-lived UI test instead of using the resident helper.

Override CLI discovery with `RESH_REX_BIN`; override the Rex application bundle
with `RESH_REX_APP`. Creation is serialized by a file lock and identities are
saved atomically in `~/Library/Application Support/resh/sessions.json`.
Only the **local macOS Rex server** is supported in this first version. The
helper captures the client that invoked the Lua action; it never types into an
existing terminal or takes a client ID from another pane's environment.

### Uninstall

Run `~/Applications/resh.app/Contents/MacOS/resh --quit`. Remove the marked resh `dofile(...)` line from Rex's `init.lua`, remove
`resh.lua` beside it, and run `rex config reload`. Then remove
`~/Applications/resh.app`. The backup directory contains previous configuration
and app versions. Existing Rex sessions remain untouched.

## License

MIT. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for sesh attribution.
