# Security Policy

Quipu stores sensitive user and project memory. Please report security issues privately until a disclosure process is established.

Security-sensitive areas:

- Cross-scope retrieval leaks.
- Prompt injection through stored memory.
- Secret leakage in logs, exports, debug traces, or eval artifacts.
- Incomplete forgetting/deletion propagation.
- MCP/CLI argument injection.
- Provider exfiltration of sensitive memory.
