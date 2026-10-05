# ADR-0009: AI explains, after the verdict, behind a provider seam

**Status:** Accepted
**Date:** 2026-09-11

## Context

The governing principle is that the deterministic engine decides and AI
explains. Phase 8 is where that stops being a slogan and has to become
a property of the code. The plan named Claude; the provider chosen for
this build is Groq, and the requirement is that it be changeable later
without a rewrite.

## Decision

### The provider is a configuration value

`ai_client` knows nothing about testing. It sends a prompt and returns
text. One `OpenAiCompatibleClient` covers Groq, OpenAI, OpenRouter,
Together, Fireworks, DeepSeek, xAI, Ollama and LM Studio, because they
all accept `POST {baseUrl}/chat/completions` with the same body -
differing only in endpoint, key and model name, which is exactly what
`LlmConfig` holds. Moving from Groq to a local Ollama is two lines of
`ai.yaml`:

```yaml
provider: ollama
model: llama3
```

Anthropic and Gemini use a different wire shape. They are declared as a
dialect and **rejected with an explanation** rather than sent a body
they cannot parse and then blamed for the failure. Adding one means
writing a second `LlmClient`, not changing anything that calls it.

### The key never enters a configuration file

`ai.yaml` carries `apiKeyEnv` - the *name* of an environment variable.
Writing `apiKey:` is a parse error whose message says why, checked
before the unknown-key rule so the reason is the one you get. Values
resolve from the real environment first and `.env` (gitignored) second,
so CI is never overridden by a stray local file.

### Analysis happens after the verdict, and cannot reach it

`RunResult.passed` is a function of the steps and the deterministic
reports. The analyst takes a finished `RunResult` and returns a **copy**
with an explanation attached. There is no code path from a model's
output to a verdict, because by the time the model is asked the verdict
is already computed and immutable. A test asserts that a model
insisting everything is fine leaves the run failed.

`ValidationResult` still has no confidence field, and a test asserts it
never gains one. Confidence exists only on `AiFinding`.

### Three claim levels, defaulting to the weakest

`confirmed_failure`, `probable_cause`, `hypothesis`. An unrecognised
value parses to `hypothesis` - defaulting the other way would let a
malformed reply promote a guess to a certainty, which is the one
failure mode the classification exists to prevent.

### A model outage is never a test failure

Every path returns an outcome: `AnalysisReady`, `AnalysisSkipped`
(nothing failed) or `AnalysisUnavailable` (no key, provider down,
unparseable reply). The three are rendered distinctly, for the same
reason validation separates skip from error.

### Only what is needed leaves the machine

Request and response **bodies and headers are never sent**. Redaction
already strips secrets at capture, but the cheaper guarantee is not to
send the payload at all. Endpoints, status codes, validator messages
and the expected/actual pair carry enough to reason about a cause. A
test asserts no header or body content appears in the prompt.

## Consequences

The prompt was tuned against real output, and both rules in it exist
because the model broke them.

**It labelled a guess as confirmed.** Asked to classify findings, it
produced `confirmed_failure` for *"indicating a visual regression,
likely due to layout, styling, or rendering changes"* - an unproven
cause under the word "confirmed", and wrong besides. The fix is a
mechanical test the model can apply to its own sentence: if the
explanation contains "because", "due to", "suggests" or "indicates", it
is not `confirmed_failure`.

**Then it explained nothing.** With that rule alone it retreated to
restating measurements, which is honest and useless. So it is now asked
to add the cause as a *separate* finding, classified `probable_cause`
or `hypothesis`.

The result on the seeded price regression, unedited:

```
[confirmed_failure] api-to-ui product.price          conf 1.00
  The API returned price 90 (displayed as "Rs 90" for INR) but the UI
  rendered "Rs -,310" for product.price.

[probable_cause]    api-to-ui product.price          conf 0.92
  The mismatch is likely caused by an incorrect formatting or
  data-binding implementation ... because the UI shows a completely
  different number rather than a simple rounding error.

[probable_cause]    visual                           conf 0.88
  The visual deviation is likely caused by the same price rendering
  error identified in the api-to-ui failure.
```

The fact and the cause are separate findings, the causal language is
hedged, and the model correctly connected two independent validators to
one root cause - which is the thing a deterministic engine cannot do
and the reason this layer exists at all.

Cost on that run: 704 prompt + 526 completion tokens, 1.7s.
