# Quipu Protocol

Quipu uses JSON-RPC 2.0 envelopes with method-specific `params` and `result` shapes. The schemas in `schemas/` define the public contract, and the fixtures in `conformance/` are golden examples shared by SDKs, the daemon, CLI, MCP adapter, and eval harness.

The daemon is the canonical implementation of memory behavior. SDKs should only validate the public protocol shape, submit JSON-RPC requests, and return typed results.
