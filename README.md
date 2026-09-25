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
export ARTIFACT_DIR="/path/to/suite"                    # absolute path to suite of which test case is part
export TEST_SOURCE_DIR="path/to/oadp-e2e-qe"            # optional: absolute path to the oadp-e2e-qe repo for automationissue
bash run-ai-analysis.sh
######################################################################################################
```


```bash
- For example :

# 1. oadp-e2e-qe repo is cloned & a test case is failed & all resources are collected.

# in oadp-e2e-qe dir
export KUBECONFIG=/path/to/kubeconfig
export CLOUD_PROVIDER=<>
export BUCKET=<bucket-name>                          
export BACKUP_LOCATION=<>
export OADP_CREDS_FILE=/path/to/credentials    
TESTS_FOLDER=e2e EXTRA_GINKGO_PARAMS="--focus=OADP-79" make run

# When tests complete, artifacts are collected in the e2e directory:
# oadp-e2e-qe/
#   e2e/
#   ├── report.json              # Ginkgo JSON report (created by gingko framework)
#   ├── junit_report.xml         # JUnit test results (created by gingko framework)
#   └── logs/                    # Per-test logs by must gather
#      └── <tc:OADP-752>/       # worklload manifests & pod logs

# 2. run AI analysis 

# 2.1 clone this repo in top-dir

top-dir $ git clone https://github.com/PratikMane0112/oadp-ai-analysis.git

# Tests dirs after cloned:
#
# top-dir/ 
#   oadp-ai-anaysis/
#      ├──scripts/
#         ├── logger.sh  
#      ├── ai-failure-analysis.sh          
#   oadp-e2e-qe/
#     e2e/
#     ├── report.json              
#     ├── junit_report.xml         
#     └── logs/                    

# 2.2 run the script to trigger ai analysis in top-dir
export OPENAI_API_KEY=""
export WORKSPACE="$(pwd)"
export ARTIFACT_DIR="$(pwd)/oadp-e2e-qe/e2e"         
bash oadp-ai-analysis/ai-failure-analysis.sh 1

# When AI analysis completes, below files are created :
# e2e/
#  ├──.ai-redacted (redacted copies of files)
#      ├── preprocessed-logs.json       # reduced logs version of large logs (provided as context to ai)
#      ├── logs                         # must-gather logs (pre-processed & add only failed lines in preprocessed-logs.json)
#      ├── oadp-ref/flake.go            # known flakes from (oadp-operator/tests/e2e/lib/flakes.go provided as context to ai)
#      ├── failed-specs.json            # info about only failed spec from report.json (provided as context to ai)
#      └── ai-prompt.txt                # Prompt given to AI for analysis (provided as context to ai)
#
#  ├── ai-analysis-logs.txt             # AI verbose logs (to know how ai done analysis behind the scenes)#
#  ├── ai-failure-analysis.md           # AI analysis report (to see final results)

# 3. Open the md file to see results
cat "e2e/ai-failure-analysis.md"
```
