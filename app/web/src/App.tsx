import { FormEvent, useState } from "react";

import { AnswerResponse, RefusedError, ask } from "./api";

// Suggestions, not shortcuts. Each one demonstrates a different control, and
// the second and third are supposed to fail for most identities.
const EXAMPLES = [
  "What is the leave carry-over deadline?",
  "What is the Q3 revenue forecast?",
  "Summarise the customer records document.",
];

export function App() {
  // The token is component state and nothing else. Putting a bearer token in
  // localStorage would leave it behind on a shared machine after the demo.
  const [token, setToken] = useState("");
  const [question, setQuestion] = useState("");
  const [pending, setPending] = useState(false);
  const [answer, setAnswer] = useState<AnswerResponse | null>(null);
  const [refusal, setRefusal] = useState<string | null>(null);

  async function onSubmit(event: FormEvent) {
    event.preventDefault();
    if (!token.trim() || !question.trim() || pending) return;

    setPending(true);
    setAnswer(null);
    setRefusal(null);

    try {
      setAnswer(await ask(token.trim(), question.trim()));
    } catch (error) {
      setRefusal(
        error instanceof RefusedError
          ? `${error.status}: ${error.message}`
          : String(error),
      );
    } finally {
      setPending(false);
    }
  }

  return (
    <main>
      <h1>Internal assistant</h1>
      <p className="sub">
        Answers come only from the internal corpus. Retrieval is filtered by your
        group membership before it runs, and every response passes through a
        Bedrock guardrail on the way out.
      </p>

      <form onSubmit={onSubmit}>
        <label htmlFor="token">Identity token</label>
        <input
          id="token"
          value={token}
          onChange={(e) => setToken(e.target.value)}
          placeholder="paste the token minted for you"
          autoComplete="off"
          spellCheck={false}
        />

        <label htmlFor="question">Question</label>
        <textarea
          id="question"
          value={question}
          onChange={(e) => setQuestion(e.target.value)}
          placeholder="What is the leave carry-over deadline?"
        />

        <div className="examples">
          {EXAMPLES.map((example) => (
            <button
              key={example}
              type="button"
              className="example"
              onClick={() => setQuestion(example)}
            >
              {example}
            </button>
          ))}
        </div>

        <button type="submit" disabled={pending || !token.trim() || !question.trim()}>
          {pending ? "Asking…" : "Ask"}
        </button>
      </form>

      {refusal && (
        <section className="card">
          <h2>Refused</h2>
          <p className="error">{refusal}</p>
        </section>
      )}

      {answer && <Answer response={answer} />}
    </main>
  );
}

function Answer({ response }: { response: AnswerResponse }) {
  return (
    <section className="card">
      <h2>Answer</h2>
      <p className="answer">{response.answer}</p>

      <div className="meta">
        <span className={response.guardrail_intervened ? "badge blocked" : "badge clean"}>
          {response.guardrail_intervened ? "guardrail intervened" : "guardrail passed"}
        </span>

        <p>
          Asked as <code>{response.caller.subject}</code> in{" "}
          {response.caller.groups.map((group) => (
            <code key={group}>{group}</code>
          ))}
        </p>

        <p>
          Sources:{" "}
          {response.sources.length === 0 ? (
            <em>none retrieved — nothing in the corpus matched what you are entitled to see</em>
          ) : (
            response.sources.map((source) => <code key={source}>{source}</code>)
          )}
        </p>
      </div>
    </section>
  );
}
