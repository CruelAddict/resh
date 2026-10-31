#!/usr/bin/env bash
# Download or locate a distribution, then use its shared Rex setup.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bash install.sh [options]
  --remote                 Install only the remote folder-source adapter
  --source DIRECTORY       Use a checkout or unpacked distribution
  --config FILE            Rex config file (required for a custom server config)
  --repository OWNER/REPO  Download a release (default: CruelAddict/resh)
  --version TAG            Release tag (default: latest)
  --verify                 Verify build provenance with GitHub CLI
  --yes                    Apply Rex configuration changes without prompting

Rex must already be installed and running as the installing account.
The installer previews Rex configuration changes and asks for confirmation.
EOF
}

die() { printf 'resh: %s\n' "$*" >&2; exit 1; }

parse_options() {
    while (( $# > 0 )); do
        case "$1" in
            --remote) remote=true; shift ;;
            --verify) verify=true; download=true; shift ;;
            --yes) setup_options+=(--yes); shift ;;
            --source|--config|--repository|--version)
                [[ $# -ge 2 && -n $2 ]] || die "Missing value for $1"
                case "$1" in
                    --source) source_dir=$2 ;;
                    --config) setup_options+=(--config "$2") ;;
                    --repository) repository=$2; download=true ;;
                    --version) version=$2 ;;
                esac
                shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    [[ -z $source_dir || $download == false ]] || die '--source cannot be combined with --repository or --verify.'
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
    [[ $repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'Invalid repository; expected OWNER/REPO.'
    [[ $version =~ ^[A-Za-z0-9._-]+$ ]] || die 'Invalid release tag.'

    if [[ $verify == true ]]; then
        if ! command -v gh >/dev/null 2>&1 || ! gh attestation verify --help >/dev/null 2>&1; then
            die '--verify requires a current GitHub CLI (gh) with attestation support.'
        fi
        if [[ $version == latest ]]; then
            version=$(gh release view --repo "$repository" --json tagName --jq .tagName)
            [[ $version =~ ^[A-Za-z0-9._-]+$ ]] || die 'Invalid latest release tag.'
        fi
    fi

    if [[ $remote == true ]]; then
        artifact=resh-remote.tar.gz
    else
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

    if [[ $verify == true ]]; then
        local commit
        commit=$(gh api "repos/$repository/commits/$version" --jq .sha)
        gh attestation verify "$work/archive.tar.gz" --repo "$repository" \
            --signer-workflow "$repository/.github/workflows/release.yml" \
            --source-ref "refs/tags/$version" --source-digest "$commit" \
            --deny-self-hosted-runners || die 'Release provenance verification failed; nothing was installed.'
    fi

    tar -tzf "$work/archive.tar.gz" > "$work/entries"
    awk '/^\// || /(^|\/)\.\.(\/|$)/ { bad=1 } END { exit bad }' "$work/entries" || die 'Unsafe archive paths.'
    tar -tvzf "$work/archive.tar.gz" > "$work/types"
    awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" { bad=1 } END { exit bad }' "$work/types" || die 'Archive links/special files are not allowed.'
    mkdir "$work/source"
    tar -xzf "$work/archive.tar.gz" -C "$work/source" --no-same-owner --no-same-permissions
    source_dir="$work/source"
}

find_source() {
    if [[ -z $source_dir && $download == false && -f ${BASH_SOURCE[0]:-} ]]; then
        local candidate
        candidate=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
        if [[ -f $candidate/rex-actions.lua || -f $candidate/integration/rex-actions.lua ]]; then
            source_dir=$candidate
        fi
    fi
    if [[ -z $source_dir ]]; then download_release; fi
    source_dir=$(cd -- "$source_dir" && pwd)
}

main() {
    remote=false verify=false download=false
    source_dir=""
    repository=${RESH_REPOSITORY:-CruelAddict/resh}
    version=latest
    setup_options=()
    parse_options "$@"
    [[ $remote == true || $(uname -s) == Darwin ]] || die 'resh requires macOS. Use --remote for a remote Rex host.'
    unset REX_SESSION REX_BLOCK REX_CLIENT REX_SERVER
    umask 077
    work=$(mktemp -d "${TMPDIR:-/tmp}/resh-install.XXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    find_source

    # Bash 3.2 needs the + form when expanding an empty array under set -u.
    if [[ $remote == true ]]; then
        local setup_script="$source_dir/setup.sh"
        [[ -f $setup_script ]] || setup_script="$source_dir/Sources/Resh/Resources/setup.sh"
        [[ -r $setup_script ]] || die 'Missing remote setup script in the distribution.'
        bash "$setup_script" --remote --source "$source_dir" ${setup_options[@]+"${setup_options[@]}"}
    else
        local bundle=$source_dir
        [[ -f $bundle/resh ]] || bundle="$source_dir/dist/resh"
        [[ -x $bundle/resh && -f $bundle/resh.lua && -d $bundle/resh_Resh.bundle ]] || die 'Missing prebuilt picker. Run bash scripts/build.sh or install a macOS release archive.'
        "$bundle/resh" setup ${setup_options[@]+"${setup_options[@]}"}
    fi
}

main "$@"
