#!/usr/bin/env bash
# Shared Rex setup for standalone installations, Homebrew, and remote adapters.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: resh setup [options]
  --config FILE       Rex config file (required for a custom server config)
  --yes               Apply changes without prompting
  --source DIRECTORY  Distribution directory (supplied by resh)
  --remote            Install only the remote folder-source adapter

Rex must be installed and running as the installing account.
Setup previews the configuration change and saves a backup before applying it.
EOF
}

say() { printf '%s\n' "$*"; }
die() { printf 'resh: %s\n' "$*" >&2; exit 1; }

parse_options() {
    while (( $# > 0 )); do
        case "$1" in
            --remote) remote=true; shift ;;
            --yes) yes=true; shift ;;
            --source|--config)
                [[ $# -ge 2 && -n $2 ]] || die "Missing value for $1"
                case "$1" in
                    --source) source_dir=$2 ;;
                    --config) config=$2; explicit_config=true ;;
                esac
                shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

resolve_config_path() {
    local path=$1 target depth=0
    while [[ -L $path ]]; do
        (( depth < 32 )) || die "Too many config symlinks: $1"
        target=$(readlink "$path") || return 1
        case "$target" in
            /*) path=$target ;;
            *) path="${path%/*}/$target" ;;
        esac
        depth=$((depth + 1))
    done
    printf '%s\n' "$path"
}

configure_environment() {
    local platform
    platform=$(uname -s)
    [[ $remote == true || $platform == Darwin ]] || die 'resh requires macOS. Use --remote on a remote Rex host.'
    export PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin"
    unset REX_SESSION REX_BLOCK REX_CLIENT REX_SERVER
    case "$config" in
        '') config=${REX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua} ;;
        /*) ;;
        *) config="$PWD/$config" ;;
    esac
    tools_reference=${RESH_TOOLS:-${XDG_CONFIG_HOME:-$HOME/.config}/resh/tools.lua}
    destination="$HOME/Library/Application Support/resh"
    if [[ $remote == true ]]; then destination="${XDG_DATA_HOME:-$HOME/.local/share}/resh"; fi
    local path
    for path in "$HOME" "$config" "$tools_reference" "$destination"; do
        [[ $path == /* ]] || die "Installation paths must be absolute: $path"
    done
    config=$(resolve_config_path "$config")
    rex_bin=${RESH_REX_BIN:-$(type -P rex || true)}
    if [[ -z $rex_bin && $platform == Darwin ]]; then
        rex_bin="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
    fi
    [[ -n $rex_bin && -x $rex_bin ]] || die 'Rex CLI not found. Install/start Rex first, or set RESH_REX_BIN.'
    rex_command=("$rex_bin" --autostart=false --timeout 40s)
}

rex_lua() { "${rex_command[@]}" "do" - "$@"; }

check_rex() {
    local pid command
    pid=$(rex_lua "account=$(id -un)" <<'LUA'
local identity = assert(rex.call("server.whoami"))
assert(identity.principal.transport == "unix" and identity.account == rex.args.account,
  "Run setup on the Rex host, as the OS account that runs that server.")
io.write(tostring(assert(rex.call("server.status")).pid), "\n")
LUA
    )
    if [[ $explicit_config == false ]]; then
        command=$(ps -ww -p "$pid" -o command=)
        [[ ! $command =~ --config[[:space:]=] ]] || die 'This server uses a custom config. Pass --config FILE explicitly.'
    fi
}

find_source() {
    [[ -n $source_dir ]] || die 'Missing distribution directory. Run resh setup from an installed or unpacked release.'
    source_dir=$(cd -- "$source_dir" && pwd)
    if [[ $remote == true ]]; then
        module_source="$source_dir/rex-actions.lua"
        [[ -f $module_source ]] || module_source="$source_dir/integration/rex-actions.lua"
        [[ -r $module_source ]] || die 'Missing rex-actions.lua in the distribution.'
        module="$destination/rex-actions.lua"
    else
        if [[ -f $source_dir/.resh-prefix ]]; then
            # The formula records its opt path so links survive brew upgrades.
            IFS= read -r source_dir < "$source_dir/.resh-prefix"
            [[ $source_dir == /* ]] || die 'Invalid Homebrew installation prefix.'
            source_dir=$(cd -- "$source_dir" && pwd)
            linked=true
        fi
        bundle=$source_dir
        [[ -x $bundle/resh && -r $bundle/resh.lua && -d $bundle/resh_Resh.bundle ]] || die 'Missing prebuilt picker. Run bash scripts/build.sh or use a macOS release.'
        local name
        for name in LICENSE resh_Resh.bundle/Contents/Resources/ThirdPartyNotices.txt; do
            [[ -r $bundle/$name ]] || die "Missing $name in the distribution."
        done
        module="$destination/resh.lua"
        module_source="$bundle/resh.lua"
    fi
}

snapshot_file() {
    if [[ -L $1 ]]; then
        [[ ! -d $1 ]] || die "Not a readable file: $1"
        ln -s "$(readlink "$1")" "$2"
        touch "$2.exists"
    elif [[ -e $1 ]]; then
        [[ -f $1 && -r $1 ]] || die "Not a readable file: $1"
        cp -p "$1" "$2"
        touch "$2.exists"
    else
        : > "$2"
    fi
}

unchanged() {
    if [[ -f $2.exists ]]; then
        if [[ -L $2 ]]; then
            [[ -L $1 && $(readlink "$1") == "$(readlink "$2")" ]]
        else
            [[ -f $1 && ! -L $1 ]] && cmp -s "$1" "$2"
        fi
    else
        [[ ! -e $1 && ! -L $1 ]]
    fi
}

prepare_rex_config() {
    rex_lua "input=$work/config.before" "output=$work/config.after" "remote=$remote" \
        "module=$module" "tools=$tools_reference" "executable=$destination/resh" <<'LUA'
local args = rex.args
local file = assert(io.open(args.input, "rb"))
local text = assert(file:read("*a")); file:close()
local integration = args.remote
  and "assert(loadfile(" .. string.format("%q", args.module) .. "))(" .. string.format("%q", args.tools) .. ")"
  or "dofile(" .. string.format("%q", args.module) .. ")"
local found = text:find(integration, 1, true) ~= nil
if not args.remote and not found then
  for argument in text:gmatch("dofile%s*%(([^\n%)]+)%)") do
    if argument:find(args.module, 1, true) then found = true end
  end
end
local additions = {}
if not found then additions[#additions + 1] = integration end
if not args.remote then
  local startup = false
  for arguments in ("\n" .. text):gmatch("\n[ \t]*rex%.exec%.start%s*%(%s*{(.-)}") do
    if arguments:find("resh", 1, true) and arguments:match("['\"]service['\"]%s*,%s*['\"]start['\"]") then startup = true end
  end
  if not startup then
    additions[#additions + 1] = "rex.exec.start({ " .. string.format("%q", args.executable) .. ", \"service\", \"start\" },\n  { detach = true, stdout = false, stderr = false })"
  end
end
if #additions > 0 then
  text = text .. (text == "" and "" or "\n") .. "-- >>> resh >>>\n"
    .. table.concat(additions, "\n") .. "\n-- <<< resh <<<\n"
end
local output = assert(io.open(args.output, "wb"))
assert(output:write(text)); assert(output:close())
LUA
    touch "$work/config.after.exists"
}

confirm_setup() {
    say 'This will install resh files and reload the Rex configuration.'
    say "Rex config: $config"
    say "resh files: $destination"
    if [[ $linked == true ]]; then say "Homebrew source: $bundle (linked, not copied)"; fi
    if cmp -s "$work/config.before" "$work/config.after"; then
        say 'Rex integration is already configured; the config will be preserved.'
    else
        diff -u "$work/config.before" "$work/config.after" || true
    fi
    if [[ $yes == true ]]; then return 0; fi
    local answer
    if ! IFS= read -r -p 'Continue with installation? [y/N] ' answer < /dev/tty; then
        die 'Confirmation requires a terminal. Use --yes to apply changes non-interactively.'
    fi
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) say 'Installation cancelled.'; return 1 ;;
    esac
}

atomic_copy() {
    local source=$1 target=$2 preserve_mode=${3:-false} status=0
    [[ ! -d $target ]] || die "Not a file: $target"
    mkdir -p -- "${target%/*}" || return 1
    pending_file=$(mktemp "${target%/*}/.resh-setup.XXXXXX") || return 1
    if [[ -L $source ]]; then
        rm -f -- "$pending_file"
        ln -s "$(readlink "$source")" "$pending_file" || status=$?
    elif [[ $preserve_mode == true && -f $target && ! -L $target ]]; then
        cp -p "$target" "$pending_file" && cat "$source" > "$pending_file" || status=$?
    else
        cp -p "$source" "$pending_file" || status=$?
    fi
    if (( status == 0 )); then mv -f -- "$pending_file" "$target" || status=$?; fi
    if (( status != 0 )); then rm -f -- "$pending_file"; fi
    pending_file=
    return "$status"
}

install_native() {
    "$bundle/resh" service stop >/dev/null
    if [[ $bundle -ef $destination ]]; then return 0; fi
    local name
    for name in resh LICENSE; do
        if [[ $linked == true ]]; then
            ln -s "$bundle/$name" "$work/$name.link"
            atomic_copy "$work/$name.link" "$destination/$name"
        else
            atomic_copy "$bundle/$name" "$destination/$name"
        fi
    done
    # Replace only our resources; retain personal configuration and history.
    rm -rf -- "$destination/resh_Resh.bundle"
    if [[ $linked == true ]]; then
        ln -s "$bundle/resh_Resh.bundle" "$destination/resh_Resh.bundle"
    else
        cp -R "$bundle/resh_Resh.bundle" "$destination/resh_Resh.bundle"
    fi
}

restore_file() {
    local path=$1 before=$2 after=$3
    if [[ -f $after.exists ]] && unchanged "$path" "$after"; then
        if [[ -f $before.exists ]]; then
            atomic_copy "$before" "$path" || printf 'resh: Could not restore %s\n' "$path" >&2
        else
            rm -f -- "$path"
        fi
    fi
}

cleanup() {
    local status=$?
    trap - EXIT
    set +e
    [[ -z $pending_file ]] || rm -f -- "$pending_file"
    pending_file=
    if [[ $applied == true && $committed == false ]]; then
        restore_file "$config" "$work/config.before" "$work/config.after"
        restore_file "$module" "$work/module.before" "$work/module.after"
        if [[ $reload_attempted == true ]] && unchanged "$config" "$work/config.before"; then
            "${rex_command[@]}" config reload >/dev/null 2>&1
        fi
    fi
    [[ -z $work ]] || rm -rf -- "$work"
    exit "$status"
}

main() {
    remote=false yes=false linked=false
    source_dir="" config=""
    explicit_config=false
    work="" pending_file="" module=""
    applied=false committed=false reload_attempted=false
    parse_options "$@"
    configure_environment
    find_source
    check_rex
    umask 077
    work=$(mktemp -d "${TMPDIR:-/tmp}/resh-setup.XXXXXX")
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    snapshot_file "$config" "$work/config.before"
    prepare_rex_config
    snapshot_file "$module" "$work/module.before"
    if [[ $linked == true ]]; then
        ln -s "$module_source" "$work/module.after"
    else
        cp -p "$module_source" "$work/module.after"
    fi
    touch "$work/module.after.exists"
    if ! confirm_setup; then return 0; fi

    unchanged "$config" "$work/config.before" || die 'Rex config changed during setup; refusing to overwrite concurrent edits.'
    if [[ $remote == false ]]; then install_native; fi
    applied=true
    atomic_copy "$work/module.after" "$module" true
    unchanged "$config" "$work/config.before" || die 'Rex config changed during setup; refusing to overwrite concurrent edits.'
    if [[ -f $work/config.before.exists ]] && ! cmp -s "$work/config.before" "$work/config.after"; then
        local backup
        backup=$(mktemp "$config.resh-backup-XXXXXX")
        cp -p "$work/config.before" "$backup"
        say "Rex config backup: $backup"
    fi
    if [[ ! -f $config ]] || ! cmp -s "$config" "$work/config.after"; then
        atomic_copy "$work/config.after" "$config" true
    fi
    "${rex_command[@]}" config check "$config" --json >/dev/null
    unchanged "$config" "$work/config.after" || die 'Rex config changed during setup; reload was not attempted.'
    reload_attempted=true
    "${rex_command[@]}" config reload >/dev/null
    committed=true
    say "Connected resh to Rex: $config"
    if [[ $remote == false ]]; then say 'Rex Server → Remote Control must be enabled for session switching.'; fi
}

main "$@"
