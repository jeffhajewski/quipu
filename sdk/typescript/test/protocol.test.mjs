import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  Quipu,
  QuipuProtocolError,
  SUPPORTED_METHODS,
  validateJsonRpcRequest,
  validateJsonRpcResponse,
  validateRpcParams,
} from "../dist/index.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "../../..");
const fixtureDir = path.join(root, "protocol", "conformance");
const coreDir = path.join(root, "core");
const coreBinary = path.join(coreDir, "zig-out", "bin", "quipu");
const zigEnv = {
  ...process.env,
  ZIG_GLOBAL_CACHE_DIR: "/tmp/quipu-zig-cache",
  ZIG_LOCAL_CACHE_DIR: "/tmp/quipu-zig-local-cache",
};
let coreBuildChecked = false;

function ensureCoreBuilt() {
  if (coreBuildChecked) return;
  const build = spawnSync("zig", ["build"], {
    cwd: coreDir,
    env: zigEnv,
    encoding: "utf8",
  });
  if (build.status !== 0) {
    process.stderr.write(build.stdout ?? "");
    process.stderr.write(build.stderr ?? "");
  }
  assert.equal(build.status, 0);
  coreBuildChecked = true;
}

function tempDbPath(name) {
  const dir = mkdtempSync(path.join(tmpdir(), "quipu-sdk-ts-"));
  return {
    dbPath: path.join(dir, `${name}.lattice`),
    cleanup: () => rmSync(dir, { recursive: true, force: true }),
  };
}

function loadFixtures() {
  return readdirSync(fixtureDir)
    .filter((name) => name.endsWith(".json"))
    .sort()
    .map((name) => JSON.parse(readFileSync(path.join(fixtureDir, name), "utf8")));
}

test("conformance fixtures cover public methods", () => {
  const successMethods = new Set(
    loadFixtures()
      .filter((fixture) => "result" in fixture.response)
      .map((fixture) => fixture.request.method),
  );
  assert.deepEqual(successMethods, new Set(SUPPORTED_METHODS));
});

test("success conformance fixtures validate", () => {
  for (const fixture of loadFixtures()) {
    validateJsonRpcResponse(fixture.response);
    if ("result" in fixture.response) {
      validateJsonRpcRequest(fixture.request);
      validateRpcParams(fixture.request.method, fixture.request.params);
    }
  }
});

test("memory.answer fixture includes optional answerTrace and debug prompt", () => {
  const fixture = JSON.parse(readFileSync(path.join(fixtureDir, "memory.answer.success.json"), "utf8"));
  assert.equal(fixture.response.result.answerTrace.strategy, "deterministic_fallback");
  assert.equal(fixture.response.result.answerTrace.supportValid, true);
  assert.equal(fixture.response.result.answerTrace.validation.status, "accepted");
  assert.equal(fixture.request.params.options.includeDebug, true);
  assert.equal(typeof fixture.response.result.prompt, "string");
  assert.ok(fixture.response.result.prompt.startsWith("<memory>"));
});

test("memory.answer reader options fixture reports reasoning and temporal hints", () => {
  const fixture = JSON.parse(readFileSync(path.join(fixtureDir, "memory.answer.reader_options.json"), "utf8"));
  const trace = fixture.response.result.answerTrace;
  assert.equal(fixture.request.params.options.readerReasoning, true);
  assert.equal(fixture.request.params.options.temporalHints, true);
  assert.equal(trace.readerMode, "reasoning");
  assert.equal(trace.temporalHints, true);
  assert.equal(trace.timeReferences, '"last week" = 2023-05-22 to 2023-05-28');
  assert.equal(typeof trace.reasoning, "string");
  assert.ok(fixture.response.result.prompt.includes("## session s-late 2023-05-22 (Mon), 8 days ago"));

  const defaults = JSON.parse(readFileSync(path.join(fixtureDir, "memory.answer.success.json"), "utf8"));
  assert.equal(defaults.response.result.answerTrace.readerMode, "none");
  assert.equal(defaults.response.result.answerTrace.temporalHints, false);
  assert.equal(defaults.response.result.answerTrace.reasoning, null);
});

