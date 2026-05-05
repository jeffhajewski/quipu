# Quipu Presets

Presets define product defaults for common agent domains without changing the
canonical JSON-RPC methods. SDKs and CLIs can load these files to choose scopes,
extraction slots, core block templates, retrieval needs, and forgetting policy.

## coding-agent

`coding-agent.json` is the first preset. It covers repository package manager,
test command, repo style, project constraints, and user response style. The core
runtime has deterministic extraction coverage for these slots so a first memory
round trip does not require a provider key.
