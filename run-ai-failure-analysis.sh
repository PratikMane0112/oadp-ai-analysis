#!/bin/bash

# Prompt for the API key securely (input will be hidden)
echo -n "Enter your AI API Key: "
read -s API_KEY
echo ""

# Export the API key (Change OPENAI_API_KEY to GEMINI_API_KEY if needed)
export OPENAI_API_KEY="${API_KEY}"

# ARTIFACT_DIR is inside your current directory (oadp-ai-analysis/e2e/non-admin)
export ARTIFACT_DIR="$(pwd)/e2e/non-admin"

# TEST_SOURCE_DIR is one level up (the parent oadp-e2e-qe directory)
export TEST_SOURCE_DIR="$(dirname "$(pwd)")"

echo "----------------------------------------"
echo "Artifact Dir: $ARTIFACT_DIR"
echo "Test Source:  $TEST_SOURCE_DIR"
echo "----------------------------------------"

# Run the analysis script
bash ai-failure-analysis.sh
