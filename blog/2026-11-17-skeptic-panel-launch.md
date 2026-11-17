<!-- MIT License — Copyright (c) 2026 Garman Unified Systems — https://idirectships.com -->
---
title: "skeptic-panel: a multi-agent debate before the one-way door"
meta_description: "Every advisor has a prior. Run the debate before the decision: skeptic-panel dispatches parallel agents with opposite priors, then synthesizes Crux + Disagreements + Recommendation in one pass."
slug: skeptic-panel
skill: skeptic-panel
date: 2026-11-17
tags: [multi-agent, decision-making, ai-debate, skeptic, claude-skills, architecture-review]
representative_queries:
  - "how to get a second opinion from an AI before a big decision"
  - "multi-agent debate for architecture decisions"
  - "AI skeptic check on my plan"
  - "parallel personas for decision review"
  - "stress test a decision with AI"
  - "get an AI to argue against my plan"
---

# skeptic-panel: a multi-agent debate before the one-way door

## Hook

Every advisor has a prior. Ask for a plan and you get a plan. Ask for risks and
you get risks. Ask "is this a good idea?" and the agent confirms it is — because
"no" reads as failing to deliver. **skeptic-panel breaks this by running the
debate before the decision:** parallel agents with opposite priors argue the case,
then a synthesizer returns the crux of their disagreement and a recommendation.

## The Problem

A single-agent advisor is a single prior. It's the prior baked into the prompt
("what should I do?"), plus whatever confirmation bias the model picked up from
training. If you ask it to review your plan, it reviews your plan. If you ask it
to find holes, it finds holes. The question decides the answer.

One-way doors are where this bites hardest. Architecture choices, vendor lock-in,
thesis pivots — decisions where the cost of reversing is high and the cost of
getting it wrong is higher. By the time you realize the plan had a structural flaw,
you are past the door.

The pattern we needed: get the disagreement on the table before committing, not
after. The disagreement is data; the absence of it is not a signal that there is
nothing to disagree about.

## How It Works

skeptic-panel dispatches 2-5 parallel agents, each with a fixed prior that runs
against the question:

- **Skeptic** — find the strongest argument against; assume failure; cite concrete risks
- **Optimist** — find the strongest path forward; assume success is reachable; cite concrete wins
- **Pragmatist** — what is the smallest viable next step? What can be tested in under one day?
- **Historian** — what is the precedent in past decisions, encoded rules, or prior choices?
- **Architect** — what is the long-term structural implication? What does this lock in or close off?

Each agent returns a structured position: Verdict, Strongest Argument, Key Risk, Evidence.
A synthesizer reads all positions and returns three things:

1. **Crux** — the single most load-bearing disagreement, one sentence
2. **Disagreements** — 2-4 bullets, one per persona's strongest objection
3. **Recommendation** — one clear call with rationale

Nothing is hidden. The crux is the disagreement that decides the question; if the
Skeptic and Optimist agree on the same thing, the crux is elsewhere.

## Panel Size

| Stakes | Panel |
|---|---|
| Routine choice | Skeptic + Optimist |
| Architecture decision | + Pragmatist (default) |
| Spec freeze or lock-in | + Historian |
| One-way door | Full panel of 5 |

The panel size is a parameter, not a fixed configuration. Mid-stakes decisions run
three personas by default; one-way doors use all five.

## A Real Run

The question: "Should we replace the existing message bus with a streaming event log?"

**Skeptic:** Reject. Migration cost is underestimated; the existing bus handles backpressure
the team doesn't know about. Risk: the new log has no replay on consumer crash without
explicit implementation.

**Optimist:** Approve. The streaming log eliminates the coupling that blocks three
pending features. Win: query semantics are cleaner; the team can reason about state
at any point in time.

**Pragmatist:** Hold. Run one consumer off the new log in parallel for 72 hours before
cutting over. Smallest testable step in under a day.

**Synthesizer:**
- Crux: The team doesn't know about the existing backpressure handling — if the
  streaming log doesn't replicate that behavior, the cutover creates a hidden failure mode.
- Key disagreement: Skeptic says the migration surface is larger than the team realizes;
  Pragmatist says a 72-hour parallel run answers the question.
- Recommendation: Hold. Run the parallel consumer first. The Pragmatist's test surfaces
  the Skeptic's risk at low cost; approve after 72 hours green.

You didn't get a plan. You got the disagreement and a decision — the crux, the competing
positions, and a call. That is a different output than a single prior would produce.

## When To Use It

Reach for skeptic-panel when:

- An architecture choice has 3 or more viable paths with non-obvious tradeoffs.
- A decision is one-way and you want the strongest case against on the table before committing.
- You asked for a plan and realized you are only hearing one prior.
- Someone says "stress test this" or "get a second opinion."

Skip it when the answer is obvious, the choice is reversible in under an hour, or the
question is a matter of preference with no structural consequence.

## Try It

```
# Install
Copy skills/skeptic-panel/ into .claude/skills/skeptic-panel/

# Run
/skeptic-panel [decision question]
```

The full protocol, persona priors, and agent prompt templates are in
[`skills/skeptic-panel/SKILL.md`](../skills/skeptic-panel/SKILL.md).

---

*skeptic-panel is part of the DRUstack Skill Pack — open skills built from
real production mistakes. Each ships with the story of the mistake that produced it.
Built by [Garman Unified Systems](https://idirectships.com).*
