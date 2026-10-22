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

## Compact UI and fresh data

There is no title/header, theme-name badge, footer, result-kind badge, or result
icon. A session occupies one 26-point row containing only its name; folders show
their shortened path on one line. The panel sizes to its results (up to 12 rows),
instead of reserving a large empty area. The outer padding is 8 points on all
sides. Search uses a capsule-shaped field, and selected rows use Rex's UI accent.
Search → sources and sources → results also have 8-point gaps, including when
filtering leaves a single row. This follows the grouping/alignment principles in
[Apple's layout guidance](https://developer.apple.com/design/human-interface-guidelines/layout),
not a claim that Apple mandates one spacing value for every interface.

The native shortcut reads `client.list` and `session.list` over one persistent,
supported `rex do` connection (`resh-data.lua`). Each opening reads a **fresh snapshot**;
there are no new CLI processes on this path. The command-palette Lua action can
also pass a fresh snapshot to the helper. There is no session cache.
There are no per-session/tab/process queries on the
list path. zoxide and filesystem search run only when their source is requested;
switching back to Sessions does not wait for them. The UI uses AppKit controls.

The native helper now stays resident: Rex's config warms it once, and each shortcut
reuses its data connection and AppKit controls. Command-palette invocations use a
small Foundation-only IPC sender rather than relaunching AppKit. The same
window, text editor, and glass view are reused. Each invocation replaces its data
with a fresh server snapshot; hiding the panel clears sessions, folders and query.
There is no saved session-list cache and no login agent. `resh --quit` stops the
helper; reloading Rex's config or running `resh --warmup` starts it again.
`resh --status` reports its state and native hotkey registration.

The non-activating panel accepts keyboard input without deactivating or dimming Rex.
It opens on the display containing the pointer. Opening never enumerates other
apps' windows: that WindowServer call can stall for hundreds of milliseconds.
Smoke reports measure `requestToPanelMs` separately from one-time application startup.

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
dist/resh.app/Contents/MacOS/resh --diagnose
dist/resh.app/Contents/MacOS/resh --name ~/personal/resh
dist/resh.app/Contents/MacOS/resh --connect ~/personal/resh --client client:…
dist/resh.app/Contents/MacOS/resh --smoke-test "$PWD/.build/ui-smoke"
python3 scripts/smoke.py
```

`--diagnose`, `--name`, and the UI smoke test do not create sessions. The smoke
test saves a JSON report and a view snapshot, including startup timing,
layout-independent input routing, and actual native text-field input; it does not need Accessibility or
screen-recording permissions. `scripts/smoke.py` verifies reuse of one process,
new snapshots on each opening, native editing, equal padding, and data clearing
on dismissal. Its synthetic session rows exist only in the UI, not in Rex.
`--native-hotkey-smoke PATH` exercises the Carbon callback and full live data path
while Rex is frontmost; it does not synthesize a physical OS keypress or require
Accessibility. Real keyboard testing is a separate check.
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