test("reader options are validated per method", () => {
  validateRpcParams("memory.answer", { query: "q", options: { readerReasoning: true, temporalHints: false } });
  validateRpcParams("memory.retrieve", { query: "q", options: { temporalHints: true } });
  assert.throws(() => validateRpcParams("memory.answer", { query: "q", options: { readerReasoning: "yes" } }), QuipuProtocolError);
  assert.throws(() => validateRpcParams("memory.retrieve", { query: "q", options: { readerReasoning: true } }), QuipuProtocolError);
});

test("factKeys is a retrieve and answer option with its own trace", () => {
  const schema = JSON.parse(readFileSync(path.join(root, "protocol", "schemas", "methods.schema.json"), "utf8"));
  for (const def of ["memoryRetrieveParams", "memoryAnswerParams"]) {
    assert.equal(schema.$defs[def].properties.options.properties.factKeys.type, "boolean");
  }
  assert.ok(schema.$defs.retrievalTrace.properties.factKeys);
  assert.ok(schema.$defs.memoryItem.properties.type.enum.includes("assertion"));
  assert.ok(schema.$defs.systemHealthResult.properties.capabilities.properties.extractor);

  for (const method of ["memory.retrieve", "memory.answer"]) {
    validateRpcParams(method, { query: "q", options: { factKeys: true } });
    assert.throws(() => validateRpcParams(method, { query: "q", options: { factKeys: "yes" } }), QuipuProtocolError);
  }

  const fixture = JSON.parse(readFileSync(path.join(fixtureDir, "memory.retrieve.fact_keys.json"), "utf8"));
  assert.equal(fixture.request.params.options.factKeys, true);
  assert.ok(fixture.response.result.prompt.includes("[event 2023-03-03]"));
  assert.deepEqual(fixture.response.result.items.map((item) => item.type), ["message"]);
  assert.equal(fixture.response.result.trace.factKeys.assertionHits, 1);
});

test("facts is a retrieve and answer option that lists dated current and superseded facts", () => {
  const schema = JSON.parse(readFileSync(path.join(root, "protocol", "schemas", "methods.schema.json"), "utf8"));
  for (const def of ["memoryRetrieveParams", "memoryAnswerParams"]) {
    assert.equal(schema.$defs[def].properties.options.properties.facts.type, "boolean");
  }
  assert.equal(schema.$defs.systemHealthResult.properties.capabilities.properties.facts.type, "boolean");

  for (const method of ["memory.retrieve", "memory.answer"]) {
    validateRpcParams(method, { query: "q", options: { facts: true } });
    assert.throws(() => validateRpcParams(method, { query: "q", options: { facts: "yes" } }), QuipuProtocolError);
  }

  const fixture = JSON.parse(readFileSync(path.join(fixtureDir, "memory.retrieve.facts.json"), "utf8"));
  assert.equal(fixture.request.params.options.facts, true);
  const result = fixture.response.result;
  assert.ok(result.prompt.includes("(superseded, 2023-05-25 to 2023-06-10) The user has 1250 followers"));
  assert.ok(result.prompt.includes("(current, from 2023-06-10) The user is close to 1300 followers"));
  assert.deepEqual(result.context.currentFacts.map((fact) => [fact.type, fact.state]), [["fact", "superseded"], ["fact", "current"]]);
  assert.equal(result.context.currentFacts[0].validTo, result.context.currentFacts[1].validFrom);
  assert.equal(result.trace.facts.superseded, 1);
});

test("a time the question names is resolved for the reader, with no option", () => {
  const schema = JSON.parse(readFileSync(path.join(root, "protocol", "schemas", "methods.schema.json"), "utf8"));
  for (const def of ["memoryRetrieveParams", "memoryAnswerParams"]) {
    assert.equal(schema.$defs[def].properties.options.properties.timeAnchors, undefined);
  }
  assert.equal(schema.$defs.systemHealthResult.properties.capabilities.properties.timeAnchors.type, "boolean");

  for (const method of ["memory.retrieve", "memory.answer"]) {
    assert.throws(() => validateRpcParams(method, { query: "q", options: { timeAnchors: true } }), QuipuProtocolError);
  }

  const fixture = JSON.parse(readFileSync(path.join(fixtureDir, "memory.retrieve.timeAnchors.json"), "utf8"));
  assert.equal(fixture.request.params.options.timeAnchors, undefined);
  const result = fixture.response.result;
  assert.ok(result.prompt.includes('Time references: "10 days ago" = 2023-03-15 (Wed)\n'));
  assert.ok(result.prompt.includes('## session s-smoker 2023-03-15 (Wed): this is the question\'s "10 days ago"\n'));
  assert.ok(result.prompt.includes("Just got a smoker today"));
  assert.deepEqual(result.trace.timeAnchors, { windows: 1, items: 1, tokens: 31 });
});

