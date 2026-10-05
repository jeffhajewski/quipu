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
