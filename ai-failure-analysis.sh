#!/bin/bash
#
# Analyze test failures with AI (OpenAI Codex CLI) after Ginkgo suite completes.
# Designed for QE automation — classifies failures by component owner
# (test automation, operator, velero, cli, non-admin, environment, flake).
#
# Prerequisites:
#    - Codex CLI installed (npm install -g @openai/codex)
#    - OPENAI_API_KEY set
#    - Test artifacts available in ARTIFACT_DIR
#
# Input artifacts:
#   - ${ARTIFACT_DIR}/junit_report.xml   — JUnit results
#   - ${ARTIFACT_DIR}/report.json        — Ginkgo JSON report (richer than JUnit)
#   - ${ARTIFACT_DIR}/logs/<TestName>/   — Per-test must-gather & pod logs
#   - ${ARTIFACT_DIR}/oadp-ref/flakes.go — Known flake patterns (fetched by caller)
#
# Optional:
#   - ${TEST_SOURCE_DIR}                 — Path to oadp-e2e-qe source (for test code analysis)
#
# Environment variables:
#   ARTIFACT_DIR                — Directory containing test artifacts (default: /tmp)
#   TEST_SOURCE_DIR             — Path to oadp-e2e-qe checkout (default: not set)
#   OPENAI_API_KEY              — OpenAI API key for Codex CLI
#   LARGE_FILE_THRESHOLD        — Bytes above which logs get preprocessed (default: 1MB)
#   OADP_OPERATOR_BRANCH        — Branch to fetch flakes.go from (default: oadp-dev)
#   REPO_OWNER                  — GitHub repo owner for flakes.go (default: openshift)

set +e # Don't exit on failure

# --- Environment & Setup ---
readonly SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
readonly TOP_DIR=$(
	cd "${SCRIPT_DIR}"
	git rev-parse --show-toplevel
)
readonly WORKSPACE="${WORKSPACE:-${TOP_DIR}}"
readonly REPO_OWNER="${REPO_OWNER:-openshift}"
readonly REPO_BRANCH="${OADP_OPERATOR_BRANCH:-oadp-dev}"

# Receives it from analyzeTestFailuresWithClaude(migrationqe-automation/vars/oadpQeAutomation.groovy)
EXIT_CODE="${1:-0}"

# Default artifact directory
export ARTIFACT_DIR="${ARTIFACT_DIR:-$(pwd)}"
AI_LOG_FILE="${ARTIFACT_DIR}/ai-analysis-logs.txt"

# Configurable Codex settings
CODEX_MODEL="${CODEX_MODEL:-gpt-5.6-terra}"
CODEX_SANDBOX="${CODEX_SANDBOX:-danger-full-access}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-high}"

# Source logger utility
source "${TOP_DIR}/scripts/logger.sh"

# Size thresholds for preprocessing (in bytes)
LARGE_FILE_THRESHOLD=${LARGE_FILE_THRESHOLD:-1048576} # 1MB
MAX_LOG_LINES=${MAX_LOG_LINES:-500}

# --- Verify prerequisites ---

# Verify OpenAI API key and register with Codex CLI
if [ -z "$OPENAI_API_KEY" ]; then
    echo "⚠ OPENAI_API_KEY not set"
    echo "Skipping AI analysis"
    exit $EXIT_CODE
fi

# Check for Codex CLI availability
if ! command -v codex &>/dev/null; then
    echo "⚠ Codex CLI not found in PATH"
    echo "Skipping AI analysis (install with: npm install -g @openai/codex)"
    exit $EXIT_CODE
fi

# Register API key with Codex CLI (needed for WebSocket auth)
printenv OPENAI_API_KEY | codex login --with-api-key 2>/dev/null || true

# --- Functions ---

