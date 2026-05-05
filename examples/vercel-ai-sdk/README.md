# Vercel AI SDK Example

Minimal TypeScript integration that injects Quipu memory into an AI SDK
`generateText` call and writes the completed turn back to Quipu.

```bash
npm install @quipu/memory ai @ai-sdk/openai
quipu quickstart
npx tsx examples/vercel-ai-sdk/agent.ts
```

Set `OPENAI_API_KEY` for a real model call. Without a provider key, keep the
same Quipu calls and replace the `generateText` block with your local model.
