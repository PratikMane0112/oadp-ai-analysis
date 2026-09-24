```bash
######################################################################
Triggering AI analysis, After tests fail and artifacts are collected:

Automatically analyze OADP e2e test failures using OpenAI Codex CLI.
When tests fail, this tool reads the test artifacts (JUnit reports,
Ginkgo JSON reports, must-gather logs) and produces a detailed
failure analysis report in Markdown.
######################################################################

#########################
Prerequisites:
codex cli installed
#########################

######################################################################################################
# 1. Clone the repo
git clone https://github.com/PratikMane0112/oadp-ai-analysis.git

# 2. Run AI analysis
export OPENAI_API_KEY="key-here-please"
export ARTIFACT_DIR="$(pwd)/path/to/suite"  # add path to suite of which test case is part
export TEST_SOURCE_DIR="$(pwd)"            # optional: path to the oadp-e2e-qe repo for automationissue
bash run-ai-analysis.sh
######################################################################################################
```


```bash
- For example :

# 1. oadp-e2e-qe repo is cloned & run a test case which fails

export KUBECONFIG=/path/to/kubeconfig
export CLOUD_PROVIDER=<>
export BUCKET=<bucket-name>                          
export BACKUP_LOCATION=<>
export OADP_CREDS_FILE=/path/to/credentials    
TESTS_FOLDER=e2e/non-admin EXTRA_GINKGO_PARAMS="--focus=OADP-637" make run

# When tests complete, artifacts are collected in the e2e/non-admin directory:
# e2e/non-admin/
# ├── report.json           # Ginkgo JSON report (primary input)
# ├── junit_report.xml      # JUnit test results
# └── logs/                 # Per-test logs by must gather
#     └── <TestName>/       # worklload manifests & pod logs

# 2. run AI analysis after cloning this repo

export OPENAI_API_KEY=""
export ARTIFACT_DIR="$(pwd)/e2e/non-admin"
export TEST_SOURCE_DIR="$(pwd)"           
bash run-ai-analysis.sh

# When AI analysis completes, below files are created :
# e2e/non-admin/
#      ├── claude-failure-analysis.md   # AI analysis report (to see final results)
#      └── ai-analysis-logs.txt         # Codex verbose logs (to know how ai done analysis behind the scenes)
#      ├── failed-specs.json            # info about only failed spec from report.json (provided as context to ai)
#      └── codex-prompt.txt             # Prompt given to AI for analysis (provided as context to ai)

# 3. Open the md file to see results
cat "e2e/non-admin/claude-failure-analysis.md"
```
