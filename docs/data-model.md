# Data Model

See [../SPEC.md](../SPEC.md) for the full design.

## Derived Memory

The core writes raw, episodic, card, and derived labels.

Raw labels:

- `Message`: user/assistant/tool text from `memory.remember`.
- `ToolCall`: optional tool invocation records supplied in `toolCalls`.
- `Observation`: optional tool or environment observations supplied in
  `observations`.

Episodic/card labels:

- `Episode`: deterministic conversation episode for extracted turns.
- `MemoryCard`: atomic retrieval note linked to raw message evidence.

Derived labels:

- `Fact`: scoped semantic fact, such as `project.package_manager`.
- `Preference`: scoped user preference, such as `user.response_style`.
- `Procedure`: scoped workflow rule, such as `project.test_command`.

Each active derived node stores `slotKey`, `value`, `text`, `state`, `validFrom`, `validTo`, `evidenceQid`, `quote`, scope fields, and `deleted`. A new current node for the same scoped `slotKey` supersedes the previous current node by setting its `state` to `superseded` and its `validTo` to the new evidence timestamp.
