# skeptic-panel

Convene a 2-5 persona debate before making a high-stakes decision.

## What it does

Runs parallel agents — Skeptic, Optimist, Pragmatist, Historian, Architect — each
with a fixed prior, then synthesizes their positions into a Crux, Disagreements, and
Recommendation. One install; no external dependencies.

| Stakes | Personas |
|---|---|
| Routine | Skeptic + Optimist |
| Mid-stakes | + Pragmatist (default) |
| High-stakes | + Historian |
| One-way door | Full panel of 5 |

## Install

Copy `skills/skeptic-panel/` into `.claude/skills/skeptic-panel/`

## Usage

Triggers on: `second opinion`, `skeptic check`, `panel review`, `/panel`,
`/skeptic-panel`, `convene a panel`, `stress test this decision`.

**Argument:** `[decision question]`

## Files

- `SKILL.md` — panel protocol, persona priors, agent and synthesis prompt templates

## Pairs with

A neutral-audit pass on whatever code or spec the decision is about — understand it
first, then run the panel.

## Config

None required.
