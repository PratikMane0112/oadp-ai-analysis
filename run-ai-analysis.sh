#!/bin/bash
#
# OADP AI Test Failure Analysis — Bootstrap Runner
#
# Downloads analyze_failures.sh from GitHub and runs it.
# No repo clone needed — just this script + your API key.
#
# Usage:
#   export OPENAI_API_KEY="sk-your-key"
#   export ARTIFACT_DIR="/path/to/e2e/non-admin"
#   bash run-ai-analysis.sh
#
# Optional:
#   export TEST_SOURCE_DIR="/path/to/oadp-e2e-qe"
#   export LARGE_FILE_THRESHOLD=1048576
#

set -e

# ── Configuration ──────────────────────────────────────

GITHUB_REPO="https://raw.githubusercontent.com/PratikMane0112/oadp-ai-analysis/main"
SCRIPT_NAME="analyze_failures.sh"

# ── Validate required variables ────────────────────────
if [ -z "$OPENAI_API_KEY" ]; then
    echo "ERROR: OPENAI_API_KEY is not set"
    echo ""
    echo "Usage:"
    echo "  export OPENAI_API_KEY=\"sk-your-key\""
    echo "  export ARTIFACT_DIR=\"/path/to/e2e/non-admin\""
    echo "  bash $0"
    exit 1
fi

if [ -z "$ARTIFACT_DIR" ]; then
    echo "ERROR: ARTIFACT_DIR is not set"
    echo "  Set it to the directory containing junit_report.xml and report.json"
    exit 1
fi

if [ ! -d "$ARTIFACT_DIR" ]; then
    echo "ERROR: ARTIFACT_DIR does not exist: $ARTIFACT_DIR"
    exit 1
fi

# Check for required artifacts
if [ ! -f "${ARTIFACT_DIR}/report.json" ] && [ ! -f "${ARTIFACT_DIR}/junit_report.xml" ]; then
    echo "ERROR: No test artifacts found in $ARTIFACT_DIR"
    echo "  Expected: report.json and/or junit_report.xml"
    exit 1
fi

# ── Install Codex CLI if needed ────────────────────────
if ! command -v codex &>/dev/null; then
    echo "Codex CLI not found, installing..."
    npm install -g @openai/codex 2>&1 || true

    if ! command -v codex &>/dev/null; then
        echo "Global install failed, installing locally..."
        CODEX_INSTALL_DIR="${HOME}/.codex-cli"
        npm install @openai/codex --prefix "${CODEX_INSTALL_DIR}" 2>&1 || true
        export PATH="${CODEX_INSTALL_DIR}/node_modules/.bin:${PATH}"
    fi

    if ! command -v codex &>/dev/null; then
        echo "ERROR: Could not install Codex CLI. Make sure npm is available."
        exit 1
    fi
    echo "✓ Codex CLI installed: $(which codex)"
fi

# ── Download analysis script ──────────────────────────
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

echo "Downloading analysis script..."
if ! curl -sfL "${GITHUB_REPO}/${SCRIPT_NAME}" -o "${WORK_DIR}/${SCRIPT_NAME}"; then
    echo "ERROR: Failed to download ${SCRIPT_NAME} from ${GITHUB_REPO}"
    exit 1
fi
chmod +x "${WORK_DIR}/${SCRIPT_NAME}"
echo "✓ Downloaded ${SCRIPT_NAME}"

# ── Run analysis ──────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  OADP AI Failure Analysis"
echo "  Artifacts: $ARTIFACT_DIR"
[ -n "$TEST_SOURCE_DIR" ] && echo "  Test source: $TEST_SOURCE_DIR"
echo "════════════════════════════════════════"
echo ""

bash "${WORK_DIR}/${SCRIPT_NAME}" 1
[12:59 PM]echo ""
echo "════════════════════════════════════════"
echo "  Analysis complete!"
[ -f "${ARTIFACT_DIR}/claude-failure-analysis.md" ] && echo "  Report: ${ARTIFACT_DIR}/claude-failure-analysis.md"
[ -f "${ARTIFACT_DIR}/ai-analysis-logs.txt" ] && echo "  Logs:   ${ARTIFACT_DIR}/ai-analysis-logs.txt"
echo "════════════════════════════════════════"
