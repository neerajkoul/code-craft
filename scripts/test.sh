#!/usr/bin/env bash
#
# test.sh — run tests with coverage for Python and/or Go in the current project.
#
# Detection: presence of pyproject.toml or setup.cfg triggers the Python path;
# presence of go.mod triggers the Go path. Both can run in the same project.
#
# Tools assumed installed:
#   Python: pytest, pytest-cov
#   Go:     go (race detector requires CGO, which is on by default)
#
# Behavior: prints a coverage summary at the end. Exits non-zero if any test
# fails or if coverage falls below the configured floor.

set -euo pipefail

# ----- configuration -----

readonly SCRIPT_NAME="$(basename "$0")"
readonly PROJECT_ROOT="$(pwd)"

# Coverage floor: tests fail if combined coverage drops below this percentage.
# Set to 0 to disable. Tune per project; 80 is a reasonable starting point for
# new code, lower for legacy code being incrementally tested.
COVERAGE_FLOOR_PERCENT=80

PYTHON_SOURCE_DIR="src"
PYTHON_TEST_DIR="tests"

# ----- argument parsing -----

print_usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [--coverage-floor N] [--python-src DIR] [--python-tests DIR]

Options:
    --coverage-floor N      Fail if coverage is below N percent (default: 80, 0 disables).
    --python-src DIR        Override the Python source directory (default: src).
    --python-tests DIR      Override the Python test directory (default: tests).
    -h, --help              Print this message and exit.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --coverage-floor)
            COVERAGE_FLOOR_PERCENT="$2"
            shift 2
            ;;
        --python-src)
            PYTHON_SOURCE_DIR="$2"
            shift 2
            ;;
        --python-tests)
            PYTHON_TEST_DIR="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "$SCRIPT_NAME: unknown argument: $1" >&2
            print_usage >&2
            exit 2
            ;;
    esac
done

# ----- helpers -----

log_step() {
    printf "\n\033[1m==> %s\033[0m\n" "$1"
}

require_tool() {
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$SCRIPT_NAME: required tool not found: $tool" >&2
        exit 3
    fi
}

# ----- Python test path -----

run_python_tests() {
    require_tool pytest

    log_step "Python: pytest with branch coverage"

    # --cov-branch: branch coverage (catches untested if-branches that line
    # coverage misses). --cov-report=term-missing: prints uncovered lines.
    # --cov-fail-under: fails the run if total coverage is below the floor.
    pytest \
        --cov="$PYTHON_SOURCE_DIR" \
        --cov-branch \
        --cov-report=term-missing \
        --cov-fail-under="$COVERAGE_FLOOR_PERCENT" \
        "$PYTHON_TEST_DIR"
}

# ----- Go test path -----

run_go_tests() {
    require_tool go

    log_step "Go: go test with race detector and coverage"

    local coverage_file
    coverage_file="$(mktemp)"
    # Ensure the temp file is cleaned up regardless of how the function exits.
    trap 'rm -f "$coverage_file"' EXIT

    # -race: data race detector (cheap concurrency bug catcher).
    # -covermode=atomic: race-safe coverage counters; required when -race is on.
    # -coverprofile: write the coverage profile for the post-run summary.
    go test \
        -race \
        -covermode=atomic \
        -coverprofile="$coverage_file" \
        ./...

    log_step "Go: coverage summary"
    go tool cover -func="$coverage_file" | tail -n 1

    if [[ "$COVERAGE_FLOOR_PERCENT" -gt 0 ]]; then
        # Extract the total coverage percentage and compare against the floor.
        local total_percent
        total_percent="$(
            go tool cover -func="$coverage_file" \
            | tail -n 1 \
            | awk '{print $NF}' \
            | tr -d '%'
        )"
        # Use awk for floating-point comparison (bash arithmetic is integer-only).
        local below_floor
        below_floor="$(awk -v t="$total_percent" -v f="$COVERAGE_FLOOR_PERCENT" \
            'BEGIN { print (t < f) ? "1" : "0" }')"
        if [[ "$below_floor" == "1" ]]; then
            echo "$SCRIPT_NAME: Go coverage $total_percent% is below floor $COVERAGE_FLOOR_PERCENT%" >&2
            exit 1
        fi
    fi
}

# ----- main -----

main() {
    local ran_anything=false

    if [[ -f "$PROJECT_ROOT/pyproject.toml" || -f "$PROJECT_ROOT/setup.cfg" ]]; then
        run_python_tests
        ran_anything=true
    fi

    if [[ -f "$PROJECT_ROOT/go.mod" ]]; then
        run_go_tests
        ran_anything=true
    fi

    if [[ "$ran_anything" == "false" ]]; then
        echo "$SCRIPT_NAME: no pyproject.toml/setup.cfg or go.mod found in $PROJECT_ROOT" >&2
        echo "  nothing to do; is this the project root?" >&2
        exit 4
    fi

    log_step "tests complete"
}

main
