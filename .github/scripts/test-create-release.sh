#!/bin/bash
##===----------------------------------------------------------------------===##
##
## Test harness for create-release.sh
## Tests each failure condition by mocking the gh command
##
##===----------------------------------------------------------------------===##

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_DIR=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR"' EXIT

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

# Helper to create mock gh script
create_mock_gh() {
  local mock_script="$1"
  cat > "$MOCK_DIR/gh" << EOF
#!/bin/bash
$mock_script
EOF
  chmod +x "$MOCK_DIR/gh"
}

# Helper to run test
run_test() {
  local test_name="$1"
  local expected_exit_code="$2"
  local expected_output_pattern="$3"

  echo ""
  echo -e "${YELLOW}=== Test: $test_name ===${NC}"

  # Run the script with mocked gh
  export PATH="$MOCK_DIR:$PATH"
  export GITHUB_REPOSITORY="test/repo"
  export GITHUB_TOKEN="fake-token"

  cd "$SCRIPT_DIR"
  set +e
  output=$(bash create-release.sh 2>&1)
  actual_exit_code=$?
  set -e

  echo "Output:"
  echo "$output"
  echo ""
  echo "Exit code: $actual_exit_code (expected: $expected_exit_code)"

  # Check results
  local passed=true

  if [ "$actual_exit_code" != "$expected_exit_code" ]; then
    echo -e "${RED}FAIL: Expected exit code $expected_exit_code, got $actual_exit_code${NC}"
    passed=false
  fi

  if ! echo "$output" | grep -qF "$expected_output_pattern"; then
    echo -e "${RED}FAIL: Expected output to contain '$expected_output_pattern'${NC}"
    passed=false
  fi

  if [ "$passed" = true ]; then
    echo -e "${GREEN}PASS${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

echo "========================================"
echo "Testing create-release.sh failure conditions"
echo "========================================"

# Test 1: No previous releases found
# gh release list --limit 1 --json tagName --jq '.[0].tagName' returns empty when no releases
echo ""
echo -e "${YELLOW}Test 1: No previous releases found${NC}"
create_mock_gh '
if [[ "$1" == "release" && "$2" == "list" ]]; then
  # When there are no releases, jq returns null which becomes empty string
  echo ""
  exit 0
fi
echo "Unexpected command: $*" >&2
exit 1
'
run_test "No previous releases" 1 "Error: No previous releases found"

# Test 2: Latest tag doesn't match semver format
echo ""
echo -e "${YELLOW}Test 2: Tag does not match semver format${NC}"
create_mock_gh '
if [[ "$1" == "release" && "$2" == "list" ]]; then
  # Returns raw tag name from jq
  echo "invalid-tag"
  exit 0
fi
if [[ "$1" == "release" && "$2" == "view" ]]; then
  # Returns raw date from jq
  echo "2024-01-01T00:00:00Z"
  exit 0
fi
echo "Unexpected command: $*" >&2
exit 1
'
run_test "Invalid semver tag" 1 "Error: Latest tag 'invalid-tag' does not match semver format"

# Test 3: No PRs found since last release
echo ""
echo -e "${YELLOW}Test 3: No PRs found since last release${NC}"
create_mock_gh '
if [[ "$1" == "release" && "$2" == "list" ]]; then
  echo "v1.2.3"
  exit 0
fi
if [[ "$1" == "release" && "$2" == "view" ]]; then
  echo "2024-01-01T00:00:00Z"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  # No PRs matching the filter, returns empty
  echo ""
  exit 0
fi
echo "Unexpected command: $*" >&2
exit 1
'
run_test "No PRs since last release" 0 "No PRs found since last release. Skipping release."

# Test 4: Failed to fetch labels for PR
echo ""
echo -e "${YELLOW}Test 4: Failed to fetch labels for PR${NC}"
create_mock_gh '
if [[ "$1" == "release" && "$2" == "list" ]]; then
  echo "v1.2.3"
  exit 0
fi
if [[ "$1" == "release" && "$2" == "view" ]]; then
  echo "2024-01-01T00:00:00Z"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  echo "123"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  echo "Error: API error" >&2
  exit 1
fi
echo "Unexpected command: $*" >&2
exit 1
'
run_test "Failed to fetch PR labels" 1 "Error: Failed to fetch labels for PR #123"

# Test 5: semver/major found - manual release required
echo ""
echo -e "${YELLOW}Test 5: semver/major found - manual release required${NC}"
create_mock_gh '
if [[ "$1" == "release" && "$2" == "list" ]]; then
  echo "v1.2.3"
  exit 0
fi
if [[ "$1" == "release" && "$2" == "view" ]]; then
  echo "2024-01-01T00:00:00Z"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  echo "456"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  echo "⚠️ semver/major"
  exit 0
fi
echo "Unexpected command: $*" >&2
exit 1
'
run_test "semver/major label found" 1 "Error: ⚠️ semver/major found in PR #456. Major releases must be created manually."

# Test 6: Failed to generate release notes
echo ""
echo -e "${YELLOW}Test 6: Failed to generate release notes${NC}"
create_mock_gh '
if [[ "$1" == "release" && "$2" == "list" ]]; then
  echo "v1.2.3"
  exit 0
fi
if [[ "$1" == "release" && "$2" == "view" ]]; then
  echo "2024-01-01T00:00:00Z"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  echo "789"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  echo "🔨 semver/patch"
  exit 0
fi
if [[ "$1" == "api" ]]; then
  echo "Error: API error" >&2
  exit 1
fi
echo "Unexpected command: $*" >&2
exit 1
'
run_test "Failed to generate release notes" 1 "Error: Failed to generate release notes"

# Test 7: Failed to get release date for tag
echo ""
echo -e "${YELLOW}Test 7: Failed to get release date for tag${NC}"
create_mock_gh '
if [[ "$1" == "release" && "$2" == "list" ]]; then
  echo "v1.2.3"
  exit 0
fi
if [[ "$1" == "release" && "$2" == "view" ]]; then
  echo "Error: release not found" >&2
  exit 1
fi
echo "Unexpected command: $*" >&2
exit 1
'
run_test "Failed to get release date" 1 "Error: Failed to get release date for tag 'v1.2.3'"

# Test 8: Failed to fetch merged PRs
echo ""
echo -e "${YELLOW}Test 8: Failed to fetch merged PRs${NC}"
create_mock_gh '
if [[ "$1" == "release" && "$2" == "list" ]]; then
  echo "v1.2.3"
  exit 0
fi
if [[ "$1" == "release" && "$2" == "view" ]]; then
  echo "2024-01-01T00:00:00Z"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  echo "Error: API rate limit exceeded" >&2
  exit 1
fi
echo "Unexpected command: $*" >&2
exit 1
'
run_test "Failed to fetch merged PRs" 1 "Error: Failed to fetch merged PRs"

# Test 9: Failed to create release
echo ""
echo -e "${YELLOW}Test 9: Failed to create release${NC}"
create_mock_gh '
if [[ "$1" == "release" && "$2" == "list" ]]; then
  echo "v1.2.3"
  exit 0
fi
if [[ "$1" == "release" && "$2" == "view" ]]; then
  echo "2024-01-01T00:00:00Z"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  echo "999"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  echo "🔨 semver/patch"
  exit 0
fi
if [[ "$1" == "api" ]]; then
  echo "Release notes content"
  exit 0
fi
if [[ "$1" == "release" && "$2" == "create" ]]; then
  echo "Error: Tag already exists" >&2
  exit 1
fi
echo "Unexpected command: $*" >&2
exit 1
'
run_test "Failed to create release" 1 "Error: Failed to create release 1.2.4"

# Summary
echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"

if [ "$TESTS_FAILED" -gt 0 ]; then
  exit 1
fi