test("pattern nodes are part of every retrieve and answer context, with no option", () => {
  const schema = JSON.parse(readFileSync(path.join(root, "protocol", "schemas", "methods.schema.json"), "utf8"));
  assert.ok(schema.$defs.memoryItem.properties.type.enum.includes("pattern"));
  for (const def of ["memoryRetrieveResult", "memoryAnswerResult"]) {
    assert.ok(schema.$defs[def].properties.context.required.includes("patterns"));
  }
  for (const def of ["memoryRetrieveParams", "memoryAnswerParams"]) {
    assert.equal(schema.$defs[def].properties.options.properties.patterns, undefined);
  }
  assert.deepEqual(schema.$defs.systemHealthResult.properties.capabilities.properties.patterns.required, ["available", "promptVersion", "model"]);

  const fixture = JSON.parse(readFileSync(path.join(fixtureDir, "memory.retrieve.patterns.json"), "utf8"));
  assert.equal(fixture.request.params.options.patterns, undefined);
  const result = fixture.response.result;
  assert.ok(result.prompt.includes("<patterns>\n[q_pat_"));
  assert.equal(result.context.patterns.length, 1);
  const pattern = result.context.patterns[0];
  assert.equal(pattern.type, "pattern");
  assert.ok(pattern.text.includes("Worked out by the memory from 8 occasions, never stated by the person"));
  // Every occasion the finding counts is evidence, quoted.
  assert.equal(pattern.evidence.length, 8);
  for (const evidence of pattern.evidence) {
    assert.ok(evidence.quote.includes("sourdough loaf"));
    assert.ok(result.items.some((item) => item.qid === evidence.qid));
  }
  assert.deepEqual(result.trace.patterns, { candidates: 1, sentences: 26, ownedMost: 10, kept: 1, tokens: 75 });

  const plain = JSON.parse(readFileSync(path.join(fixtureDir, "memory.retrieve.success.json"), "utf8"));
  assert.deepEqual(plain.response.result.context.patterns, []);
  assert.equal(plain.response.result.trace.patterns, undefined);
});

test("summary nodes are read first by every retrieve and answer, with no option", () => {
  const schema = JSON.parse(readFileSync(path.join(root, "protocol", "schemas", "methods.schema.json"), "utf8"));
  for (const def of ["memoryRetrieveResult", "memoryAnswerResult"]) {
    assert.ok(schema.$defs[def].properties.context.required.includes("threads"));
  }
  for (const def of ["memoryRetrieveParams", "memoryAnswerParams"]) {
    assert.equal(schema.$defs[def].properties.options.properties.threads, undefined);
    assert.equal(schema.$defs[def].properties.options.properties.summaries, undefined);
  }

  const fixture = JSON.parse(readFileSync(path.join(fixtureDir, "memory.retrieve.threads.json"), "utf8"));
  assert.equal(fixture.request.params.options.threads, undefined);
  const result = fixture.response.result;
  // The threads come before the conversations they were built from.
  assert.ok(result.prompt.indexOf("<threads>\n") >= 0);
  assert.ok(result.prompt.indexOf("<threads>\n") < result.prompt.indexOf("<sessions>\n"));
  assert.ok(result.prompt.includes("\n## Sourdough starter Bubbles: The user keeps a starter named Bubbles and looks after it.\n"));
  assert.ok(result.prompt.includes("[q_msg_25] 2023-05-12 (Fri), 18 days ago: The user gave half of the sourdough starter named Bubbles away.\n"));
  // Each session opened is headed by its summary.
  assert.ok(result.prompt.includes("## session day-12 2023-05-12 (Fri) | Looking after Bubbles: The user talked about the sourdough starter Bubbles.\n"));

  assert.equal(result.context.threads.length, 1);
  const topic = result.context.threads[0];
  assert.equal(topic.type, "summary");
  // Every fact shown under the topic is evidence: its message, quoting the fact.
  assert.deepEqual(topic.evidence.map((evidence) => evidence.qid), ["q_msg_4", "q_msg_11", "q_msg_25"]);
  for (const evidence of topic.evidence) {
    assert.ok(evidence.quote.includes("Bubbles"));
    assert.ok(result.items.some((item) => item.qid === evidence.qid));
  }
  assert.deepEqual(result.trace.threads, { topics: 1, sessions: 10, claims: 4, shown: 1, facts: 3, sessionsOpened: 6, rawDropped: 0, tokens: 189 });

  const plain = JSON.parse(readFileSync(path.join(fixtureDir, "memory.retrieve.success.json"), "utf8"));
  assert.deepEqual(plain.response.result.context.threads, []);
  assert.equal(plain.response.result.trace.threads, undefined);
  assert.ok(!plain.response.result.prompt.includes("<threads>"));
});

