# Quipu

Evidence-backed temporal memory for long-horizon AI agents.

Quipu is a local-first memory daemon built on top of LatticeDB. It stores raw interaction history, compiles it into episodic/semantic/procedural memory, retrieves compact evidence-backed context packets, and supports temporal updates and selective forgetting.

> Status: pre-implementation skeleton. See [SPEC.md](./SPEC.md).

## Intended architecture

- Native Zig daemon and CLI.
- LatticeDB as graph/vector/full-text/event substrate.
- Thin TypeScript and Python SDKs.
- Optional MCP adapter.
- Python eval harness.

## Development toolchain

Target contributors should have Zig, Python 3.10 or newer, Node.js, npm, and `just`. Until every toolchain is installed locally, `python3 scripts/run_tests.py` skips unavailable optional checks and CI runs the checks with Python and Node configured.

## Target quickstart

```bash
quipu init
quipu serve
quipu remember --text "For this repo, use pnpm, not npm."
quipu retrieve --query "What should I know before editing this repo?"
```

## License

MIT.
