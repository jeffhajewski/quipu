#!/usr/bin/env node
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const MCP_PROTOCOL_VERSION = "2024-11-05";
const SERVER_INFO = { name: "quipu-mcp", version: "0.1.0" };

const TOOL_DEFINITIONS = [
  {
    name: "quipu_health",
    method: "system.health",
    description: "Return Quipu runtime health and capability metadata.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false,
    },
  },
  {
    name: "quipu_remember",
    method: "memory.remember",
    description: "Store raw conversation messages and optionally extract derived memories.",
    inputSchema: {
      type: "object",
      properties: {
        sessionId: { type: "string" },
        scope: { $ref: "#/$defs/scope" },
        messages: {
          type: "array",
          minItems: 1,
          items: {
            type: "object",
            properties: {
              role: { type: "string" },
              content: { type: "string" },
              createdAt: { type: "string" },
            },
            required: ["role", "content"],
            additionalProperties: true,
          },
        },
        extract: { type: "boolean" },
        idempotencyKey: { type: "string" },
      },
      required: ["messages"],
      additionalProperties: true,
      $defs: sharedDefs(),
    },
  },
  {
    name: "quipu_retrieve",
    method: "memory.retrieve",
    description: "Retrieve a scoped context packet and rendered prompt for an agent query.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string" },
        task: { type: "string" },
        scope: { $ref: "#/$defs/scope" },
        budgetTokens: { type: "integer", minimum: 0 },
        needs: {
          type: "array",
          items: { type: "string" },
        },
        time: { type: "object", additionalProperties: true },
        options: { type: "object", additionalProperties: true },
      },
      required: ["query"],
      additionalProperties: true,
      $defs: sharedDefs(),
    },
  },
  {
    name: "quipu_search",
    method: "memory.search",
    description: "Search stored memory items with Quipu's current search adapter.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string" },
        scope: { $ref: "#/$defs/scope" },
        limit: { type: "integer", minimum: 1 },
        labels: {
          type: "array",
          items: { type: "string" },
        },
      },
      required: ["query"],
      additionalProperties: true,
      $defs: sharedDefs(),
    },
  },
  {
    name: "quipu_inspect",
    method: "memory.inspect",
    description: "Inspect one memory item, optionally including provenance and dependents.",
    inputSchema: {
      type: "object",
      properties: {
        qid: { type: "string" },
        includeProvenance: { type: "boolean" },
        includeDependents: { type: "boolean" },
      },
      required: ["qid"],
      additionalProperties: false,
    },
  },
  {
    name: "quipu_forget",
    method: "memory.forget",
    description: "Dry-run or apply forgetting for selected Quipu memory roots.",
    inputSchema: {
      type: "object",
      properties: {
        selector: { type: "object", additionalProperties: true },
        mode: { type: "string" },
        dryRun: { type: "boolean" },
        reason: { type: "string" },
      },
      required: ["selector"],
      additionalProperties: true,
    },
  },
  {
    name: "quipu_feedback",
    method: "memory.feedback",
    description: "Store retrieval feedback for future utility and policy updates.",
    inputSchema: {
      type: "object",
      properties: {
        retrievalId: { type: "string" },
        rating: { type: "string" },
        usedItemQids: {
          type: "array",
          items: { type: "string" },
        },
        ignoredItemQids: {
          type: "array",
          items: { type: "string" },
        },
        corrections: {
          type: "array",
          items: { type: "object", additionalProperties: true },
        },
        metadata: { type: "object", additionalProperties: true },
      },
      required: ["retrievalId", "rating"],
      additionalProperties: true,
    },
  },
  {
    name: "quipu_core_get",
    method: "memory.core.get",
    description: "Read scoped Quipu core memory blocks.",
    inputSchema: {
      type: "object",
      properties: {
        scope: { $ref: "#/$defs/scope" },
        blockKey: { type: "string" },
      },
      additionalProperties: false,
      $defs: sharedDefs(),
    },
  },
  {
    name: "quipu_core_update",
    method: "memory.core.update",
    description: "Create, append, or replace a scoped Quipu core memory block.",
    inputSchema: {
      type: "object",
      properties: {
        blockKey: { type: "string" },
        scope: { $ref: "#/$defs/scope" },
        text: { type: "string" },
        mode: { type: "string" },
        evidenceQids: {
          type: "array",
          items: { type: "string" },
        },
        managedBy: { type: "string" },
      },
      required: ["blockKey", "text"],
      additionalProperties: true,
      $defs: sharedDefs(),
    },
  },
];