# Redact sensitive information from logs and output
redact_secrets() {
    sed -E \
        -e 's/AKIA[0-9A-Z]{16}/[REDACTED-AWS-ACCESS-KEY]/g' \
        -e 's/(aws_secret_access_key[" :=]+)[A-Za-z0-9/+=]{40}/\1[REDACTED-AWS-SECRET]/g' \
        -e 's/"private_key": ?"-----BEGIN[^"]*END[^"]*"/"private_key": "[REDACTED-GCP-PRIVATE-KEY]"/g' \
        -e 's/Bearer +[A-Za-z0-9._~+-]+=*/Bearer [REDACTED-TOKEN]/g' \
        -e 's/(password[" :=]+)[^ "'\'']+/\1[REDACTED-PASSWORD]/gi' \
        -e 's/(passwd[" :=]+)[^ "'\'']+/\1[REDACTED-PASSWORD]/gi' \
        -e 's/(api[_-]?key[" :=]+)[^ "'\'']+/\1[REDACTED-APIKEY]/gi' \
        -e 's/(token[" :=]+)[A-Za-z0-9._~+-]+=*/\1[REDACTED-TOKEN]/gi' \
        -e 's/(secret[" :=]+)[^ "'\'']{16,}/\1[REDACTED-SECRET]/gi' \
        -e 's/eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*/[REDACTED-JWT-TOKEN]/g' \
        -e 's/-----BEGIN (RSA |EC )?PRIVATE KEY-----[^-]*-----END (RSA |EC )?PRIVATE KEY-----/[REDACTED-PRIVATE-KEY]/g' \
        -e 's/(client[_-]?secret[" :=]+)[^ "'\'']+/\1[REDACTED-CLIENT-SECRET]/gi' \
        -e 's/(authorization[" :]+)[^ "'\'']+/\1[REDACTED-AUTH]/gi'
}

# Get file size in bytes (cross-platform)
get_file_size() {
    local file="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        stat -f%z "$file" 2>/dev/null || echo 0
    else
        stat -c%s "$file" 2>/dev/null || echo 0
    fi
}

