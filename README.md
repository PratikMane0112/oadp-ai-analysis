
After tests fail and artifacts are collected, run this:

```bash
# One-time: download the runner script
curl -sfL "https://raw.githubusercontent.com/PratikMane0112/oadp-ai-analysis/main/run-ai-analysis.sh" -o run-ai-analysis.sh

# Run with your own API key
export OPENAI_API_KEY="sk-their-key"
export ARTIFACT_DIR="/path/to/e2e/non-admin"
bash run-ai-analysis.sh
```
OR 

```bash
export OPENAI_API_KEY="sk-their-key"
export ARTIFACT_DIR="/path/to/e2e/non-admin"
curl -sfL "https://raw.githubusercontent.com/PratikMane0112/oadp-ai-analysis/main/run-ai-analysis.sh" | bash
```