const TOOL_BY_NAME = new Map(TOOL_DEFINITIONS.map((tool) => [tool.name, tool]));

function sharedDefs() {
  return {
    scope: {
      type: "object",
      properties: {
        tenantId: { type: "string" },
        userId: { type: "string" },
        agentId: { type: "string" },
        projectId: { type: "string" },
      },
      additionalProperties: false,
    },
  };
}

export function createMcpServer(quipuTransport) {
  let nextQuipuId = 1;

  async function callQuipu(method, params) {
    const response = await quipuTransport({
      jsonrpc: "2.0",
      id: `mcp_${nextQuipuId++}`,
      method,
      params,
    });
    if (response.error) {
      throw new QuipuToolError(response.error.message, response.error.code, response.error.details);
    }
    return response.result ?? {};
  }

  return {
    async handleMessage(message) {
      if (!message || typeof message !== "object" || Array.isArray(message)) {
        return errorResponse(null, -32600, "invalid JSON-RPC request");
      }

      const id = Object.hasOwn(message, "id") ? message.id : undefined;
      if (message.jsonrpc !== "2.0" || typeof message.method !== "string") {
        return id === undefined ? null : errorResponse(id, -32600, "invalid JSON-RPC request");
      }
      if (id === undefined) {
        return null;
      }

      try {
        const result = await handleMethod(message.method, message.params ?? {}, callQuipu);
        return { jsonrpc: "2.0", id, result };
      } catch (error) {
        if (error instanceof McpRequestError) {
          return errorResponse(id, error.code, error.message, error.data);
        }
        if (error instanceof QuipuToolError) {
          return {
            jsonrpc: "2.0",
            id,
            result: toolErrorResult(error),
          };
        }
        return errorResponse(id, -32603, error instanceof Error ? error.message : "internal error");
      }
    },
  };
}

async function handleMethod(method, params, callQuipu) {
  switch (method) {
    case "initialize":
      return {
        protocolVersion: MCP_PROTOCOL_VERSION,
        capabilities: {
          tools: {},
          resources: {},
          prompts: {},
        },
        serverInfo: SERVER_INFO,
      };
    case "ping":
      return {};
    case "tools/list":
      return {
        tools: TOOL_DEFINITIONS.map((tool) => ({
          name: tool.name,
          description: tool.description,
          inputSchema: tool.inputSchema,
        })),
      };
    case "tools/call":
      return callTool(params, callQuipu);
    case "resources/list":
      return { resources: [] };
    case "prompts/list":
      return { prompts: [] };
    default:
      throw new McpRequestError(-32601, `unknown MCP method: ${method}`);
  }
}

async function callTool(params, callQuipu) {
  if (!params || typeof params !== "object" || Array.isArray(params)) {
    throw new McpRequestError(-32602, "tools/call params must be an object");
  }
  const { name, arguments: args = {} } = params;
  if (typeof name !== "string") {
    throw new McpRequestError(-32602, "tools/call name must be a string");
  }
  if (!args || typeof args !== "object" || Array.isArray(args)) {
    throw new McpRequestError(-32602, "tools/call arguments must be an object");
  }
  const tool = TOOL_BY_NAME.get(name);
  if (!tool) {
    throw new McpRequestError(-32602, `unknown Quipu tool: ${name}`);
  }

  const result = await callQuipu(tool.method, args);
  return toolResult(result);
}

