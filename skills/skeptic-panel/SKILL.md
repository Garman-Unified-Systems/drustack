---
name: skeptic-panel
description: "Convene a 2-5 persona debate panel (Skeptic / Optimist / Pragmatist / Historian / Architect) before making a high-stakes decision. Dynamic multi-agent debate workflow. Use for high-stakes choices, multiple viable paths, or requests like 'second opinion', 'skeptic check', 'panel review', '/panel', '/skeptic-panel', 'convene a panel', 'stress test this decision'."
argument-hint: "[decision question]"
---
<!-- MIT License — Copyright (c) 2026 Garman Unified Systems — https://idirectships.com -->

# Skeptic Panel

Multi-agent debate primitive. Parallel personas with different priors deliberate;
a synthesizer returns Crux + Disagreement + Recommendation.

## When to use

| Stakes | Panel size | When |
|---|---|---|
| Routine | 2 | Quick gut check on a small reversible choice (skeptic + optimist) |
| Mid-stakes | 3 | Default — most architecture and routing decisions (+ pragmatist) |
| High-stakes | 4 | Spec freeze, vendor lock-in, irreversible refactor (+ historian) |
| DECIDE-4 | 5 | One-way doors: thesis pivot, repo archive, brand decision (+ architect) |

**Activate when:** someone asks for skepticism / second opinion / debate / panel / decision review;
an architecture choice has 3+ viable paths with non-obvious tradeoffs; a decision is one-way and
the advisor's own prior feels under-supported.

**Skip when:** the answer is obvious; the choice is reversible in under an hour; this is a stylistic preference.

---

## Execution

### Step 1 — Identify the decision question

If not provided, ask: "What decision should the panel evaluate?"

### Step 2 — Select panel size

Based on the stakes table above. Default: 3 (Skeptic + Optimist + Pragmatist).

### Step 3 — Dispatch personas in parallel

Spawn one agent per persona using the Agent tool. Each persona receives:
- The decision question
- Its prior (see Personas below)
- Instruction to produce a structured position: Verdict, Strongest Argument, Key Risk, Evidence

Run all persona agents in a single parallel dispatch.

### Step 4 — Synthesize

After all persona agents return, synthesize:

1. **Crux** — the single most load-bearing disagreement across positions
2. **Disagreements** — 2-4 bullets, one per persona's strongest objection
3. **Recommendation** — the synthesizer's call with rationale

### Step 5 — Present

Present to the user:
1. Crux (one sentence)
2. Disagreement summary (2-4 bullets)
3. Recommendation (call + rationale)

Do NOT present full persona positions unless the user asks.

For one-way doors, offer to save the panel result as `panels/<slug>-YYYY-MM-DD.json`.

---

## Personas

Carry these priors verbatim into each agent's prompt:

- **Skeptic** — find the strongest argument against; assume failure; cite concrete risks
- **Optimist** — find the strongest path forward; assume success is reachable; cite concrete wins
- **Pragmatist** — what is the smallest viable next step? What can be tested in under one day?
- **Historian** — what is the precedent in past decisions, encoded rules, or prior choices?
- **Architect** — what is the long-term structural implication? What does this lock in or close off?

---

## Agent prompt template (use for each persona)

```
You are the [PERSONA_NAME] in a structured decision panel.

Decision question: [DECISION]

Your prior: [PRIOR_FROM_PERSONAS_TABLE]

Produce a structured position:
- Verdict: [approve / reject / hold]
- Strongest argument: (1-2 sentences)
- Key risk or win: (1-2 sentences)
- Evidence or precedent: (cite one specific example, rule, or data point)

Be direct. No hedging. Under 150 words total.
```

---

## Synthesis prompt template

```
You are the synthesizer for a [N]-member decision panel on:
"[DECISION]"

Panel positions:
[PASTE EACH PERSONA RESULT]

Produce:
1. Crux: The single most load-bearing disagreement in one sentence.
2. Disagreements: 2-4 bullets, one per persona, each naming the strongest objection.
3. Recommendation: One clear call (approve / reject / hold) with a one-sentence rationale.

Under 200 words total. No persona-by-persona play-by-play.
```
