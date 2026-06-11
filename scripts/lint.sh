#!/usr/bin/env bash
#
# lint.sh — format and lint Python and/or Go code in the current project.
#
# Detection: presence of pyproject.toml or setup.cfg triggers the Python path;
# presence of go.mod triggers the Go path. Both can run in the same project.
#
# Tools assumed installed:
#   Python: ruff, mypy
#   Go:     gofmt (stdlib), goimports, golangci-lint
#
# Behavior: each step prints what it is doing. Any failure causes the script
# to exit non-zero with a message naming the step that failed. The script
# does not auto-fix in CI mode (--check); without --check it does fix in
# place where the tool supports it.

set -euo pipefail

# ----- configuration -----

readonly SCRIPT_NAME="$(basename "$0")"
readonly PROJECT_ROOT="$(pwd)"

CHECK_ONLY=false
PYTHON_SOURCE_DIR="src"
PYTHON_TEST_DIR="tests"

# ----- argument parsing -----

print_usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [--check] [--python-src DIR] [--python-tests DIR]

Options:
    --check               Do not modify files; exit non-zero on any finding.
                          Use in CI.
    --python-src DIR      Override the Python source directory (default: src).
    --python-tests DIR    Override the Python test directory (default: tests).
    -h, --help            Print this message and exit.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            CHECK_ONLY=true
            shift
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
    # Bold heading for each step so output is easy to skim.
    printf "\n\033[1m==> %s\033[0m\n" "$1"
}

require_tool() {
    # Verify a binary is on PATH; fail with a helpful message if not.
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$SCRIPT_NAME: required tool not found: $tool" >&2
        echo "  install it and retry." >&2
        exit 3
    fi
}

# ----- Python lint path -----

run_python_lint() {
    require_tool ruff
    require_tool mypy

    local ruff_format_args=("format")
    local ruff_check_args=("check")
    if [[ "$CHECK_ONLY" == "true" ]]; then
        ruff_format_args+=("--check")
    else
        ruff_check_args+=("--fix")
    fi

    log_step "Python: ruff format"
    ruff "${ruff_format_args[@]}" "$PYTHON_SOURCE_DIR" "$PYTHON_TEST_DIR"

    log_step "Python: ruff check"
    ruff "${ruff_check_args[@]}" "$PYTHON_SOURCE_DIR" "$PYTHON_TEST_DIR"

    log_step "Python: mypy --strict"
    mypy --strict "$PYTHON_SOURCE_DIR"
}

# ----- Go lint path -----

run_go_lint() {
    require_tool gofmt
    require_tool goimports
    require_tool golangci-lint

    log_step "Go: gofmt"
    # gofmt -l prints filenames that need formatting; the list is empty when
    # everything is well-formed.
    local unformatted
    unformatted="$(gofmt -l .)"
    if [[ -n "$unformatted" ]]; then
        if [[ "$CHECK_ONLY" == "true" ]]; then
            echo "$SCRIPT_NAME: the following files are not gofmt-clean:" >&2
            echo "$unformatted" >&2
            exit 1
        fi
        echo "applying gofmt to:"
        echo "$unformatted"
        gofmt -w .
    fi

    log_step "Go: goimports"
    local mis_imported
    mis_imported="$(goimports -l .)"
    if [[ -n "$mis_imported" ]]; then
        if [[ "$CHECK_ONLY" == "true" ]]; then
            echo "$SCRIPT_NAME: the following files have unsorted imports:" >&2
            echo "$mis_imported" >&2
            exit 1
        fi
        echo "applying goimports to:"
        echo "$mis_imported"
        goimports -w .
    fi

    log_step "Go: golangci-lint"
    golangci-lint run ./...
}

# ----- main -----

main() {
    local ran_anything=false

    if [[ -f "$PROJECT_ROOT/pyproject.toml" || -f "$PROJECT_ROOT/setup.cfg" ]]; then
        run_python_lint
        ran_anything=true
    fi

    if [[ -f "$PROJECT_ROOT/go.mod" ]]; then
        run_go_lint
        ran_anything=true
    fi

    if [[ "$ran_anything" == "false" ]]; then
        echo "$SCRIPT_NAME: no pyproject.toml/setup.cfg or go.mod found in $PROJECT_ROOT" >&2
        echo "  nothing to do; is this the project root?" >&2
        exit 4
    fi

    log_step "lint complete"
}

main
