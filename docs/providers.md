# LLM Providers

Quipu has one LLM provider abstraction for answer generation, entity resolution, and eval judging. The core still defaults to deterministic behavior when no provider is configured, so local development works without an API key.

## Quick Start

```bash
export OPENAI_API_KEY="sk-..."
quipu llm-check
quipu serve-stdio --llm-provider openai --llm-model gpt-4o
```

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
quipu serve-stdio --llm-provider anthropic --llm-model claude-sonnet-4-20250514
```

```bash
quipu serve-stdio --llm-provider ollama --llm-model llama3.3 --llm-base-url http://localhost:11434
```

Existing flags still work:

```bash
export OPENROUTER_API_KEY="sk-or-..."
quipu serve-stdio --answer-provider openrouter --answer-model anthropic/claude-3.5-sonnet
```

## Configuration Precedence

Quipu resolves provider settings in this order:

1. CLI flags: `--llm-provider`, `--llm-model`, `--llm-base-url`, `--llm-api-key`, `--llm-temperature`, `--llm-max-tokens`.
2. Specific CLI flags: `--answer-provider`, `--answer-model`, `--answer-url`, `--entity-provider`, `--entity-model`, `--entity-url`.
3. Environment variables: `QUIPU_LLM_PROVIDER`, `QUIPU_LLM_MODEL`, `QUIPU_LLM_BASE_URL`, `QUIPU_LLM_API_KEY`, plus provider-specific keys.
4. Config file: `./quipu.yaml`, then `~/.quipu/config.yaml`, or an explicit `--config PATH`.
5. Defaults: an API-key provider auto-detected from the environment, Ollama if localhost is available, otherwise deterministic.

## Config File

```yaml
llm:
  provider: openai
  model: gpt-4o
  api_key: "${OPENAI_API_KEY}"
  temperature: 0.1
  max_tokens: 4096

embedding:
  provider: openrouter
  model: openai/text-embedding-3-small

providers:
  primary:
    provider: anthropic
    model: claude-sonnet-4-20250514
```

The current core parser supports the `llm`, `embedding`, and `providers.primary` sections shown above.

## Supported Providers

| Provider | CLI ID | API key env | Wire format | Default model |
| --- | --- | --- | --- | --- |
| OpenAI | `openai` | `OPENAI_API_KEY` | OpenAI-compatible | `gpt-4o` |
| Anthropic | `anthropic` | `ANTHROPIC_API_KEY` | Anthropic Messages | `claude-sonnet-4-20250514` |
| Google Gemini | `google`, `gemini` | `GOOGLE_API_KEY` | Gemini generateContent | `gemini-2.0-flash` |
| OpenRouter | `openrouter` | `OPENROUTER_API_KEY` | OpenAI-compatible | `openai/gpt-4o` |
| Azure OpenAI | `azure` | `AZURE_OPENAI_API_KEY` | OpenAI-compatible with `api-key` header | configure deployment URL |
| Groq | `groq` | `GROQ_API_KEY` | OpenAI-compatible | `llama-3.3-70b-versatile` |
| Ollama | `ollama` | none | OpenAI-compatible local endpoint | `llama3.3` |
| Together AI | `together` | `TOGETHER_API_KEY` | OpenAI-compatible | `meta-llama/Llama-3.3-70B-Instruct-Turbo` |
| Mistral AI | `mistral` | `MISTRAL_API_KEY` | OpenAI-compatible | `mistral-large-latest` |
| DeepSeek | `deepseek` | `DEEPSEEK_API_KEY` | OpenAI-compatible | `deepseek-chat` |
| Moonshot/Kimi | `kimi`, `moonshot` | `MOONSHOT_API_KEY` | OpenAI-compatible | `kimi-latest` |
| Cohere | `cohere` | `COHERE_API_KEY` | Cohere Chat v2 | `command-a-03-2025` |
| Custom | `custom`, `openai-compatible` | `QUIPU_LLM_API_KEY` | OpenAI-compatible | configure model and base URL |

For OpenAI-compatible providers, `--llm-base-url` may point at a `/v1` base URL. Quipu appends `/chat/completions` when appropriate. Azure deployments should pass the full deployment URL including `api-version`.

## Connectivity Checks

Run a dry provider probe without writing memory:

```bash
quipu llm-check --llm-provider openai --llm-model gpt-4o
```

The response includes provider, model, URL, declared capabilities, and either a sample answer or a clear setup error.

## Evals

The eval harness exposes the same provider IDs for answer and judge providers:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.runner \
  --answer-provider anthropic \
  --answer-model claude-sonnet-4-20250514 \
  --judge-provider openai \
  --judge-model gpt-4o
```

OpenRouter embedding caches remain supported:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.runner \
  --embedding-provider openrouter \
  --embedding-cache artifacts/provider-cache/openrouter-embeddings.jsonl
```

## Troubleshooting

Missing API key errors name the exact environment variable to set. For example, `provider 'anthropic' is missing an API key; set ANTHROPIC_API_KEY or QUIPU_LLM_API_KEY`.

If a model is not found, check the provider dashboard for the exact model ID and pass it with `--llm-model` or `QUIPU_LLM_MODEL`.

If a local Ollama model fails, verify Ollama is running and the model is pulled:

```bash
ollama list
ollama pull llama3.3
```

If a provider times out or rate limits, use OpenRouter as a universal fallback or switch to a local Ollama model for offline development.
