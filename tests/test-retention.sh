#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT
readonly SCRIPT="$PROJECT_ROOT/bin/wazuh-alerts-retention"

test_root="$(mktemp -d -t wazuh-alerts-retention-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT
alerts_root="$test_root/alerts"
lock_file="$test_root/wazuh-alerts-retention.lock"

fail() {
    printf 'TEST FAILED: %s\n' "$*" >&2
    exit 1
}

assert_exists() {
    [[ -e "$1" || -L "$1" ]] || fail "expected path to exist: $1"
}

assert_missing() {
    [[ ! -e "$1" && ! -L "$1" ]] || fail "expected path to be absent: $1"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain: $needle"
}

mkdir -p \
    "$alerts_root/2026/Aug" \
    "$alerts_root/2026/Bad" \
    "$alerts_root/not-a-year/Aug" \
    "$alerts_root/2026/Aug/nested"

zero_byte_file="$alerts_root/2026/Aug/ossec-alerts-05.json.sum"

old_files=(
    "$alerts_root/2026/Aug/ossec-alerts-01.log.gz"
    "$alerts_root/2026/Aug/ossec-alerts-01.json.gz"
    "$alerts_root/2026/Aug/ossec-alerts-01.log.sum"
    "$alerts_root/2026/Aug/ossec-alerts-01.json.sum"
    "$alerts_root/2026/Aug/ossec-alerts-01-001.json.gz"
    "$zero_byte_file"
)

for file in "${old_files[@]}"; do
    printf 'old-data\n' > "$file"
    touch -d '8 days ago' "$file"
done

# Ensure zero-byte matching files do not trigger an early exit under set -e.
: > "$zero_byte_file"
touch -d '8 days ago' "$zero_byte_file"

new_file="$alerts_root/2026/Aug/ossec-alerts-02.log.gz"
printf 'new-data\n' > "$new_file"
touch -d '6 days ago' "$new_file"

current_log="$alerts_root/alerts.log"
current_json="$alerts_root/alerts.json"
printf 'current\n' > "$current_log"
printf 'current\n' > "$current_json"
touch -d '30 days ago' "$current_log" "$current_json"

wrong_extension="$alerts_root/2026/Aug/ossec-alerts-03.txt.gz"
uncompressed="$alerts_root/2026/Aug/ossec-alerts-03.log"
wrong_month="$alerts_root/2026/Bad/ossec-alerts-03.log.gz"
wrong_year="$alerts_root/not-a-year/Aug/ossec-alerts-03.log.gz"
wrong_depth="$alerts_root/2026/Aug/nested/ossec-alerts-03.log.gz"

for file in "$wrong_extension" "$uncompressed" "$wrong_month" "$wrong_year" "$wrong_depth"; do
    printf 'protected\n' > "$file"
    touch -d '30 days ago' "$file"
done

symlink_target="$test_root/symlink-target"
symlink_file="$alerts_root/2026/Aug/ossec-alerts-04.log.gz"
printf 'target\n' > "$symlink_target"
touch -d '30 days ago' "$symlink_target"
ln -s "$symlink_target" "$symlink_file"

bash -n "$SCRIPT"

printf 'Running dry-run test...\n'
dry_output="$(ALERTS_ROOT="$alerts_root" RETENTION_DAYS=7 RETENTION_LOCK_FILE="$lock_file" "$SCRIPT" --dry-run)"

for file in "${old_files[@]}"; do
    assert_contains "$dry_output" "WOULD_DELETE: $file"
    assert_exists "$file"
done

assert_contains "$dry_output" 'SUMMARY: would delete 6 file(s)'
assert_not_contains "$dry_output" "$new_file"
assert_not_contains "$dry_output" "$wrong_extension"
assert_not_contains "$dry_output" "$uncompressed"
assert_not_contains "$dry_output" "$wrong_month"
assert_not_contains "$dry_output" "$wrong_year"
assert_not_contains "$dry_output" "$wrong_depth"
assert_not_contains "$dry_output" "$symlink_file"
assert_not_contains "$dry_output" "$current_log"
assert_not_contains "$dry_output" "$current_json"

printf 'Running deletion test...\n'
delete_output="$(ALERTS_ROOT="$alerts_root" RETENTION_DAYS=7 RETENTION_LOCK_FILE="$lock_file" "$SCRIPT" --delete)"
assert_contains "$delete_output" 'SUMMARY: matched 6 file(s); deleted 6 file(s)'

for file in "${old_files[@]}"; do
    assert_missing "$file"
done

for file in \
    "$new_file" \
    "$current_log" \
    "$current_json" \
    "$wrong_extension" \
    "$uncompressed" \
    "$wrong_month" \
    "$wrong_year" \
    "$wrong_depth" \
    "$symlink_file" \
    "$symlink_target"; do
    assert_exists "$file"
done

printf 'Running idempotency test...\n'
second_output="$(ALERTS_ROOT="$alerts_root" RETENTION_DAYS=7 RETENTION_LOCK_FILE="$lock_file" "$SCRIPT" --delete)"
assert_contains "$second_output" 'SUMMARY: matched 0 file(s); deleted 0 file(s)'

printf 'Running input-validation tests...\n'
if ALERTS_ROOT="$alerts_root" RETENTION_DAYS=0 RETENTION_LOCK_FILE="$lock_file" "$SCRIPT" --dry-run >/dev/null 2>&1; then
    fail 'RETENTION_DAYS=0 should fail'
fi

if ALERTS_ROOT="$alerts_root" RETENTION_DAYS=3651 RETENTION_LOCK_FILE="$lock_file" "$SCRIPT" --dry-run >/dev/null 2>&1; then
    fail 'RETENTION_DAYS=3651 should fail'
fi

if ALERTS_ROOT='relative/path' RETENTION_DAYS=7 RETENTION_LOCK_FILE="$lock_file" "$SCRIPT" --dry-run >/dev/null 2>&1; then
    fail 'a relative ALERTS_ROOT should fail'
fi

if ALERTS_ROOT="$alerts_root" RETENTION_DAYS=7 RETENTION_LOCK_FILE="$lock_file" "$SCRIPT" --dry-run unexpected >/dev/null 2>&1; then
    fail 'an extra positional argument should fail'
fi

printf 'Running lock-contention test...\n'
exec 8>"$lock_file"
flock -n 8
set +e
ALERTS_ROOT="$alerts_root" \
RETENTION_DAYS=7 \
RETENTION_LOCK_FILE="$lock_file" \
"$SCRIPT" --dry-run >/dev/null 2>&1
lock_status=$?
set -e
(( lock_status == 75 )) || fail "expected lock contention exit code 75, got $lock_status"
flock -u 8
exec 8>&-

printf 'All tests passed.\n'