test("method schema accepts slot metadata, support validity, and answer prompt", () => {
  const schema = JSON.parse(readFileSync(path.join(root, "protocol", "schemas", "methods.schema.json"), "utf8"));
  assert.ok(schema.$defs.memoryItem.properties.slotKey);
  assert.ok(schema.$defs.answerTrace.properties.supportValid);
  assert.ok(schema.$defs.answerTrace.required.includes("supportValid"));
  assert.equal(schema.$defs.answerTrace.properties.evidenceGate, undefined);
  assert.deepEqual(schema.$defs.memoryAnswerResult.properties.prompt.type, ["string", "null"]);
  assert.deepEqual(schema.$defs.answerTrace.properties.readerMode.enum, ["none", "direct", "reasoning"]);
  assert.deepEqual(schema.$defs.answerTrace.properties.reasoning.type, ["string", "null"]);
  assert.equal(schema.$defs.answerTrace.required.includes("reasoning"), false);
  assert.equal(schema.$defs.memoryAnswerParams.properties.options.properties.readerReasoning.type, "boolean");
  assert.equal(schema.$defs.memoryRetrieveParams.properties.options.properties.temporalHints.type, "boolean");
});

test("rerank options are part of the retrieve and answer contract", () => {
  const schema = JSON.parse(readFileSync(path.join(root, "protocol", "schemas", "methods.schema.json"), "utf8"));
  for (const def of ["memoryRetrieveParams", "memoryAnswerParams"]) {
    const options = schema.$defs[def].properties.options.properties;
    assert.equal(options.rerank.type, "boolean");
    assert.equal(options.rerankCandidates.minimum, 1);
  }
  assert.ok(schema.$defs.retrievalTrace.properties.rerank);
  assert.ok(schema.$defs.systemHealthResult.properties.capabilities.properties.reranker);

  for (const method of ["memory.retrieve", "memory.answer"]) {
    validateRpcParams(method, { query: "q", options: { rerank: false, rerankCandidates: 20 } });
    for (const options of [{ rerank: "no" }, { rerankCandidates: 0 }, { rerankCandidates: 2.5 }, { rerankCandidates: "5" }]) {
      assert.throws(() => validateRpcParams(method, { query: "q", options }), QuipuProtocolError);
    }
  }
});

test("query expansion is part of the retrieve and answer contract", () => {
  const schema = JSON.parse(readFileSync(path.join(root, "protocol", "schemas", "methods.schema.json"), "utf8"));
  assert.deepEqual(schema.$defs.queryExpansionMode.enum, ["off", "rules", "llm"]);
  for (const def of ["memoryRetrieveParams", "memoryAnswerParams"]) {
    assert.deepEqual(schema.$defs[def].properties.options.properties.queryExpansion, { $ref: "#/$defs/queryExpansionMode" });
  }
  for (const def of ["retrievalTrace", "answerTrace"]) {
    assert.deepEqual(schema.$defs[def].properties.queryExpansion, { $ref: "#/$defs/queryExpansionTrace" });
    assert.equal((schema.$defs[def].required ?? []).includes("queryExpansion"), false);
  }
  assert.deepEqual(schema.$defs.queryExpansionTrace.properties.queries.items.properties.source.enum, ["original", "rules", "llm"]);
  assert.ok(schema.$defs.systemHealthResult.properties.capabilities.properties.queryExpansion);

  for (const method of ["memory.retrieve", "memory.answer"]) {
    for (const mode of ["off", "rules", "llm"]) {
      validateRpcParams(method, { query: "q", options: { queryExpansion: mode } });
    }
    for (const bad of ["LLM", "", null, true, ["rules"]]) {
      assert.throws(() => validateRpcParams(method, { query: "q", options: { queryExpansion: bad } }), QuipuProtocolError);
    }
  }
});

