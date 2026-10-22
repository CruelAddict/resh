# resh

A compact native macOS session/folder picker for **Rex**, inspired by **sesh**.
Press **⌘S** in Rex, fuzzy-find a folder, and open it as a named Rex session.
No tmux, fzf, Electron, Accessibility permission, or background daemon required.

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
editing shortcuts. The picker exits when closed. Repeated launches bring the existing panel forward.

## Compact UI and fresh data

There is no title/header, theme-name badge, footer, result-kind badge, or result
icon. A session occupies one 26-point row containing only its name; folders show
their shortened path on one line. The panel sizes to its results (up to 12 rows),
instead of reserving a large empty area.

The Rex Lua action reads `session.list` directly and passes that **fresh snapshot**
to the helper, so sessions exist before the first paint. No session cache or
resident helper is needed. There are no per-session/tab/process queries on the
list path. zoxide and filesystem search run only when their source is requested;
switching back to Sessions does not wait for them. The UI uses AppKit controls.
This removes late session-list loading, not the cost of cold-starting a macOS
application. The smoke report measures that separately as `panelReadyMs`; no
resident process or persisted session cache is used to hide it.

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

Unlike sesh, resh does not yet import `sesh.toml` startup/window presets or
tmuxinator projects. Those were not configured in the original installation.
There is no presets source because there are no configured sesh presets to show.

## Theme

Each launch reads Rex's selected light/dark theme and interface style.
Built-in palettes are read from Rex's bundled `themes.json`; imported/custom
palettes come from its preferences. Colors and style refresh while the panel is
open. Glass uses native `NSGlassEffectView` on macOS 26+, with an
`NSVisualEffectView` fallback on macOS 15. Classic or Reduce Transparency uses
a solid theme background. This is a matching companion, not a copy of Rex's
private material renderer. If Rex changes its internal formats, resh falls back
to a system palette rather than changing Rex's settings.

## CLI & development

```sh
bash scripts/build.sh
dist/resh.app/Contents/MacOS/resh --diagnose
dist/resh.app/Contents/MacOS/resh --name ~/personal/resh
dist/resh.app/Contents/MacOS/resh --connect ~/personal/resh --client client:…
dist/resh.app/Contents/MacOS/resh --smoke-test "$PWD/.build/ui-smoke"
```

`--diagnose`, `--name`, and the UI smoke test do not create sessions. The smoke
test saves a JSON report and a view snapshot, including startup timing,
layout-independent input routing, and actual native text-field input; it does not need Accessibility or
screen-recording permissions. `--connect` is deliberately state-changing.

Override CLI discovery with `RESH_REX_BIN`; override the Rex application bundle
with `RESH_REX_APP`. Creation is serialized by a file lock and identities are
saved atomically in `~/Library/Application Support/resh/sessions.json`.
Only the **local macOS Rex server** is supported in this first version. The
helper captures the client that invoked the Lua action; it never types into an
existing terminal or takes a client ID from another pane's environment.

### Uninstall

Remove the marked resh `dofile(...)` line from Rex's `init.lua`, remove
`resh.lua` beside it, and run `rex config reload`. Then remove
`~/Applications/resh.app`. The backup directory contains previous configuration
and app versions. Existing Rex sessions remain untouched.

## License

MIT. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for sesh attribution.
