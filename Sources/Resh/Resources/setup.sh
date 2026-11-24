#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: resh setup [options]
  --config FILE       Rex config file (required for a custom server config)
  --yes               Apply changes without prompting
  --executable FILE   Selected resh command (supplied by resh)

Rex may be closed. Setup asks for confirmation and backs up changed configuration.
EOF
}

say() { printf '%s\n' "$*"; }
die() { printf 'resh: %s\n' "$*" >&2; exit 1; }

parse_options() {
    if [[ ${1:-} == --adapter ]]; then
        [[ -n ${2:-} ]] || die 'Missing value for --adapter'
        adapter=$2; shift 2
    fi
    while (( $# > 0 )); do
        case "$1" in
            --yes) is_confirmed=true; shift ;;
            --executable|--source|--config)
                [[ $# -ge 2 && -n $2 ]] || die "Missing value for $1"
                case "$1" in
                    --executable) executable=$2 ;;
                    --source) source=$2 ;;
                    --config) config=$2; is_config_explicit=true ;;
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
    [[ -n $adapter || $platform == Darwin ]] || die 'resh requires macOS. Use bash install.sh --remote on a remote Rex host.'
    export PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin"
    unset REX_SESSION REX_BLOCK REX_CLIENT REX_SERVER
    case "$config" in
        '') config=${REX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua} ;;
        /*) ;;
        *) config="$PWD/$config" ;;
    esac
    tools_reference=${RESH_TOOLS:-${XDG_CONFIG_HOME:-$HOME/.config}/resh/tools.lua}
    local path
    for path in "$HOME" "$config" "$tools_reference"; do
        [[ $path == /* ]] || die "Installation paths must be absolute: $path"
    done
    config=$(resolve_config_path "$config")
    rex_bin=${RESH_REX_BIN:-$(type -P rex || true)}
    if [[ -z $rex_bin && $platform == Darwin ]]; then
        rex_bin="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
    fi
    [[ -n $rex_bin && -x $rex_bin ]] || die 'Rex CLI not found. Install Rex first, or set RESH_REX_BIN.'
    rex_command=("$rex_bin" --autostart=false --timeout 40s)
    if [[ -n $adapter ]]; then
        marker=remote
        module="${XDG_DATA_HOME:-$HOME/.local/share}/resh/rex-actions.lua"
        [[ $module == /* && -f $adapter ]] || die 'Missing remote adapter or invalid data directory.'
    elif [[ -n $source ]]; then
        [[ -x $source/resh && -d $source/resh_Resh.bundle ]] || die 'Missing prebuilt picker.'
        executable="$HOME/.local/bin/resh"
    else
        [[ $executable == /* && -x $executable ]] || die 'Missing installed resh command.'
    fi
}

rex_lua() { "${rex_command[@]}" "do" - "$@"; }

check_rex() {
    local pid command
    is_rex_server_running=false
    if ! "${rex_command[@]}" "do" -e 'return rex.call("server.status")' > /dev/null 2>&1; then return 0; fi
    is_rex_server_running=true
    pid=$(rex_lua "account=$(id -un)" <<'LUA'
local identity = assert(rex.call("server.whoami"))
assert(identity.principal.transport == "unix" and identity.account == rex.args.account,
  "Run setup on the Rex host, as the OS account that runs that server.")
io.write(tostring(assert(rex.call("server.status")).pid), "\n")
LUA
    )
    if [[ $is_config_explicit == false ]]; then
        command=$(ps -ww -p "$pid" -o command=)
        [[ ! $command =~ --config[[:space:]=] ]] || die 'This server uses a custom config. Pass --config FILE explicitly.'
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
    {
        say "-- >>> $marker >>>"
        if [[ -n $adapter ]]; then
            printf 'assert(loadfile(%s))(%s)\n' "$(lua_quote "$module")" "$(lua_quote "$tools_reference")"
        else
            local quoted_executable
            quoted_executable=$(lua_quote "$executable")
            cat <<LUA
do
  local result = rex.exec({ $quoted_executable, "print-rex-startup-lua" }, { timeout = 5 })
  if result and result.ok then
    local startup, err = loadstring(result.stdout, "@resh startup")
    if startup then startup() else rex.log("warn", err) end
  end
end
LUA
        fi
        say "-- <<< $marker <<<"
    } > "$work/block"
    # Only the managed block is replaced; bindings elsewhere remain untouched.
    REX_CONFIG_PATH="$config" LEGACY_RESH_LOAD="dofile($(lua_quote "$HOME/Library/Application Support/resh/resh.lua"))" \
    awk -v marker="$marker" '
        FILENAME == ARGV[1] { block = block $0 "\n"; next }
        /^[ \t]*-- >>> (resh|remote) >>>[ \t]*$/ && !role {
            role = $3; start = FNR; body = ""; next
        }
        role && $0 ~ ("^[ \t]*-- <<< " role " <<<[ \t]*$") {
            if (role == "resh" && body ~ /rex-actions\.lua/) {
                if (body !~ /^[ \t]*assert\(loadfile\([^\n]+\n$/) {
                    printf "resh: %s:%d: Move the adapter loader between -- >>> remote >>> and -- <<< remote <<<.\n", ENVIRON["REX_CONFIG_PATH"], start > "/dev/stderr"; role = ""; exit 1
                }
                role = "remote"
            }
            if (role != marker) printf "-- >>> %s >>>\n%s-- <<< %s <<<\n", role, body, role
            else if (!found++) printf "%s", block
            role = ""; lines++; next
        }
        role { body = body $0 "\n"; next }
        marker == "resh" && !legacy_line && $0 == ENVIRON["LEGACY_RESH_LOAD"] { legacy_line = FNR }
        { print; lines++ }
        END {
            if (role) { print "resh: Unclosed block in Rex config." > "/dev/stderr"; exit 1 }
            if (legacy_line) {
                printf "resh: %s:%d: Old resh integration outside a managed block: %s\n", ENVIRON["REX_CONFIG_PATH"], legacy_line, ENVIRON["LEGACY_RESH_LOAD"] > "/dev/stderr"
                print "Remove the old integration or restore its markers, then run resh setup again." > "/dev/stderr"
                exit 1
            }
            if (!found) { if (lines) print ""; printf "%s", block }
        }
    ' "$work/block" "$work/config.before" > "$work/config.after"
    touch "$work/config.after.exists"
}

lua_quote() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '"%s"' "$value"
}

confirm_setup() {
    local prompt='Install resh files? [y/N] ' answer
    if [[ $1 == true ]]; then
        say "Update $config:"
        sed 's/^/  /' "$work/block"
        prompt='Apply changes? [y/N] '
    fi
    if [[ $is_confirmed == true ]]; then return 0; fi
    if ! IFS= read -r -p "$prompt" answer < /dev/tty; then
        die 'Confirmation requires a terminal. Use --yes to apply changes non-interactively.'
    fi
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) say 'Installation cancelled.'; return 1 ;;
    esac
}

atomic_copy() {
    local source=$1 target=$2 is_preserving_mode=${3:-false} status=0
    [[ ! -d $target ]] || die "Not a file: $target"
    mkdir -p -- "${target%/*}" || return 1
    pending_file=$(mktemp "${target%/*}/.resh-setup.XXXXXX") || return 1
    if [[ -L $source ]]; then
        rm -f -- "$pending_file"
        ln -s "$(readlink "$source")" "$pending_file" || status=$?
    elif [[ $is_preserving_mode == true && -f $target && ! -L $target ]]; then
        cp -p "$target" "$pending_file" && cat "$source" > "$pending_file" || status=$?
    else
        cp -p "$source" "$pending_file" || status=$?
    fi
    if (( status == 0 )); then mv -f -- "$pending_file" "$target" || status=$?; fi
    if (( status != 0 )); then rm -f -- "$pending_file"; fi
    pending_file=
    return "$status"
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

install_entry() {
    local from=$1 target=$2 stage
    [[ ! -d $target || -L $target || -d $from ]] || die "Not a file: $target"
    mkdir -p -- "${target%/*}"
    stage=$(mktemp -d "${target%/*}/.resh-install.XXXXXX")
    stages+=("$stage")
    targets+=("$target")
    cp -pPR "$from" "$stage/new"
    if [[ -e $target || -L $target ]]; then
        mv -- "$target" "$stage/old"
    else
        touch "$stage/absent"
    fi
    mv -- "$stage/new" "$target"
}

cleanup() {
    local status=$? i stage target
    trap - EXIT
    set +e
    [[ -z $pending_file ]] || rm -f -- "$pending_file"
    pending_file=
    if [[ $is_config_applied == true && $is_setup_complete == false ]]; then
        restore_file "$config" "$work/config.before" "$work/config.after"
    fi
    for ((i=${#targets[@]}-1; i>=0; i--)); do
        stage=${stages[i]} target=${targets[i]}
        if [[ $is_setup_complete == false ]]; then
            if [[ -e $stage/old || -L $stage/old ]]; then
                rm -rf -- "$target" || continue
                mv -- "$stage/old" "$target" || continue
            elif [[ -f $stage/absent ]]; then rm -rf -- "$target"; fi
        fi
        rm -rf -- "$stage"
    done
    if [[ $is_reload_attempted == true && $is_setup_complete == false ]] && unchanged "$config" "$work/config.before"; then
        "${rex_command[@]}" config reload >/dev/null 2>&1
    fi
    [[ -z $work ]] || rm -rf -- "$work"
    exit "$status"
}

main() {
    is_confirmed=false is_config_explicit=false
    config="" executable="" source="" adapter="" marker=resh
    targets=() stages=()
    work="" pending_file=""
    is_config_applied=false is_setup_complete=false is_reload_attempted=false
    parse_options "$@"
    configure_environment
    check_rex
    umask 077
    work=$(mktemp -d "${TMPDIR:-/tmp}/resh-setup.XXXXXX")
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    snapshot_file "$config" "$work/config.before"
    prepare_rex_config
    local changed=false
    cmp -s "$work/config.before" "$work/config.after" || changed=true
    if [[ $changed == true || -n $source || -n $adapter ]]; then
        if ! confirm_setup "$changed"; then return 0; fi
    fi
    if [[ -n $adapter ]]; then
        install_entry "$adapter" "$module"
    elif [[ -n $source ]]; then
        local destination="$HOME/Library/Application Support/resh"
        install_entry "$source/resh" "$destination/resh"
        install_entry "$source/resh_Resh.bundle" "$destination/resh_Resh.bundle"
        ln -s "$destination/resh" "$work/command"
        install_entry "$work/command" "$executable"
        "$executable" print-rex-startup-lua >/dev/null
    fi
    unchanged "$config" "$work/config.before" || die 'Rex config changed during setup; refusing to overwrite concurrent edits.'
    if [[ $changed == true ]]; then
        if [[ -f $work/config.before.exists ]]; then
            local backup
            backup=$(mktemp "$config.resh-backup-XXXXXX")
            cp -p "$work/config.before" "$backup"
            say "Rex config backup: $backup"
        fi
        atomic_copy "$work/config.after" "$config" true
        is_config_applied=true
    fi
    "${rex_command[@]}" config check "$config" --json >/dev/null
    unchanged "$config" "$work/config.after" || die 'Rex config changed during setup; reload was not attempted.'
    if [[ $is_rex_server_running == true ]]; then
        is_reload_attempted=true
        "${rex_command[@]}" config reload >/dev/null
    fi
    is_setup_complete=true
}

main "$@"
