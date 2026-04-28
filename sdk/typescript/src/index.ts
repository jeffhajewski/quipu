export type QuipuScope = {
  tenantId?: string | null;
  userId?: string | null;
  agentId?: string | null;
  projectId?: string | null;
};

export type RememberRequest = {
  sessionId?: string;
  scope?: QuipuScope;
  messages: Array<{ role: string; content: string; createdAt?: string }>;
  extract?: boolean;
};

export type RetrieveRequest = {
  query: string;
  scope?: QuipuScope;
  budgetTokens?: number;
  needs?: string[];
};

export class Quipu {
  static async local(): Promise<Quipu> {
    return new Quipu();
  }

  async remember(_request: RememberRequest): Promise<unknown> {
    throw new Error("TODO: connect to Quipu daemon");
  }

  async retrieve(_request: RetrieveRequest): Promise<unknown> {
    throw new Error("TODO: connect to Quipu daemon");
  }
}
