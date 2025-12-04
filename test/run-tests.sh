#!/bin/bash
# Run BATS tests for EVerest OCPP Client
#
# Usage:
#   ./test/run-tests.sh           # Run all tests
#   ./test/run-tests.sh --tap     # TAP output for CI
#   ./test/run-tests.sh --filter "OCPP 2.0.1"  # Filter tests

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Check for required tools
for cmd in docker jq curl bats; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is required but not installed."
        exit 1
    fi
done

# Check Docker is running
if ! docker info &> /dev/null; then
    echo "Error: Docker is not running"
    exit 1
fi

echo "=== EVerest OCPP Integration Tests ==="
echo "Project: $PROJECT_ROOT"
echo ""

# Run BATS tests
cd "$PROJECT_ROOT"
bats "$@" test/ocpp.bats
