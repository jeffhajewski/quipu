import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
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
  const build = spawnSync("zig", ["build"], {
    cwd: coreDir,
    env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: "/tmp/quipu-zig-cache" },
    stdio: "inherit",
  });
  assert.equal(build.status, 0);

  const client = Quipu.stdio([coreBinary, "serve-stdio"]);
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
  }
});

test("local client auto-starts core stdio process", { skip: !hasZig }, async () => {
  const build = spawnSync("zig", ["build"], {
    cwd: coreDir,
    env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: "/tmp/quipu-zig-cache" },
    stdio: "inherit",
  });
  assert.equal(build.status, 0);

  const client = await Quipu.local({ binary: coreBinary });
  try {
    const health = await client.health();
    assert.equal(health.status, "ok");
  } finally {
    client.close();
  }
});