test("query expansion fixture reports the queries in both traces", () => {
  const fixture = JSON.parse(readFileSync(path.join(fixtureDir, "memory.answer.query_expansion.json"), "utf8"));
  const result = fixture.response.result;
  assert.equal(fixture.request.params.options.queryExpansion, "rules");
  const expansion = result.answerTrace.queryExpansion;
  assert.deepEqual(expansion, result.trace.queryExpansion);
  assert.equal(expansion.status, "expanded");
  assert.deepEqual(
    expansion.queries.map((query) => [query.query, query.source]),
    [
      [fixture.request.params.query, "original"],
      ["the necklace for my sister", "rules"],
      ["the photo album for my mom", "rules"],
    ],
  );
  const itemQids = new Set(result.items.map((item) => item.qid));
  for (const query of expansion.queries) {
    for (const qid of query.topQids) assert.ok(itemQids.has(qid));
  }

  const defaults = JSON.parse(readFileSync(path.join(fixtureDir, "memory.answer.success.json"), "utf8"));
  assert.equal("queryExpansion" in defaults.response.result.answerTrace, false);
  const health = JSON.parse(readFileSync(path.join(fixtureDir, "system.health.success.json"), "utf8"));
  assert.deepEqual(health.response.result.capabilities.queryExpansion.modes, ["off", "rules", "llm"]);
});

test("invalid request fixture is rejected", () => {
  const fixture = JSON.parse(readFileSync(path.join(fixtureDir, "memory.retrieve.invalid_request.json"), "utf8"));
  assert.throws(() => validateJsonRpcRequest(fixture.request), QuipuProtocolError);
  validateJsonRpcResponse(fixture.response);
});

test("client delegates valid requests to transport", async () => {
  const calls = [];
  const client = new Quipu((request) => {
    calls.push(request);
    return {
      jsonrpc: "2.0",
      id: request.id,
      result: {
        status: "ok",
        version: "0.1.0",
        protocolVersion: "2026-04-quipu-v1",
        schemaVersion: 1,
        workers: {},
      },
    };
  });

  const result = await client.health();

  assert.equal(result.status, "ok");
  assert.equal(calls[0].method, "system.health");
  validateJsonRpcRequest(calls[0]);
});

const hasZig = spawnSync("zig", ["version"], { stdio: "ignore" }).status === 0;

test("stdio client calls core process", { skip: !hasZig }, async () => {
  ensureCoreBuilt();

  const temp = tempDbPath("stdio");
  const client = Quipu.stdio([coreBinary, "--db", temp.dbPath, "serve-stdio"]);
  try {
    const remembered = await client.remember({
      scope: { projectId: "repo:test" },
      messages: [{ role: "user", content: "Use pnpm from TypeScript." }],
    });
    const retrieved = await client.retrieve({
      query: "pnpm",
      scope: { projectId: "repo:test" },
      needs: ["current_facts"],
      options: { includeDebug: true },
    });

    assert.equal(remembered.status, "stored");
    assert.match(String(retrieved.prompt), /The repo uses pnpm as its package manager/);
    assert.equal(Array.isArray(retrieved.context?.currentFacts), true);
    assert.equal(retrieved.trace?.keptCount, 1);
  } finally {
    client.close();
    temp.cleanup();
  }
});

test("local client auto-starts core stdio process", { skip: !hasZig }, async () => {
  ensureCoreBuilt();

  const temp = tempDbPath("local");
  const client = await Quipu.local({ binary: coreBinary, dbPath: temp.dbPath });
  try {
    const health = await client.health();
    assert.equal(health.status, "ok");
  } finally {
    client.close();
    temp.cleanup();
  }
});
