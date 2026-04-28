import assert from "node:assert/strict";
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
