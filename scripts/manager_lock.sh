#!/usr/bin/env bash
#
# Host-side operation locks for POK-manager.
# Lock files remain on disk; the kernel releases the actual flock when the
# owning process exits or closes its file descriptor.

if ! declare -p POK_MANAGER_LOCK_FDS >/dev/null 2>&1; then
    declare -ag POK_MANAGER_LOCK_FDS=()
fi

if ! declare -p POK_MANAGER_LOCK_SCOPES >/dev/null 2>&1; then
    declare -ag POK_MANAGER_LOCK_SCOPES=()
fi

_manager_lock_directory() {
    if [ -n "${POK_MANAGER_LOCK_DIR:-}" ]; then
        printf '%s\n' "$POK_MANAGER_LOCK_DIR"
        return 0
    fi

    if [ -z "${BASE_DIR:-}" ]; then
        echo "Manager lock error: BASE_DIR is not configured." >&2
        return 1
    fi

    printf '%s\n' "${BASE_DIR%/}/config/POK-manager/locks"
}

_manager_lock_scope_is_valid() {
    local scope="${1:-}"

    [[ "$scope" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

_manager_lock_scope_is_held() {
    local wanted_scope="$1"
    local held_scope

    for held_scope in "${POK_MANAGER_LOCK_SCOPES[@]}"; do
        if [ "$held_scope" = "$wanted_scope" ]; then
            return 0
        fi
    done

    return 1
}

manager_lock_acquire() {
    local scope="${1:-}"
    local wait_seconds="${2:-0}"
    local lock_directory
    local lock_path
    local lock_fd

    if ! command -v flock >/dev/null 2>&1; then
        echo "Manager lock error: flock is required but is not installed." >&2
        return 1
    fi

    if ! _manager_lock_scope_is_valid "$scope"; then
        echo "Manager lock error: invalid lock scope '$scope'." >&2
        return 1
    fi

    if ! [[ "$wait_seconds" =~ ^[0-9]+$ ]]; then
        echo "Manager lock error: wait time must be a whole number of seconds." >&2
        return 1
    fi

    if _manager_lock_scope_is_held "$scope"; then
        return 0
    fi

    lock_directory="$(_manager_lock_directory)" || return 1
    mkdir -p "$lock_directory" || {
        echo "Manager lock error: cannot create $lock_directory." >&2
        return 1
    }

    lock_path="${lock_directory}/${scope}.lock"
    exec {lock_fd}>>"$lock_path" || {
        echo "Manager lock error: cannot open $lock_path." >&2
        return 1
    }

    if [ "$wait_seconds" -eq 0 ]; then
        if ! flock -n "$lock_fd"; then
            echo "Manager operation blocked: lock '$scope' is already held." >&2
            exec {lock_fd}>&-
            return 1
        fi
    elif ! flock -w "$wait_seconds" "$lock_fd"; then
        echo "Manager operation timed out waiting for lock '$scope'." >&2
        exec {lock_fd}>&-
        return 1
    fi

    POK_MANAGER_LOCK_FDS+=("$lock_fd")
    POK_MANAGER_LOCK_SCOPES+=("$scope")

    return 0
}

manager_lock_release_all() {
    local index
    local lock_fd

    for ((index = ${#POK_MANAGER_LOCK_FDS[@]} - 1; index >= 0; index--)); do
        lock_fd="${POK_MANAGER_LOCK_FDS[$index]}"
        flock -u "$lock_fd" 2>/dev/null || true
        exec {lock_fd}>&-
    done

    POK_MANAGER_LOCK_FDS=()
    POK_MANAGER_LOCK_SCOPES=()
}