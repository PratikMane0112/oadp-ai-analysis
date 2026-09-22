#!/bin/bash

#
# Analyze test failures using Claude AI via Vertex
# This script checks out the oadp-operator repository and runs the analyze_failures.sh script
# Analyze test failures using OpenAI Codex CLI
# Runs the analyze_failures.sh script.
#
# Prerequisites:
#    - Claude CLI installed (npm install -g @anthropic-ai/claude-code)
#    - Google Cloud credentials configured (GOOGLE_APPLICATION_CREDENTIALS)
#    - Vertex AI project configured (ANTHROPIC_VERTEX_PROJECT_ID)
#    - Codex CLI installed (npm install -g @openai/codex)
#    - OPENAI_API_KEY set
#    - Test artifacts available in ARTIFACT_DIR
#
# Usage:
#    analyze-fails-ai.sh [EXIT_CODE]
#
# Environment Variables:
#    ARTIFACT_DIR: Directory containing test artifacts (default: current directory)
#    SKIP_CLAUDE_ANALYSIS: Set to "true" to skip analysis (default: false)
#    GOOGLE_APPLICATION_CREDENTIALS: Path to GCP service account key
#    ANTHROPIC_VERTEX_PROJECT_ID: GCP project ID for Vertex AI
#    CLOUD_ML_REGION: GCP region for Vertex AI (default: us-east5)
#    OADP_OPERATOR_BRANCH: Branch to checkout (default: oadp-dev)
#    REPO_OWNER: GitHub repo owner (default: openshift)
#    SKIP_AI_ANALYSIS: Set to "true" to skip analysis (default: false)
#    OPENAI_API_KEY: OpenAI API key for Codex CLI
#    OADP_OPERATOR_BRANCH: Branch to fetch flakes.go from (default: oadp-dev)
#    REPO_OWNER: GitHub repo owner for flakes.go (default: openshift)
#

set -e

readonly SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
readonly TOP_DIR=$(cd "${SCRIPT_DIR}"; git rev-parse --show-toplevel)
readonly TOP_DIR=$(
	cd "${SCRIPT_DIR}"
	git rev-parse --show-toplevel
)
readonly WORKSPACE="${WORKSPACE:-${SCRIPT_DIR}}"

readonly REPO_OWNER="${REPO_OWNER:-openshift}"
readonly REPO_BRANCH="${OADP_OPERATOR_BRANCH:-oadp-dev}"

readonly OADP_GIT_URL="https://github.com/${REPO_OWNER}/oadp-operator"
readonly OADP_GIT_DIR="${WORKSPACE}/oadp-operator"
readonly ANALYZE_SCRIPT="tests/e2e/scripts/analyze_failures.sh"
readonly ANALYZE_SCRIPT="${SCRIPT_DIR}/analyze_failures.sh"

# Exit code to pass to the analysis script (0 = success, non-zero = failure)
EXIT_CODE="${1:-0}"

@@ -45,68 +43,101 @@ export ARTIFACT_DIR="${ARTIFACT_DIR:-$(pwd)}"
# Source logger utility
source "${TOP_DIR}/scripts/logger.sh"

scripts::logger::INFO "Starting Claude AI test failure analysis"
scripts::logger::INFO "Repository: ${OADP_GIT_URL}"
scripts::logger::INFO "Branch: ${REPO_BRANCH}"
scripts::logger::INFO "Starting AI test failure analysis"
scripts::logger::INFO "Artifact directory: ${ARTIFACT_DIR}"
scripts::logger::INFO "Exit code: ${EXIT_CODE}"

#
# Verify prerequisites
#
if [ -z "$GOOGLE_APPLICATION_CREDENTIALS" ] || [ -z "$ANTHROPIC_VERTEX_PROJECT_ID" ]; then
    scripts::logger::WARN "Vertex AI not configured properly"
    scripts::logger::WARN "Missing GOOGLE_APPLICATION_CREDENTIALS or ANTHROPIC_VERTEX_PROJECT_ID"
    scripts::logger::WARN "Skipping Claude analysis"
    exit $EXIT_CODE
if [ -z "$OPENAI_API_KEY" ]; then
	scripts::logger::WARN "OPENAI_API_KEY not set"
	scripts::logger::WARN "Skipping AI analysis"
	exit $EXIT_CODE
fi

if ! command -v claude &> /dev/null; then
    scripts::logger::WARN "Claude CLI not found in PATH"
    scripts::logger::WARN "Install with: npm install -g @anthropic-ai/claude-code"
    scripts::logger::WARN "Skipping Claude analysis"
    exit $EXIT_CODE
