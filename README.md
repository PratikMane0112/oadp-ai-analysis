
After tests fail and artifacts are collected, run this:

```bash
# One-time: download the runner script
curl -sfL "https://raw.githubusercontent.com/PratikMane0112/oadp-ai-analysis/main/run-ai-analysis.sh" -o run-ai-analysis.sh

# Run with your own API key
export OPENAI_API_KEY="key-here-pease"
export ARTIFACT_DIR="$(pwd)/path/to/suite"
bash run-ai-analysis.sh
```
OR 

```bash
export OPENAI_API_KEY="sk-here-please"
export ARTIFACT_DIR="$(pwd)/path/to/suite"
curl -sfL "https://raw.githubusercontent.com/PratikMane0112/oadp-ai-analysis/main/run-ai-analysis.sh" | bash
```

