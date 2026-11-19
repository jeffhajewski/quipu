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
- `Assertion`: one claim a person stated, written by LLM fact extraction.
- `Update`: the record that a later claim replaced an earlier one, written by
  consolidation.
- `Summary`: a title and summary of one conversation (`summaryType:
  "session"`) or of one group of claims about the same subject
  (`summaryType: "topic"`), written by the summary job (see
  [algorithms.md](algorithms.md#summary-nodes)). It stores `title`,
  `summary`, `text`, a vector of the text, `firstSaid` and `lastSaid`, and a
  key of the sources it was written from. A session summary has a
  `SUMMARIZES` edge to its session; a topic summary lists its claims in
  `members` and has a `DERIVED_FROM` edge to each. Both have an
  `EVIDENCED_BY` edge to every message they rest on. Not indexed for search:
  `memory.retrieve` and `memory.answer` compare every current summary of the
  scope with the question, and a topic shown is returned as an item of type
  `summary` in `context.threads`.
- `SentenceIndex`: the byte range and embedding of each sentence of one
  message, without the text, and the embedding model that made the vectors.
  Internal; never returned as an item.
- `Pattern`: what the memory worked out from one kind of occasion that recurs
  (see [algorithms.md](algorithms.md#pattern-nodes)). It stores the occasions
  with their messages and linked sentences, the proposed generalisations with
  their two yes/no questions, the answer for every occasion, and the finding
  written from the counts. It has an `EVIDENCED_BY` edge to every message of
  every occasion.

Each active derived node stores `slotKey`, `value`, `text`, `state`, `validFrom`, `validTo`, `evidenceQid`, `quote`, scope fields, and `deleted`. A new current node for the same scoped `slotKey` supersedes the previous current node by setting its `state` to `superseded` and its `validTo` to the new evidence timestamp.
