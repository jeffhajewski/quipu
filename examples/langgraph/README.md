# LangGraph Example

Minimal LangGraph memory loop using the Python SDK.

```bash
pip install quipu-memory langgraph
quipu quickstart
python examples/langgraph/agent.py
```

The example retrieves Quipu context before the graph answers, then stores the
user and assistant turn after completion. Quipu remains the canonical memory
writer; LangGraph only receives a context string.