if ! command -v codex &>/dev/null; then
	scripts::logger::INFO "Codex CLI not found, installing..."

	# Try global install first (works if running as root)
	npm install -g @openai/codex 2>&1 || true

	# If global failed, install to user-local directory
	if ! command -v codex &>/dev/null; then
		scripts::logger::INFO "Global install failed (permission denied), installing locally..."
		CODEX_INSTALL_DIR="${HOME}/.codex-cli"
		npm install @openai/codex --prefix "${CODEX_INSTALL_DIR}" 2>&1 || true
		export PATH="${CODEX_INSTALL_DIR}/node_modules/.bin:${PATH}"
	fi

	# Final check
	if ! command -v codex &>/dev/null; then
		scripts::logger::WARN "Codex CLI not available and could not be installed"
		scripts::logger::WARN "Skipping AI analysis"
		exit 0
	fi

	scripts::logger::INFO "Codex CLI installed successfully: $(which codex)"
fi

#
# Clone oadp-operator git repository
# Verify the analyze script exists locally
#
scripts::logger::INFO "Cloning oadp-operator repository..."
rm -rf "${OADP_GIT_DIR}"
git clone --depth=1 --branch="${REPO_BRANCH}" "${OADP_GIT_URL}" "${OADP_GIT_DIR}"
if [ ! -f "${ANALYZE_SCRIPT}" ]; then
	scripts::logger::ERR_MSG "Analysis script not found: ${ANALYZE_SCRIPT}"
	exit 1
fi

# Fetch flakes.go from oadp-operator

cd "${OADP_GIT_DIR}"
FLAKES_DIR="${ARTIFACT_DIR}/oadp-ref"
mkdir -p "${FLAKES_DIR}"
FLAKES_URL="https://raw.githubusercontent.com/${REPO_OWNER}/oadp-operator/${REPO_BRANCH}/tests/e2e/lib/flakes.go"

scripts::logger::INFO "Checked out branch: $(git rev-parse --abbrev-ref HEAD)"
scripts::logger::INFO "Commit: $(git rev-parse --short HEAD)"
scripts::logger::INFO "Fetching flakes.go from ${FLAKES_URL}"
if curl -sfL "${FLAKES_URL}" -o "${FLAKES_DIR}/flakes.go"; then
	export FLAKES_FILE="${FLAKES_DIR}/flakes.go"
	scripts::logger::INFO "✓ Fetched flakes.go to ${FLAKES_FILE}"
else
	scripts::logger::WARN "Could not fetch flakes.go (non-critical, analysis will continue without flake patterns)"
fi

#
# Verify the analyze script exists
# Detect test source code directory (oadp-e2e-qe, cloned by run.sh)
# This gives Codex access to read the actual test code that failed
#
if [ ! -f "${ANALYZE_SCRIPT}" ]; then
    scripts::logger::ERR_MSG "Analysis script not found: ${ANALYZE_SCRIPT}"
    scripts::logger::ERR_MSG "Repository may be on wrong branch or script path changed"
    exit 1
if [ -d "${WORKSPACE}/oadp-e2e-qe" ]; then
	export TEST_SOURCE_DIR="${WORKSPACE}/oadp-e2e-qe"
	scripts::logger::INFO "Test source code available: ${TEST_SOURCE_DIR}"
elif [ -d "${ARTIFACT_DIR}/../../" ] && [ -f "${ARTIFACT_DIR}/../../e2e_suite_test.go" ]; then
	export TEST_SOURCE_DIR="$(cd "${ARTIFACT_DIR}/../.." && pwd)"
	scripts::logger::INFO "Test source code available: ${TEST_SOURCE_DIR}"
else
	scripts::logger::WARN "Test source code (oadp-e2e-qe) not found — analysis will be limited"
fi

#
# Run the Claude AI analysis script
# Run the AI analysis script
#
scripts::logger::INFO "Running Claude AI failure analysis..."
scripts::logger::INFO "Running AI failure analysis..."
scripts::logger::INFO "Analysis script: ${ANALYZE_SCRIPT}"

set +e
bash "${ANALYZE_SCRIPT}" "${EXIT_CODE}"

ANALYSIS_EXIT=$?
set -e

if [ $ANALYSIS_EXIT -eq 0 ]; then
    scripts::logger::INFO "✓ Claude analysis completed successfully"
    scripts::logger::INFO "✓ AI analysis completed successfully"
    if [ -f "${ARTIFACT_DIR}/claude-failure-analysis.md" ]; then
        scripts::logger::INFO "✓ Analysis report: ${ARTIFACT_DIR}/claude-failure-analysis.md"
        scripts::logger::INFO "  Report: ${ARTIFACT_DIR}/claude-failure-analysis.md"
    fi
    if [ -f "${ARTIFACT_DIR}/ai-analysis-logs.txt" ]; then
        scripts::logger::INFO "  Logs: ${ARTIFACT_DIR}/ai-analysis-logs.txt"
    fi
else
    scripts::logger::WARN "Claude analysis exited with code: $ANALYSIS_EXIT"
    scripts::logger::WARN "AI analysis exited with code: $ANALYSIS_EXIT"
fi

# Return the original exit code, not the analysis exit code
# exit $EXIT_CODE
# exit ${EXIT_CODE}