# Extract relevant errors from a large log file using Codex subagent
extract_log_errors() {
    local log_file="$1"
    local output_file="$2"
    local file_size=$(get_file_size "$log_file")

    if [ "$file_size" -lt "$LARGE_FILE_THRESHOLD" ]; then
        echo "=== Log: $(basename "$log_file") (${file_size} bytes) ===" >>"$output_file"
        head -n 50 "$log_file" >>"$output_file"
        echo "..." >>"$output_file"
        tail -n 100 "$log_file" >>"$output_file"
        return 0
    fi

    echo "  Preprocessing large log: $(basename "$log_file") (${file_size} bytes)"

    local subagent_output
    subagent_output=$(timeout 60 codex exec \
        --ephemeral \
        --sandbox "${CODEX_SANDBOX}" \
        -m "${CODEX_MODEL}" \
        -c model_reasoning_effort="${CODEX_REASONING_EFFORT}" \
        --add-dir "${ARTIFACT_DIR}" \
        "You are a log analysis assistant. Extract error messages, stack traces, and related context from this log file.

Log file: $log_file

CRITICAL INSTRUCTION: This is a READ-ONLY analysis task. Do NOT create, modify, or delete any files. Only read and inspect the provided artifacts.

Read the log file and output a summary containing:

1. **Error lines**: All lines containing 'error', 'Error', 'ERROR', 'fatal', 'Fatal', 'FATAL', 'panic', 'failed', 'Failed'
2. **Stack traces**: Lines starting with goroutine, at, or containing .go: source references
3. **Package context**: When you find an error from a specific Go package (identified by path like 'pkg/controller/', 'velero/pkg/', 'internal/'), include 3-5 additional log lines from the SAME package that occurred shortly before the error.
4. **Timeout and failure messages**: Any lines indicating timeouts or test failures
5. **Correlation**: Group related errors together - if multiple errors reference the same resource (backup name, PVC, pod), keep them together with their context.

Format each error group as:
--- [package/component name] ---
[context lines from same package]
[ERROR line]
[stack trace if present]

Maximum output: 250 lines. If more errors exist, prioritize the last 150 lines (most recent).
Do NOT include debug/info level messages unless they are from the same package as an error and occurred within 10 lines before it." 2>>"${AI_LOG_FILE}")

    if [ $? -eq 0 ] && [ -n "$subagent_output" ]; then
        echo "=== Log: $(basename "$log_file") (subagent extracted) ===" >>"$output_file"
        echo "$subagent_output" | head -n 200 >>"$output_file"
    else
        echo "=== Log: $(basename "$log_file") (fallback grep) ===" >>"$output_file"
        grep -i -E '(error|fatal|panic|failed|timeout|exception)' "$log_file" 2>/dev/null | tail -n 100 >>"$output_file"
    fi
}

# Preprocess large must-gather and per-test logs into summaries
preprocess_large_artifacts() {
    local summary_file="${ARTIFACT_DIR}/preprocessed-logs.txt"
    echo "# Preprocessed Log Summaries" >"$summary_file"
    echo "# Generated by subagent preprocessing" >>"$summary_file"
    echo "# Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >>"$summary_file"
    echo "" >>"$summary_file"

    local large_files_found=0

    # Find large log files in per-test directories (logs/<TestName>/)
    if [ -d "${ARTIFACT_DIR}/logs" ]; then
        while IFS= read -r log_file; do
            [ -z "$log_file" ] && continue
            large_files_found=$((large_files_found + 1))
            extract_log_errors "$log_file" "$summary_file"
            echo "" >>"$summary_file"
        done < <(find "${ARTIFACT_DIR}/logs" -name "*.log" -type f 2>/dev/null | while read f; do
            size=$(get_file_size "$f")
            if [ "$size" -ge "$LARGE_FILE_THRESHOLD" ]; then
                echo "$f"
            fi
        done | head -20)
    fi

    if [ "$large_files_found" -eq 0 ]; then
        echo "No large log files found requiring preprocessing" >>"$summary_file"
    else
        echo "Preprocessed $large_files_found large log files"
    fi

    echo "$summary_file"
}

# --- Prepare Test Context ---

# Fetch flakes.go from oadp-operator
FLAKES_DIR="${ARTIFACT_DIR}/oadp-ref"
mkdir -p "${FLAKES_DIR}"
FLAKES_URL="https://raw.githubusercontent.com/${REPO_OWNER}/oadp-operator/${REPO_BRANCH}/tests/e2e/lib/flakes.go"

scripts::logger::INFO "Fetching flakes.go from ${FLAKES_URL}"
if curl -sfL "${FLAKES_URL}" -o "${FLAKES_DIR}/flakes.go"; then
	export FLAKES_FILE="${FLAKES_DIR}/flakes.go"
	scripts::logger::INFO "✓ Fetched flakes.go to ${FLAKES_FILE}"
else
	scripts::logger::WARN "Could not fetch flakes.go (non-critical, analysis will continue without flake patterns)"
fi

# Detect test source code directory (oadp-e2e-qe, cloned by run.sh)
if [ -d "${WORKSPACE}/oadp-e2e-qe" ]; then
	export TEST_SOURCE_DIR="${WORKSPACE}/oadp-e2e-qe"
	scripts::logger::INFO "Test source code available: ${TEST_SOURCE_DIR}"
elif [ -d "${ARTIFACT_DIR}/../../" ] && [ -f "${ARTIFACT_DIR}/../../e2e_suite_test.go" ]; then
	export TEST_SOURCE_DIR="$(cd "${ARTIFACT_DIR}/../.." && pwd)"
	scripts::logger::INFO "Test source code available: ${TEST_SOURCE_DIR}"
else
	scripts::logger::WARN "Test source code (oadp-e2e-qe) not found — analysis will be limited for automation issue"
    exit 1
fi

# --- Run Analysis ---

if [ $EXIT_CODE -ne 0 ]; then
    echo "=== Test failures detected, invoking AI analysis ==="
    # echo "ARTIFACT_DIR: $ARTIFACT_DIR"
    # if [ -n "$TEST_SOURCE_DIR" ]; then
    #     echo "TEST_SOURCE_DIR: $TEST_SOURCE_DIR"
    # fi

    # Preprocess large artifacts with subagent pattern
    echo "Preprocessing large log files..."
    PREPROCESSED_FILE=$(preprocess_large_artifacts)
    echo "Preprocessed summaries saved to: $PREPROCESSED_FILE"

    # Extract only failed specs from report.json
    if [ -f "${ARTIFACT_DIR}/report.json" ] && command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
with open('${ARTIFACT_DIR}/report.json') as f:
    data = json.load(f)
result = {'SuiteDescription': data[0].get('SuiteDescription',''), 'PreRunStats': data[0].get('PreRunStats',{}), 'SuiteConfig': data[0].get('SuiteConfig',{})}
specs = data[0].get('SpecReports', [])
result['FailedSpecs'] = [s for s in specs if s.get('State') == 'failed']
result['PassedCount'] = sum(1 for s in specs if s.get('State') == 'passed')
result['SkippedCount'] = sum(1 for s in specs if s.get('State') == 'skipped')
result['PendingCount'] = sum(1 for s in specs if s.get('State') == 'pending')
result['TotalSpecs'] = len(specs)
json.dump(result, open('${ARTIFACT_DIR}/failed-specs.json','w'), indent=2)
print(f'Extracted {len(result[\"FailedSpecs\"])} failed specs from {len(specs)} total ({len(json.dumps(result)):,} chars vs {len(json.dumps(data)):,} chars original)')
" 2>/dev/null && echo "✓ Created failed-specs.json (reduced token input)" || echo "⚠ Could not preprocess report.json, AI will use full file"
    fi

    # Build --add-dir flags
    ADD_DIR_FLAGS="--add-dir ${ARTIFACT_DIR}"
    if [ -n "$TEST_SOURCE_DIR" ] && [ -d "$TEST_SOURCE_DIR" ]; then
        ADD_DIR_FLAGS="$ADD_DIR_FLAGS --add-dir $TEST_SOURCE_DIR"
        echo "Test source code: $TEST_SOURCE_DIR"
    fi

    ##########################
    # Create analysis prompt 
    ##########################
    cat >"${ARTIFACT_DIR}/codex-prompt.txt" <<PROMPT_EOF
# OADP E2E QE Automation Test Failure Analysis

You are a Senior Principle QE (Quality Engineering) analyst for OADP (OpenShift API for Data Protection).
Analyze failed E2E tests and classify each failure by the component/repo that owns the bug.

## OADP Ecosystem — Component Ownership

Classify each failure by the component that owns the bug.
When error messages reference Go package paths, use them to identify the source repo.

**Core (openshift org):**
- **openshift/oadp-operator** — DPA reconciler, BSL/VSL management. Errors: operator-manager logs, DPA reconciliation, etc
- **openshift/velero** — Backup/restore engine. Errors from \`pkg/backup/\`, \`pkg/restore/\`, \`pkg/controller/\`, \`pkg/nodeagent/\`, etc
- **openshift/openshift-velero-plugin** — OCP resource handling. Errors: \`openshift-velero-plugin\` container logs, etc
- **openshift/velero-plugin-for-aws** — S3 storage. Errors: AWS API failures, \`NoSuchBucket\`, \`AccessDenied\`, etc
- **openshift/velero-plugin-for-gcp** — GCS storage. Errors: GCP API failures,etc
- **openshift/velero-plugin-for-microsoft-azure** — Azure Blob. Errors: Azure API failures, etc
- **openshift/velero-plugin-for-csi** — CSI snapshots. Errors: \`VolumeSnapshot\` failures, CSI driver errors, etc
- **openshift/oadp-must-gather** — Diagnostic collection. Errors in must-gather itself (not captured data), etc
- **openshift/hypershift-oadp-plugin** — HyperShift hosted cluster backup. Errors: HyperShift plugin logs, etc

**Plugins & Tools (migtools org):**
- **migtools/oadp-non-admin** — Namespace-scoped backup/restore (NAB/NAR). Errors: non-admin-controller logs, etc
- **migtools/oadp-cli** — \`oc oadp\` / \`kubectl-oadp\`. Errors: CLI output, \`exec format error\`, etc
- **migtools/kubevirt-velero-plugin** — VM backup. Errors: kubevirt plugin logs, VMI-related failures, etc
- **migtools/oadp-vmdp** — VM data protection. Errors: vmdp-server logs, etc

**QE & Infra:**
- **oadp-e2e-qe** (GitLab) — Test suite. Wrong test data, assertion bugs, framework issues, etc
- **oadp-apps-deployer** (GitLab) — Ansible app deployer. Errors: \`TASK [...] FAILED\`, \`fatal:\`, in Ginkgo output from \`lib/apps.go\`, etc
- **Environment** — Cluster/infra. Node NotReady, API timeouts, image pull failures, cloud rate limits, etc

## Available Artifacts

### 1. Failed Specs JSON (PRIMARY — use this first)
- File: \`${ARTIFACT_DIR}/failed-specs.json\` (preprocessed, contains ONLY failed specs)
- Each failed spec contains:
  - \`LeafNodeLocation\`: exact file and line number where the test is defined
  - \`Failure.Location\`: exact file and line number where the assertion failed
  - \`Failure.Message\`: full failure message
  - \`CapturedGinkgoWriterOutput\`: full test output (logs written during test execution)
  - \`NumAttempts\` / \`MaxFlakeAttempts\`: how many retries happened
  - \`ContainerHierarchyTexts\`: full Describe/Context/It hierarchy
  - \`SpecEvents\`: timeline of events during the spec
  - \`AdditionalFailures\`: secondary failures (e.g., AfterEach cleanup failures)
- Parse this to identify ALL failed specs and extract failure details.

### 2. JUnit Report (supplementary)
- File: \`${ARTIFACT_DIR}/junit_report.xml\`
- Standard JUnit XML — less detailed than report.json but useful for cross-reference.

### 3. Per-Test Must-Gather & Pod Logs
- Directory: \`${ARTIFACT_DIR}/logs/\`
- Structure: \`logs/<TestName>/<must-gather-image>/clusters/<cluster-id>/\`
  - \`oadp-must-gather-summary.md\` — structured summary of OADP state (DPA, BSL, VSL, Backups, Restores, errors)
  - \`namespaces/<oadp-namespace>/\` — OADP namespace resources: pod logs, DPA YAML, BSL/VSL status
  - \`namespaces/<oadp-namespace>/velero.io/backups/describe-*.txt\` — Velero backup descriptions (phase, errors, items backed up)
  - \`namespaces/<oadp-namespace>/velero.io/restores/describe-*.txt\` — Velero restore descriptions
  - \`namespaces/<oadp-namespace>/pods/<pod-name>/<container>/logs/current.log\` — Container logs
  - \`cluster-scoped-resources/\` — CSI drivers, storage classes, CRDs
- **Parallel test namespaces**: Tests run in parallel across multiple OADP instances, each in its own namespace.
  The three namespaces used are:
  - \`openshift-adp\` — default/primary OADP namespace
  - \`openshift-adp-2\` — parallel OADP instance
  - \`openshift-adp-100000000000000000000000\` — parallel OADP instance
  When analyzing a failed test, check which namespace it ran in (visible in the must-gather path
  and in the test's Ginkgo output). Look for pod logs and OADP resources under the correct namespace.
  Each namespace has its own DPA, BSL, VSL, Velero deployment, and controller-manager.
- **Important**: The \`oadp-must-gather-summary.md\` is the fastest way to understand cluster state. Read it FIRST for each failed test.

### 4. Preprocessed Log Summaries
- File: \`${ARTIFACT_DIR}/preprocessed-logs.txt\`
- Pre-extracted errors from log files > 1MB. Check this for quick access to large log errors.

### 5. Known Flake Patterns
- File: \`${ARTIFACT_DIR}/oadp-ref/flakes.go\` (if available)
- Contains \`flakePatterns\` with Issue, Description, and StringSearchPattern
- Cross-reference failures against these patterns before diagnosing as real bugs.

$(if [ -n "$TEST_SOURCE_DIR" ] && [ -d "$TEST_SOURCE_DIR" ]; then
        cat <<SRCEOF
### 6. Test Source Code
- Directory: \`${TEST_SOURCE_DIR}\`
- This is the \`oadp-e2e-qe\` test suite source code.
- Key directories:
  - \`e2e/app_backup/\` — Application backup/restore test definitions (DescribeTable entries)
  - \`e2e/cli/\` — CLI test definitions
  - \`e2e/non-admin/\` — Non-admin backup/restore tests
  - \`e2e/dpa_deploy/\` — DPA deployment/configuration tests
  - \`e2e/kubevirt-plugin/\` — KubeVirt VM backup tests
  - \`lib/\` — Test helper functions (backup.go, restore.go, must_gather_helpers.go, apps.go, etc.)
  - \`lib/apps.go\` — App deploy/cleanup/validate via Ansible (calls oadp-apps-deployer playbooks)
  - \`sample-applications/\` — Ansible playbooks and roles from oadp-apps-deployer (installed via pip)
  - \`test_common/\` — Common test framework (backup_restore_case.go)
- **USE THIS** to read the actual test code that failed. The \`Failure.Location\` from report.json tells you the exact file:line.
  Read that file to understand what the test was doing and whether the failure is a test automation bug vs product bug.
SRCEOF
    fi)

## Analysis Tasks

For each failed test:

1. **Parse report.json** — get the exact failure message, location, test hierarchy, and output.
2. **Read the test source code** (if available) — understand what the test was trying to do.
   Use \`Failure.Location.FileName\` and \`LeafNodeLocation.FileName\` from report.json.
3. **Read the must-gather summary** — \`logs/<TestName>/.../oadp-must-gather-summary.md\`
4. **Read relevant pod logs** — velero, controller-manager, plugins, node-agent
5. **Read backup/restore describe files** — \`velero.io/backups/describe-*.txt\`
6. **Check preprocessed-logs.txt** for errors from large log files
7. **Cross-reference with flakes.go** for known flake patterns
8. **Classify the root cause** by component owner (see table above)

## Classification Rules

Classify by **which repo to file the bug in**. Use Go package paths from error messages to trace the source:

- **TEST_AUTOMATION_BUG** → oadp-e2e-qe — test code bug (wrong data, assertion, framework)
- **PRODUCT_BUG_OPERATOR** → openshift/oadp-operator — DPA, BSL/VSL, deployment issues
- **PRODUCT_BUG_VELERO** → openshift/velero — backup/restore engine (\`pkg/backup/\`, \`pkg/restore/\`)
- **PRODUCT_BUG_VELERO_PLUGIN** → the specific plugin repo (aws/gcp/azure/csi) based on error source
- **PRODUCT_BUG_CLI** → migtools/oadp-cli — CLI command failures
- **PRODUCT_BUG_NON_ADMIN** → migtools/oadp-non-admin — NAB/NAR controller errors
- **PRODUCT_BUG_KUBEVIRT** → migtools/kubevirt-velero-plugin — VM backup failures
- **PRODUCT_BUG_VMDP** → migtools/oadp-vmdp — VM data protection errors
- **APPS_DEPLOYER_BUG** → oadp-apps-deployer (GitLab) — Ansible playbook failures (\`TASK [...] FAILED\`)
- **MUST_GATHER_BUG** → openshift/oadp-must-gather — collection itself failed
- **ENVIRONMENT** → No bug; cluster/infra issue (retry or fix)
- **KNOWN_FLAKE** → Matches flakes.go pattern; re-run, track in existing issue

## Output Format

Generate a markdown document with this structure:

\`\`\`markdown
# OADP E2E QE Automation Test Failure Analysis
*Generated by AI analysis on <timestamp>*

## Executive Summary
- **Total Tests**: X | **Passed**: Y | **Failed**: Z | **Skipped**: W
- **Test Automation Bugs**: N (oadp-e2e-qe)
- **Product Bugs**: N (breakdown by repo)
- **Known Flakes**: N
- **Environment Issues**: N

## Failed Tests

### 1. [tc-id:OADP-XXX] <TestName>

**Classification**: <one of: TEST_AUTOMATION_BUG | PRODUCT_BUG_OPERATOR | PRODUCT_BUG_VELERO | PRODUCT_BUG_CLI | PRODUCT_BUG_NON_ADMIN | PRODUCT_BUG_KUBEVIRT | APPS_DEPLOYER_BUG | MUST_GATHER_BUG | ENVIRONMENT | KNOWN_FLAKE>

**File Bug In**: <repo name> (or "No bug — re-run" for flakes, "No bug — fix infra" for environment)

**Root Cause**: <One clear sentence>

**Evidence**:
- report.json: <failure message, file:line>
- Test source: <what the test was doing, file:line> (if available)
- Must-gather: <relevant finding from summary or pod logs>
- Pod logs: <relevant error excerpts>

**Diagnosis**: <Detailed analysis>

**Recommended Fix**:
1. <Specific action with file:line reference>

**Retries**: <N/M attempts failed, all identical / varied> (helps distinguish flakes from real bugs)

---

### 2. [tc-id:OADP-YYY] ...

[Repeat for each failed test]

## Secondary Findings
List issues found in must-gather or logs that are NOT the primary failure cause
but worth noting (e.g., must-gather helper bugs, minor warnings).

## Known Flakes Matched
- ✓/✗ for each pattern in flakes.go

## Container Startup Timing Comparison

For each failed backup/restore test that involves deployment readiness or startup probe failures,
extract timing data from per-test pod logs and present a comparison table against typical healthy
baseline values. Skip this section for tests that did not involve deployment readiness checks.

**Test**: <TestName>

| Metric | Typical (healthy baseline) | This Run (failed) |
|--------|---------------------------|--------------------|
| Post-restore container startup | ~25-30 seconds | <actual seconds or "Never succeeded (Xs timeout)"> |
| Startup probe failures | 0 | <count from pod logs> |
| Container restarts | 0 | <count from pod logs> |
| IsDeploymentReady polls needed | 2-3 | <count or "timed out at X min"> |
| Total test duration | ~3-4 minutes | <actual duration from JUnit> |

**How to extract these values from logs**:
- Restore completion: look for "restore phase: Completed" timestamp in per-test logs
- Container ready: look for ContainersReady or MinimumReplicasAvailable pod condition timestamps
- Startup probe failures: count "Startup probe failed" or "failed startup probe" log lines
- Container restarts: count "will be restarted" log lines
- IsDeploymentReady polls: count "deployment not available" or "Deployment todolist status" log lines
- Test duration: from JUnit report or Ginkgo enter/exit timestamps

Note: The "Typical" column values are baseline reference values from healthy OADP E2E runs on AWS.
Adjust if running on a different cloud provider. If multiple backup/restore tests failed, include
a separate table for each.

## Cluster Health Summary

From must-gather analysis (report for each OADP namespace that had failures):

**OADP Components** (per namespace: openshift-adp, openshift-adp-2, openshift-adp-000000000):
- Velero deployment: <status, restart count, resource usage>
- Node Agent daemonset: <X/Y running, any issues>
- Backup Storage Location: <Available/Unavailable, last sync time>
- Volume Snapshot Location: <Available/Unavailable, provider status>
- Controller-manager: <status, restart count>

**Cluster Resources**:
- CSI drivers: <driver names and status>
- Storage classes: <available SCs>
- Resource pressure: <CPU/memory/storage issues if any>

**Recent Events**:
<Significant namespace events from must-gather>

## QE Action Items (Prioritized)

### Immediate Actions (Critical)
1. [HIGH] <action> → file in <repo>

### Investigation Needed
1. [MEDIUM] <action> → file in <repo>

### Flake Handling
1. [LOW] <suggestion for known flakes>

## Analysis Confidence

- **High Confidence**: <List tests where root cause is clear>
- **Medium Confidence**: <List tests needing more data>
- **Low Confidence**: <List tests with ambiguous failures>

## Suggested Next Steps for QE

1. Review critical issues first (prioritized above)
2. Check if failures match existing GitHub/Jira issues
3. Re-run flakes to confirm transient nature
4. Investigate environmental issues in cluster/cloud provider

## Must-Gather Improvement Suggestions

If information was missing or incomplete during analysis, list what additional data would have helped:

### Missing Data That Would Have Helped
- <What was needed and why it would have helped diagnosis>
- <Specific resource/log/metric that was missing>

### Recommended Must-Gather Enhancements
1. **<Category>**: <Specific improvement suggestion>
   - Current gap: <What's missing>
   - Suggested addition: <What to collect>
   - Example: <Concrete example of the data needed>

Examples of potential improvements:
- Additional pod logs (e.g., init containers, sidecar containers)
- Specific CRD status fields not currently captured
- Cluster-level resources affecting OADP (NetworkPolicies, ResourceQuotas)
- Timing/metrics data (pod startup times, API latencies)
- Cloud provider specific diagnostics (S3 bucket policies, IAM roles)
\`\`\`

## Important Guidelines

- **Read failed-specs.json first**
- **Read JUnit report** for supplementary information
- **Read test source code** when available — this is the key to distinguishing test automation bugs from product bugs.
- **Read oadp-must-gather-summary.md** for each failed test — it's in \`logs/<TestName>/.../clusters/<id>/oadp-must-gather-summary.md\`.
- **Check all retry attempts** — if 3/3 attempts fail identically, it's NOT a flake.
- **Check velero pod, controller-manager pod, node-agent pod logs** failures collected from preprocessed-logs.txt for any errors or warnings that could help in the diagnosis.
- **Timing comparison**: For any backup/restore test failure involving deployment readiness
  timeouts or startup probe failures, ALWAYS include the Container Startup Timing Comparison
  table. Extract actual timing values from per-test pod logs and compare against the healthy
  baseline. This is critical for distinguishing environmental slowness from real bugs.
- **Must-gather feedback**: When you cannot determine root cause due to missing information,
  explicitly note what additional must-gather data would have helped. This feedback loop
  improves future debugging capabilities.
- **Be evidence-based** — cite file paths and log excerpts. Don't speculate.
- **Be concise** — QE engineers need quick, actionable insights.
- **Distinguish failure types**: Real bugs vs flakes vs environmental vs configuration (QE needs to know which repo to file the bug in if its a product bug (see table above))
- **Be actionable**: Recommendations should be on through thorough analysis and not on guesswork
- **Cross-reference**: Link similar failures across multiple tests

VERY IMPORTANT NOTES : 
1. Do not hallucinate on your own, your analysis should uphold any information on facts and evidences.
2. Do not includ/print any sensitive information (API keys, tokens, passwords or credentials) in your output.

PROMPT_EOF

    # Count failed tests from failed-specs.json
    FAILED_COUNT=0
    if [ -f "${ARTIFACT_DIR}/failed-specs.json" ] && command -v python3 &>/dev/null; then
        FAILED_COUNT=$(python3 -c "import json; print(len(json.load(open('${ARTIFACT_DIR}/failed-specs.json')).get('FailedSpecs',[])))" 2>/dev/null || echo "0")
    elif [ -f "${ARTIFACT_DIR}/junit_report.xml" ]; then
        FAILED_COUNT=$(grep -c '<failure' "${ARTIFACT_DIR}/junit_report.xml" 2>/dev/null || echo "0")
    fi

    scripts::logger::INFO "Found $FAILED_COUNT test failures"
    scripts::logger::INFO "Invoking Codex for analysis..."

    # Create temp file for Codex output
    TEMP_OUTPUT=$(mktemp)
    trap "rm -f $TEMP_OUTPUT" EXIT

    echo "AI analysis in progress, please wait..."
    timeout 600 codex exec \
        --ephemeral \
        --sandbox "${CODEX_SANDBOX}" \
        -m "${CODEX_MODEL}" \
        -c model_reasoning_effort="${CODEX_REASONING_EFFORT}" \
        $ADD_DIR_FLAGS \
        -o "$TEMP_OUTPUT" \
        "You are a senior principle QE analyst for OADP (OpenShift API for Data Protection).

CRITICAL INSTRUCTION: This is a READ-ONLY analysis task. Do NOT create, modify, delete, or rename any files or directories. 
Only read and inspect the provided source files and test artifacts to produce your analysis. All output must be returned as text in your response only.
Read the full analysis instructions in: ${ARTIFACT_DIR}/codex-prompt.txt

Analyze these artifacts IN THIS ORDER:
1. Failed specs: ${ARTIFACT_DIR}/failed-specs.json (START HERE — preprocessed, only failed tests)
2. Preprocessed log errors: ${ARTIFACT_DIR}/preprocessed-logs.txt for these failed tests
3. Per-test must-gather: ${ARTIFACT_DIR}/logs/*/  (find oadp-must-gather-summary.md inside)
4. JUnit report: ${ARTIFACT_DIR}/junit_report.xml (supplementary)
5. Known flakes: ${ARTIFACT_DIR}/oadp-ref/flakes.go (if exists)
$([ -n "$TEST_SOURCE_DIR" ] && echo "6. Test source code: ${TEST_SOURCE_DIR}/e2e/ and ${TEST_SOURCE_DIR}/lib/")
For each failure:
- Classify by component owner (which repo to file the bug in)
- Distinguish test automation bugs from product bugs
- Cite evidence with file paths
- Check if retries all failed identically (not a flake) or varied (possible flake)

IMPORTANT: Do NOT include any API keys, tokens, passwords, or credentials in your output." 2>&1 | tee -a "${AI_LOG_FILE}"

    CODEX_EXIT=$?

    # Apply secret redaction to output
    if [ -f "$TEMP_OUTPUT" ] && [ -s "$TEMP_OUTPUT" ]; then
        redact_secrets <"$TEMP_OUTPUT" >"${ARTIFACT_DIR}/claude-failure-analysis.md"
    fi

    if [ $CODEX_EXIT -eq 0 ]; then
        echo "✓ AI analysis completed successfully "
        echo "✓ Analysis saved to: ${ARTIFACT_DIR}/claude-failure-analysis.md"
    elif [ $CODEX_EXIT -eq 124 ]; then
        echo "✗ AI analysis timed out after 10 minutes"
        echo "Partial analysis may be in ${ARTIFACT_DIR}/claude-failure-analysis.md"
    else
        echo "✗ AI analysis failed (exit code: $CODEX_EXIT)"
        echo "Check ${ARTIFACT_DIR}/claude-failure-analysis.md for error details"
    fi

    rm -f "$TEMP_OUTPUT"

else
    echo "Tests passed, skipping AI analysis"
fi

exit "${EXIT_CODE:-0}"
