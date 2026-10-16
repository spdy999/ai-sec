export interface Caller {
  subject: string;
  groups: string[];
}

export interface AnswerResponse {
  answer: string;
  guardrail_intervened: boolean;
  sources: string[];
  caller: Caller;
}

export class RefusedError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
    this.name = "RefusedError";
  }
}

export async function ask(token: string, question: string): Promise<AnswerResponse> {
  const response = await fetch("/ask", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({ question }),
  });

  const payload: unknown = await response.json().catch(() => ({}));

  if (!response.ok) {
    const detail =
      typeof payload === "object" && payload !== null && "detail" in payload
        ? String((payload as { detail: unknown }).detail)
        : "request refused";
    throw new RefusedError(response.status, detail);
  }

  return payload as AnswerResponse;
}
