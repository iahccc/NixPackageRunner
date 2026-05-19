#!/usr/bin/env bash

set -euo pipefail

allow_unfree="${NIX_PACKAGE_RUNNER_ALLOW_UNFREE:-0}"
local_locked_flake_ref="__LOCAL_LOCKED_NIXPKGS__"

run_nix_eval() {
    if [[ "${allow_unfree}" == "1" ]]; then
        NIXPKGS_ALLOW_UNFREE=1 nix eval "$@"
    else
        nix eval "$@"
    fi
}

run_nix_search() {
    if [[ "${allow_unfree}" == "1" ]]; then
        NIXPKGS_ALLOW_UNFREE=1 nix search --quiet "$@"
    else
        nix search --quiet "$@"
    fi
}

run_nix_shell() {
    if [[ "${allow_unfree}" == "1" ]]; then
        NIXPKGS_ALLOW_UNFREE=1 nix shell --impure "$@"
    else
        nix shell "$@"
    fi
}

run_nix_run() {
    if [[ "${allow_unfree}" == "1" ]]; then
        NIXPKGS_ALLOW_UNFREE=1 nix run --impure "$@"
    else
        nix run "$@"
    fi
}

resolve_local_locked_nixpkgs() {
    local lock_file="/etc/nixos/flake.lock"
    local flake_ref=""

    if [[ ! -r "${lock_file}" ]]; then
        printf 'nixpkgs\n'
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        printf 'nixpkgs\n'
        return 0
    fi

    flake_ref="$(
        jq -r '
            .nodes as $nodes
            | .nodes.root.inputs.nixpkgs as $nixpkgs
            | $nodes[$nixpkgs].locked as $locked
            | if ($locked.type == "github"
                and ($locked.owner // "") != ""
                and ($locked.repo // "") != ""
                and ($locked.rev // "") != "")
              then "github:\($locked.owner)/\($locked.repo)/\($locked.rev)"
              else empty
              end
        ' "${lock_file}" 2>/dev/null || true
    )"

    if [[ -z "${flake_ref}" || "${flake_ref}" == "null" ]]; then
        printf 'nixpkgs\n'
        return 0
    fi

    printf '%s\n' "${flake_ref}"
}

resolve_flake_ref() {
    local flake_ref="${1:-}"

    if [[ -z "${flake_ref}" || "${flake_ref}" == "nixpkgs" ]]; then
        printf 'nixpkgs\n'
        return 0
    fi

    if [[ "${flake_ref}" == "${local_locked_flake_ref}" ]]; then
        resolve_local_locked_nixpkgs
        return 0
    fi

    printf '%s\n' "${flake_ref}"
}

resolve_main_program() {
    local flake_ref="${1:-}"
    local attr_path="${2:-}"
    local fallback_pname="${3:-}"
    local main_program=""
    local resolved_flake_ref=""

    if [[ -z "${attr_path}" ]]; then
        echo "missing attr path" >&2
        return 64
    fi

    resolved_flake_ref="$(resolve_flake_ref "${flake_ref}")"

    main_program="$(run_nix_eval --raw "${resolved_flake_ref}#${attr_path}.meta.mainProgram" 2>/dev/null || true)"
    if [[ -z "${main_program}" || "${main_program}" == "null" ]]; then
        main_program="$(run_nix_eval --raw "${resolved_flake_ref}#${attr_path}.pname" 2>/dev/null || true)"
    fi
    if [[ -z "${main_program}" || "${main_program}" == "null" ]]; then
        main_program="${fallback_pname}"
    fi
    if [[ -z "${main_program}" || "${main_program}" == "null" ]]; then
        main_program="${attr_path##*.}"
    fi

    printf '%s\n' "${main_program}"
}

build_command() {
    local flake_ref="${1:-}"
    local attr_path="${2:-}"
    local resolved_flake_ref

    resolved_flake_ref="$(resolve_flake_ref "${flake_ref}")"
    if [[ "${allow_unfree}" == "1" ]]; then
        printf 'NIXPKGS_ALLOW_UNFREE=1 nix shell --impure %q\n' "${resolved_flake_ref}#${attr_path}"
    else
        printf 'nix shell %q\n' "${resolved_flake_ref}#${attr_path}"
    fi
}

search_packages() {
    local query="${1:-}"
    local output=""

    if [[ -z "${query}" ]]; then
        printf '{}\n'
        return 0
    fi

    output="$(run_nix_search nixpkgs "${query}" --json 2> >(sed '/^evaluation warning:/d' >&2))"
    printf '%s\n' "${output}"
}

run_package() {
    local flake_ref="${1:-}"
    local attr_path="${2:-}"
    local resolved_flake_ref

    resolved_flake_ref="$(resolve_flake_ref "${flake_ref}")"
    run_nix_run "${resolved_flake_ref}#${attr_path}"
}

run_package_wait() {
    local flake_ref="${1:-}"
    local attr_path="${2:-}"
    local resolved_flake_ref
    local status

    resolved_flake_ref="$(resolve_flake_ref "${flake_ref}")"

    set +e
    run_nix_run "${resolved_flake_ref}#${attr_path}"
    status=$?
    set -e

    printf '\n[exit %s] Press Enter to close...' "${status}" >&2
    read -r _
    exit "${status}"
}

usage() {
    cat <<'EOF'
usage:
  nix-package-runner.sh [--allow-unfree] search <query>
  nix-package-runner.sh [--allow-unfree] resolve <flakeRef> <attrPath> [fallbackPname]
  nix-package-runner.sh [--allow-unfree] print <flakeRef> <attrPath> [fallbackPname]
  nix-package-runner.sh [--allow-unfree] run <flakeRef> <attrPath> [fallbackPname]
  nix-package-runner.sh [--allow-unfree] run-wait <flakeRef> <attrPath> [fallbackPname]
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --allow-unfree)
                allow_unfree=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                break
                ;;
        esac
    done

    local command="${1:-}"
    shift || true

    case "${command}" in
        search)
            search_packages "$@"
            ;;
        resolve)
            resolve_main_program "$@"
            ;;
        print)
            build_command "$@"
            ;;
        run)
            run_package "$@"
            ;;
        run-wait)
            run_package_wait "$@"
            ;;
        *)
            usage >&2
            exit 64
            ;;
    esac
}

main "$@"
