#!/usr/bin/env bats

load '../test_helper/bats-support/load.bash'
load '../test_helper/bats-assert/load.bash'
load '../test_helper/project.bash'

@test "manager lock acquires and releases an instance lock" {
    run env REPO_ROOT="$PROJECT_ROOT" \
        POK_MANAGER_LOCK_DIR="$BATS_TEST_TMPDIR/locks" bash -lc '
            set -e
            source "$REPO_ROOT/scripts/manager_lock.sh"

            manager_lock_acquire "instance-demo"

            test -f "$POK_MANAGER_LOCK_DIR/instance-demo.lock"
            printf "held=%s\n" "${POK_MANAGER_LOCK_SCOPES[*]}"

            manager_lock_release_all

            printf "remaining=%s\n" "${#POK_MANAGER_LOCK_SCOPES[@]}"
            flock -n "$POK_MANAGER_LOCK_DIR/instance-demo.lock" true
        '
    assert_success
    assert_output --partial "held=instance-demo"
    assert_output --partial "remaining=0"
}

@test "manager lock treats repeated acquisition by the same process as successful" {
    run env REPO_ROOT="$PROJECT_ROOT" \
        POK_MANAGER_LOCK_DIR="$BATS_TEST_TMPDIR/locks" bash -lc '
            set -e
            source "$REPO_ROOT/scripts/manager_lock.sh"

            manager_lock_acquire "instance-demo"
            manager_lock_acquire "instance-demo"

            printf "locks=%s\n" "${#POK_MANAGER_LOCK_FDS[@]}"
            manager_lock_release_all
        '

    assert_success
    assert_output --partial "locks=1"

}

@test "manager lock rejects an invalid scope" {
    run env REPO_ROOT="$PROJECT_ROOT" \
        POK_MANAGER_LOCK_DIR="$BATS_TEST_TMPDIR/locks" bash -lc '
            source "$REPO_ROOT/scripts/manager_lock.sh"
            manager_lock_acquire "../invalid"
        '

    assert_failure
    assert_output --partial "Manager lock error: invalid lock scope '../invalid'."
}

@test "manager lock blocks a second process from taking the same scope" {
    run env REPO_ROOT="$PROJECT_ROOT" \
        POK_MANAGER_LOCK_DIR="$BATS_TEST_TMPDIR/locks" bash -lc '
            set -e
            mkdir -p "$POK_MANAGER_LOCK_DIR"

            (
                exec 9>>"$POK_MANAGER_LOCK_DIR/instance-demo.lock"
                flock 9
                touch "$POK_MANAGER_LOCK_DIR/holder-ready"
                sleep 30
            ) &

            holder_pid=$!
            trap "kill $holder_pid 2>/dev/null || true; wait $holder_pid 2>/dev/null || true" EXIT

            for attempt in {1..100}; do
                [ -f "$POK_MANAGER_LOCK_DIR/holder-ready" ] && break
                sleep 0.02
            done

            test -f "$POK_MANAGER_LOCK_DIR/holder-ready"
            source "$REPO_ROOT/scripts/manager_lock.sh"

            if manager_lock_acquire "instance-demo"; then
                echo "Second lock acquisition unexpectedly succeeded."
                exit 1
            fi
        '
    assert_success
    assert_output --partial "Manager operation blocked: lock 'instance-demo' is already held."
}

@test "POK-manager loads the lock helper when BASE_DIR is overridden" {
    run env REPO_ROOT="$PROJECT_ROOT" \
        BASE_DIR="$BATS_TEST_TMPDIR/manager-base" \
        POK_MANAGER_TEST_MODE=1 bash -lc '
            set -e
            source "$REPO_ROOT/POK-manager.sh"

            declare -F manager_lock_acquire >/dev/null
            declare -F manager_lock_release_all >/dev/null

            echo "lock helper loaded"
        '
    assert_success
    assert_output --partial "lock helper loaded"
}