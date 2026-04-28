import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { createCoreTransport, createMcpServer } from "../src/server.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "../..");
const coreDir = path.join(root, "core");
const coreBinary = path.join(coreDir, "zig-out", "bin", "quipu");

test("initialize advertises tools capability", async () => {
  const server = createMcpServer(async () => {
    throw new Error("transport should not be called");
  });

  const response = await server.handleMessage({
    jsonrpc: "2.0",
    id: "init",
    method: "initialize",
    params: {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "test", version: "0.0.0" },
    },
  });

  assert.equal(response.jsonrpc, "2.0");
  assert.equal(response.id, "init");
  assert.equal(response.result.serverInfo.name, "quipu-mcp");
  assert.deepEqual(response.result.capabilities.tools, {});
});

test("tools/list exposes Quipu protocol tools", async () => {
  const server = createMcpServer(async () => {
    throw new Error("transport should not be called");
  });

  const response = await server.handleMessage({
    jsonrpc: "2.0",
    id: "tools",
    method: "tools/list",
    params: {},
  });
  const names = response.result.tools.map((tool) => tool.name);

  assert.ok(names.includes("quipu_remember"));
  assert.ok(names.includes("quipu_retrieve"));
  assert.ok(names.includes("quipu_forget"));
  assert.ok(names.includes("quipu_core_update"));
});

test("tools/call delegates retrieve arguments to Quipu JSON-RPC", async () => {
  const calls = [];
  const server = createMcpServer(async (request) => {
    calls.push(request);
    return {
      jsonrpc: "2.0",
      id: request.id,
      result: {
        ok: true,
        method: request.method,
        params: request.params,
      },
    };
  });

  const response = await server.handleMessage({
    jsonrpc: "2.0",
    id: "call",
    method: "tools/call",
    params: {
      name: "quipu_retrieve",
      arguments: {
        query: "What package manager should I use?",
        scope: { projectId: "repo:test" },
        needs: ["current_facts"],
      },
    },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, "memory.retrieve");
  assert.deepEqual(calls[0].params.scope, { projectId: "repo:test" });
  assert.equal(response.result.structuredContent.method, "memory.retrieve");
  assert.equal(JSON.parse(response.result.content[0].text).params.query, "What package manager should I use?");
});

test("tools/call reports Quipu RPC errors as tool errors", async () => {
  const server = createMcpServer(async (request) => ({
    jsonrpc: "2.0",
    id: request.id,
    error: {
      code: "invalid_request",
      message: "bad retrieve request",
      details: { field: "query" },
    },
  }));

  const response = await server.handleMessage({
    jsonrpc: "2.0",
    id: "bad",
    method: "tools/call",
    params: {
      name: "quipu_retrieve",
      arguments: { scope: { projectId: "repo:test" } },
    },
  });

  assert.equal(response.result.isError, true);
  assert.equal(response.result.structuredContent.code, "invalid_request");
  assert.equal(response.result.structuredContent.details.field, "query");
});

test("unknown tool returns a JSON-RPC invalid params error", async () => {
  const server = createMcpServer(async () => {
    throw new Error("transport should not be called");
  });

  const response = await server.handleMessage({
    jsonrpc: "2.0",
    id: "missing",
    method: "tools/call",
    params: {
      name: "quipu_missing",
      arguments: {},
    },
  });

  assert.equal(response.error.code, -32602);
  assert.match(response.error.message, /unknown Quipu tool/);
});

const hasZig = spawnSync("zig", ["version"], { stdio: "ignore" }).status === 0;

test("tools/call can reach the Quipu core stdio process", { skip: !hasZig }, async () => {
  const build = spawnSync("zig", ["build"], {
    cwd: coreDir,
    env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: "/tmp/quipu-zig-cache" },
    stdio: "inherit",
  });
  assert.equal(build.status, 0);

  const transport = createCoreTransport({ binary: coreBinary });
  const server = createMcpServer((request) => transport.send(request));
  try {
    const response = await server.handleMessage({
      jsonrpc: "2.0",
      id: "health",
      method: "tools/call",
      params: {
        name: "quipu_health",
        arguments: {},
      },
    });

    assert.equal(response.result.structuredContent.status, "ok");
    assert.equal(response.result.structuredContent.protocolVersion, "2026-04-quipu-v1");
  } finally {
    transport.close();
  }
});
