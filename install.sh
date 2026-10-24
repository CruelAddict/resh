#!/usr/bin/env bash
# Install from a checkout, an unpacked distribution, or a checksummed release.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bash install.sh local|remote [options]
  --source DIRECTORY       Use a checkout or unpacked distribution
  --config FILE            Rex config file (required for a custom server config)
  --repository OWNER/REPO  Download a checksummed GitHub release
  --version TAG            Release tag (default: latest)

Rex must already be installed and running as the installing account.
Remote mode installs only Lua files; local mode requires a prebuilt macOS bundle.
EOF
}

say() { printf '%s\n' "$*"; }
die() { printf 'resh: %s\n' "$*" >&2; exit 1; }

parse_options() {
    case "${1:-}" in
        local|remote) mode=$1; shift ;;
        ''|-h|--help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac

    while (( $# > 0 )); do
        case "$1" in
            --source|--config|--repository|--version)
                [[ $# -ge 2 && -n $2 ]] || die "Missing value for $1"
                case "$1" in
                    --source) source_dir=$2 ;;
                    --config) config=$2; explicit_config=true ;;
                    --repository) repository=$2 ;;
                    --version) version=$2 ;;
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
    platform=$(uname -s)
    [[ $mode != local || $platform == Darwin ]] || die 'The native picker requires macOS. Use remote mode on this machine.'

    export PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin"
    # Never inherit the terminal's session, remote target, or selected client.
    unset REX_SESSION REX_BLOCK REX_CLIENT REX_SERVER

    case "$config" in
        '') config=${REX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua} ;;
        /*) ;;
        *) config="$PWD/$config" ;;
    esac
    tools_reference=${RESH_TOOLS:-${XDG_CONFIG_HOME:-$HOME/.config}/resh/tools.lua}
    destination="${XDG_DATA_HOME:-$HOME/.local/share}/resh"
    if [[ $mode == local ]]; then
        destination="$HOME/Library/Application Support/resh"
    fi
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

# These small scripts use Rex's interpreter for its API and Lua config files.
# File installation and rollback stay in Bash.
rex_lua() { "${rex_command[@]}" do - "$@"; }

check_rex() {
    local pid command
    pid=$(rex_lua "account=$(id -un)" <<'LUA'
local identity = assert(rex.call("server.whoami"))
assert(identity.principal.transport == "unix" and identity.account == rex.args.account,
  "Run the installer on the Rex host, as the OS account that runs that server.")
io.write(tostring(assert(rex.call("server.status")).pid), "\n")
LUA
    )
    if [[ $explicit_config == false ]]; then
        command=$(ps -ww -p "$pid" -o command=)
        [[ ! $command =~ --config[[:space:]=] ]] || die 'This server uses a custom config. Pass --config FILE explicitly.'
    fi
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

download_release() {
    local artifact base expected arch
    [[ $repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'Pass --repository OWNER/REPO (or RESH_REPOSITORY), or --source DIRECTORY.'
    [[ $version =~ ^[A-Za-z0-9._-]+$ ]] || die 'Invalid release tag.'

    artifact=resh-remote.tar.gz
    if [[ $mode == local ]]; then
        case "$(uname -m)" in
            arm64|aarch64) arch=arm64 ;;
            x86_64) arch=x86_64 ;;
            *) die 'Unsupported macOS architecture.' ;;
        esac
        artifact="resh-macos-$arch.tar.gz"
    fi
    base="https://github.com/$repository/releases"
    if [[ $version == latest ]]; then
        base+='/latest/download'
    else
        base+="/download/$version"
    fi

    curl --proto '=https' --proto-redir '=https' -fsSL "$base/$artifact" -o "$work/archive.tar.gz"
    curl --proto '=https' --proto-redir '=https' -fsSL "$base/checksums.txt" -o "$work/checksums.txt"
    expected=$(awk -v name="$artifact" '$2 == name { print $1 }' "$work/checksums.txt")
    [[ $expected =~ ^[a-fA-F0-9]{64}$ ]] || die 'Release checksum is missing or ambiguous.'
    [[ $(sha256 "$work/archive.tar.gz") == "$expected" ]] || die 'Release checksum mismatch; nothing was installed.'

    tar -tzf "$work/archive.tar.gz" > "$work/entries"
    awk '/^\// || /(^|\/)\.\.(\/|$)/ { bad=1 } END { exit bad }' "$work/entries" || die 'Unsafe archive paths.'
    tar -tvzf "$work/archive.tar.gz" > "$work/types"
    awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" { bad=1 } END { exit bad }' "$work/types" || die 'Archive links/special files are not allowed.'
    mkdir "$work/source"
    tar -xzf "$work/archive.tar.gz" -C "$work/source" --no-same-owner --no-same-permissions
    source_dir="$work/source"
}

find_source() {
    if [[ -z $source_dir && -f ${BASH_SOURCE[0]:-} ]]; then
        source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    fi
    if [[ -z $source_dir ]]; then
        download_release
    fi
    source_dir=$(cd -- "$source_dir" && pwd)

    if [[ $mode == remote ]]; then
        module_source="$source_dir/rex-actions.lua"
        [[ -f $module_source ]] || module_source="$source_dir/integration/rex-actions.lua"
        [[ -r $module_source ]] || die 'Missing rex-actions.lua in the distribution.'
        module="$destination/rex-actions.lua"
    else
        bundle=$source_dir
        [[ -f $bundle/resh ]] || bundle="$source_dir/dist/resh"
        [[ -x $bundle/resh && -f $bundle/resh.lua && -d $bundle/resh_Resh.bundle ]] || die 'Missing prebuilt picker. Run bash scripts/build.sh or install a macOS release archive.'
        local name
        for name in LICENSE THIRD_PARTY_NOTICES.md; do
            [[ -r $bundle/$name ]] || die "Missing $name in the distribution."
        done
        module="$destination/resh.lua"
        module_source="$bundle/resh.lua"
    fi
}

snapshot_file() {
    if [[ -e $1 || -L $1 ]]; then
        [[ -f $1 && -r $1 ]] || die "Not a readable file: $1"
        cp -p "$1" "$2"
        touch "$2.exists"
    else
        : > "$2"
    fi
}

unchanged() {
    if [[ -f $2.exists ]]; then
        [[ -f $1 && ! -L $1 ]] && cmp -s "$1" "$2"
    else
        [[ ! -e $1 && ! -L $1 ]]
    fi
}

prepare_rex_config() {
    rex_lua "input=$work/config.before" "output=$work/config.after" "mode=$mode" \
        "module=$module" "tools=$tools_reference" "executable=$destination/resh" <<'LUA'
local args = rex.args
local file = assert(io.open(args.input, "rb"))
local text = assert(file:read("*a")); file:close()
local integration = args.mode == "remote"
  and "assert(loadfile(" .. string.format("%q", args.module) .. "))(" .. string.format("%q", args.tools) .. ")"
  or "dofile(" .. string.format("%q", args.module) .. ")"
local found = text:find(integration, 1, true) ~= nil
if args.mode == "local" and not found then
  for argument in text:gmatch("dofile%s*%(([^\n%)]+)%)") do
    if argument:find(args.module, 1, true) then found = true end
  end
end
if not found then text = text .. (text == "" and "" or "\n") .. integration .. "\n" end
if args.mode == "local" then
  local startup = false
  for arguments in ("\n" .. text):gmatch("\n[ \t]*rex%.exec%.start%s*%(%s*{(.-)}") do
    if arguments:find("resh", 1, true) and arguments:match("['\"]service['\"]%s*,%s*['\"]start['\"]") then startup = true end
  end
  if not startup then
    text = text .. "rex.exec.start({ " .. string.format("%q", args.executable) .. ", \"service\", \"start\" },\n  { detach = true, stdout = false, stderr = false })\n"
  end
end
local output = assert(io.open(args.output, "wb"))
assert(output:write(text)); assert(output:close())
LUA
}

atomic_copy() {
    local source=$1 target=$2 preserve_mode=${3:-false} status=0
    mkdir -p -- "${target%/*}" || return 1
    pending_file=$(mktemp "${target%/*}/.resh-install.XXXXXX") || return 1
    if [[ $preserve_mode == true && -f $target ]]; then
        cp -p "$target" "$pending_file" && cat "$source" > "$pending_file" || status=$?
    else
        cp -p "$source" "$pending_file" || status=$?
    fi
    if (( status == 0 )); then
        mv -f -- "$pending_file" "$target" || status=$?
    fi
    if (( status != 0 )); then
        rm -f -- "$pending_file"
    fi
    pending_file=
    return "$status"
}

install_native() {
    "$bundle/resh" service stop
    local name
    for name in resh LICENSE THIRD_PARTY_NOTICES.md; do
        atomic_copy "$bundle/$name" "$destination/$name"
    done
    # Replace only our resources, never sessions.json or personal configuration.
    rm -rf -- "$destination/resh_Resh.bundle"
    cp -R "$bundle/resh_Resh.bundle" "$destination/resh_Resh.bundle"
}

restore_file() {
    local path=$1 before=$2 after=$3
    if [[ -f $after && -f $path && ! -L $path ]] && cmp -s "$path" "$after"; then
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
    if [[ $committed == false ]]; then
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
    mode= source_dir= config=
    repository=${RESH_REPOSITORY:-}
    version=latest
    explicit_config=false
    work= pending_file= module=
    committed=false reload_attempted=false

    parse_options "$@"
    configure_environment
    umask 077
    work=$(mktemp -d "${TMPDIR:-/tmp}/resh-install.XXXXXX")
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    check_rex
    find_source
    snapshot_file "$config" "$work/config.before"
    prepare_rex_config
    snapshot_file "$module" "$work/module.before"
    cp -p "$module_source" "$work/module.after"

    unchanged "$config" "$work/config.before" || die 'Rex config changed during installation; refusing to overwrite concurrent edits.'
    if [[ $mode == local ]]; then
        install_native
    fi
    atomic_copy "$work/module.after" "$module" true

    unchanged "$config" "$work/config.before" || die 'Rex config changed during installation; refusing to overwrite concurrent edits.'
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
    cmp -s "$config" "$work/config.after" || die 'Rex config changed during installation; reload was not attempted.'
    reload_attempted=true
    "${rex_command[@]}" config reload >/dev/null
    committed=true

    say "Installed $mode resh: $destination"
    if [[ $mode == local ]]; then
        say 'Rex Server → Remote Control must be enabled for session switching.'
    fi
}

main "$@"
