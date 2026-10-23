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

Installs `~/Applications/resh.app`, a `dofile(...)` line and a `--start` command in Rex's config.
The action implementation and Lua resources stay inside the app, not in dotfiles.
The installer preserves personal Rex settings and existing custom startup arguments.
No server restart is necessary.
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
| Esc / Ctrl+[ / click outside | Dismiss without creating a session |
| ⌘⇧Backspace | Close a selected session, **after confirmation** |

The shortcut is scoped to Rex; it intentionally shadows Save inside programs
running in Rex. Native copy, paste, and select-all work in the search field.
Source shortcuts also use physical key positions; ⌘A/C/V/X/Z and ⌘Backspace remain native text
editing shortcuts. The resident helper registers physical Cmd+S with macOS only
while Rex is frontmost. It does not rely on Rex's character/keyboard-layout
matching. There are no duplicate launcher bindings in Rex's keymap. Outside Rex
the hotkey is unregistered, so other apps retain their normal Save shortcut.
This uses Carbon's hotkey API, not an Accessibility event tap.
The same physical-key/typed-text distinction is used in
[Ghostty's event handling](https://github.com/ghostty-org/ghostty/blob/f54340ad77814fe319d136e5e915d6a48de8dd23/macos/Sources/Ghostty/NSEvent%2BExtension.swift#L18).
It is one keycode for every language, not a table of keyboard layouts.

## Compact UI and fresh data

The panel shows session names and shortened folder paths in a single-line list,
sized to its results (up to 12 rows). It opens on the pointer's display and
accepts keyboard input without deactivating Rex.

The resident helper reuses its AppKit controls and a persistent `rex do`
connection (`resh-data.lua`) while Rex is running. Each warm opening reads a fresh
client/session snapshot, without spawning CLI processes or inspecting individual tabs. The native hotkey,
Rex action and CLI all use this same opening path; explicit reloads use the same connection.
While the panel is open, the existing activity stream also updates the session list
on creation, removal and renaming. Combined sources keep their loaded folder rows;
session changes do not rerun filesystem providers or change the selected row's identity.
Hiding clears session and folder data and the query.
Errors wrap and scroll in one compact, selectable field without expanding the panel.

Configuration, filesystem providers and search-index preparation run in the
background. Combined sources show available sessions/projects while providers
load; returning to Sessions is immediate. Search normalizes each list once,
then reuses it for keystrokes until the source changes or the panel closes.
Folder sources are snapshots: leaving and returning to a source reloads it.
Typing only filters the snapshot; there are no folder watchers or periodic scans.

### Lifecycle and background work

- The native AppKit host and controls stay resident for fast opening; the glass
  renderer is unchanged. Switching to another app does not make the connection cold.
- Closing the last Rex app, or putting the Mac to sleep, closes the CLI bridges
  and hides the panel. Launch/wake notifications attempt one preliminary data
  connection; failed connections recover on the next opening, not in a background
  retry loop. There is no hidden polling timer.
- A temporary `launchd` job supervises the host for the current GUI login session.
  Failures restart it; successful `resh --quit` stays stopped until an explicit
  show/start or Rex config reload. Nothing is installed in `~/Library/LaunchAgents`.
  The definition is cached at `~/Library/Caches/resh/launcher.plist`, with only an
  allowlist of launch environment variables, not the caller's full environment.
- Normal bridge shutdown sends SIGTERM, then SIGKILL after 200 ms if necessary,
  without blocking the UI. After a host crash, launchd signals its old process
  group; the data script also exits on stdin EOF. The visible-only activity
  stream writes a tiny heartbeat every 10 seconds to detect a closed reader.
  This is not a Rex API poll.
- Broken snapshot connections (including server EOF returned through Lua) are
  recreated automatically within one five-second deadline. Slow openings show
  `Loading sessions…` in the normal panel; only a failed recovery shows
  `Can’t connect to Rex.` and Retry. Esc cancels the opening. The visible activity
  stream also reconnects without clearing the query, selection or existing dots.
  Each recovered stream starts with a fresh retry deadline for its next disconnect.
  Other API errors, malformed responses and session-changing operations are not retried.

The startup command in Rex's config runs on every Rex launch, including after a
Mac restart. `--start` closes an existing resh host and starts a new one with the
supplied arguments, without opening the panel. Normal hotkeys/openings reuse it.
There is no separate warmup step or persistent custom-config selection in resh.

`resh --status` reports the host PID, connection state, data CLI PID, shutdown state
and native hotkey registration. It does not start a stopped host.

Sessions with an unseen result, a request for user action, or an error show a small
dot beside their name. Running agents and plain idle agents have no indicator;
an idle agent whose completion Rex has announced keeps its unread dot. Activity arrives
through Rex's program-status API and events, asynchronously after the panel opens;
there is no terminal polling. The event connection closes and its data is cleared
when the panel hides. Folder and project rows never show activity dots.

Read receipts are read from Rex's local `Workspace.programActivitySeen` preferences,
so viewing activity in Rex removes the corresponding dot (within a second while
the panel is open). resh never writes read receipts or marks activity read merely
because the picker is open. This reads a private preference format, not an exported
Rex unread-notifications API: unavailable or malformed receipts show an explicit error
and no dots. A missing program-status API or failed activity stream is also reported.
Announced idle reports and read receipts are matched at Rex's millisecond precision. The dot is a native
SF Symbol using Rex's theme `info` color, not a copied private Rex UI component.

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
For a custom path, edit the startup command in Rex's `init.lua`:

```lua
local resh = os.getenv("HOME") .. "/Applications/resh.app"
dofile(resh .. "/Contents/Resources/resh.lua")
rex.exec.start({ resh .. "/Contents/MacOS/resh", "--start", "--config", "/path/to/config.toml" },
  { detach = true, stdout = false, stderr = false })
```

Replace the existing resh startup command; do not add a second one. Reload Rex's
config to restart resh with the new path. After reboot, Rex runs that same command.
`resh.lua` only registers the palette action; it does not start the host itself.
`--config FILE` without `--start` still applies only to that opening; native hotkeys
use the host's startup path. `RESH_CONFIG` remains an environment override.
No config is required: all existing shortcuts and sources keep working.
A file explicitly chosen by `RESH_CONFIG` or `--config` must exist; only the default file is optional.
The resident panel rereads the file on each opening; no restart or Rex config reload
is needed for edits to its contents. A missing/invalid chosen file does not kill
the host or silently use old/default settings. Cmd+S opens the same glass panel
with a selectable error and full file path instead of results. Search and source
actions are disabled; there is no Retry button for configuration errors.
For a wrong path, correct `--config` in Rex's `init.lua` and reload Rex's config.
For invalid contents, fix the file and reopen the panel. No config copy is saved.

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
private material renderer. Missing or incompatible theme data is an error, not a
substitute palette. A failed refresh keeps the last successfully read theme and
shows the error; resh never changes Rex's settings. Unchanged refreshes reuse the
selected palette instead of rereading and parsing the full theme catalog. Cache
inputs include Rex preferences and theme-file metadata; refresh tasks do not pile up.

## CLI & development

```sh
bash scripts/build.sh
swift test
RESH_UI_TESTS=1 swift test --filter PanelTests
dist/resh.app/Contents/MacOS/resh --diagnose
dist/resh.app/Contents/MacOS/resh --name "$PWD"
dist/resh.app/Contents/MacOS/resh --connect "$PWD" --client client:…
```

`--diagnose` and `--name` do not create sessions; `--connect` is deliberately
state-changing. The opt-in AppKit tests check session-title layout, unread indicators
and view reuse. Synthetic rendering tests do not connect to Rex or read its preferences.

Override CLI discovery with `RESH_REX_BIN`; override the Rex application bundle
with `RESH_REX_APP`. Invalid explicit paths are errors, not hints for discovery.
Creation is serialized by a file lock and identities are
saved atomically in `~/Library/Application Support/resh/sessions.json`.
Only the **local macOS Rex server** is supported in this first version.
Multiple local Rex apps share one picker, config and theme. The hotkey identifies
the calling app by `rex_app_pid`; the palette action **Open resh Session Manager**
passes its `client_id` explicitly. CLI calls may pass `--client`. Selecting or
creating a session targets that app; session lists and deletions are shared server
state. The helper never types into an existing terminal or takes a client ID from
another pane's environment. It does not yet follow the app's active remote host.

### Uninstall

Run `~/Applications/resh.app/Contents/MacOS/resh --quit`. Remove the resh `dofile(...)` and `rex.exec.start(...)` lines from Rex's `init.lua`
and run `rex config reload`. Then remove
`~/Applications/resh.app`. Existing Rex sessions remain untouched.
To also unload the stopped session job, run
`launchctl bootout "gui/$(id -u)/io.github.CruelAddict.resh.panel"`
("not found" is harmless), then remove `~/Library/Caches/resh/launcher.plist`.
Logout also unloads the job; the cached plist does not enable automatic login startup.

## License

MIT. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for sesh attribution.