function toolResult(result) {
  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(result, null, 2),
      },
    ],
    structuredContent: result,
  };
}

function toolErrorResult(error) {
  const payload = {
    code: error.code,
    message: error.message,
    details: error.details ?? {},
  };
  return {
    isError: true,
    content: [
      {
        type: "text",
        text: JSON.stringify(payload, null, 2),
      },
    ],
    structuredContent: payload,
  };
}

function errorResponse(id, code, message, data) {
  const error = { code, message };
  if (data !== undefined) error.data = data;
  return { jsonrpc: "2.0", id, error };
}

export function createCoreTransport(options = {}) {
  const binary = options.binary ?? defaultCoreBinary();
  const args = options.args ?? ["serve-stdio"];
  const child = spawn(binary, args, {
    stdio: ["pipe", "pipe", "pipe"],
  });
  const pending = new Map();

  child.on("exit", (code, signal) => {
    const message = `Quipu core exited with code ${code ?? "null"} signal ${signal ?? "null"}`;
    for (const { reject } of pending.values()) {
      reject(new Error(message));
    }
    pending.clear();
  });

  child.stderr.setEncoding("utf8");
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });

  const lines = createInterface({ input: child.stdout });
  lines.on("line", (line) => {
    let response;
    try {
      response = JSON.parse(line);
    } catch (error) {
      rejectAll(`invalid JSON from Quipu core: ${error.message}`);
      return;
    }
    const request = pending.get(response.id);
    if (!request) return;
    pending.delete(response.id);
    request.resolve(response);
  });

  function rejectAll(message) {
    for (const { reject } of pending.values()) {
      reject(new Error(message));
    }
    pending.clear();
  }

  return {
    async send(request) {
      if (!child.stdin.writable) {
        throw new Error(stderr || "Quipu core stdin is closed");
      }
      return new Promise((resolvePromise, rejectPromise) => {
        pending.set(request.id, { resolve: resolvePromise, reject: rejectPromise });
        child.stdin.write(`${JSON.stringify(request)}\n`, (error) => {
          if (error) {
            pending.delete(request.id);
            rejectPromise(error);
          }
        });
      });
    },
    close() {
      child.stdin.end();
      child.kill();
    },
  };
}

export async function serveMcp({ input = process.stdin, output = process.stdout, transport } = {}) {
  const ownedTransport = transport ?? createCoreTransport();
  const quipuTransport = typeof ownedTransport === "function" ? ownedTransport : (request) => ownedTransport.send(request);
  const server = createMcpServer(quipuTransport);
  const lines = createInterface({ input });

  for await (const line of lines) {
    if (!line.trim()) continue;
    let message;
    try {
      message = JSON.parse(line);
    } catch (error) {
      output.write(`${JSON.stringify(errorResponse(null, -32700, error.message))}\n`);
      continue;
    }
    const response = await server.handleMessage(message);
    if (response) {
      output.write(`${JSON.stringify(response)}\n`);
    }
  }

  if (ownedTransport && typeof ownedTransport.close === "function") {
    ownedTransport.close();
  }
}

function defaultCoreBinary() {
  if (process.env.QUIPU_CORE_BINARY) return process.env.QUIPU_CORE_BINARY;
  const here = dirname(fileURLToPath(import.meta.url));
  return resolve(here, "../../core/zig-out/bin/quipu");
}

class McpRequestError extends Error {
  constructor(code, message, data) {
    super(message);
    this.name = "McpRequestError";
    this.code = code;
    this.data = data;
  }
}

class QuipuToolError extends Error {
  constructor(message, code, details) {
    super(message);
    this.name = "QuipuToolError";
    this.code = code;
    this.details = details;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  serveMcp().catch((error) => {
    process.stderr.write(`${error.stack ?? error.message}\n`);
    process.exitCode = 1;
  });
}
