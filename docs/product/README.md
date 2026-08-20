# OreScout — Product Documentation

Product and business-facing documentation for OreScout. These documents translate the engineering material in the repository into language a non-engineer can act on, while keeping enough concrete detail (table names, agency codes, measured numbers) that a new engineer can onboard from them.

**Written 2026-08-20**, from the code as it stood on that date. Where the repository's markdown and its implementation disagreed, the code was treated as authoritative and the disagreement is recorded in each document's final section.

---

## The documents

| # | Document | Answers |
|---|---|---|
| **01** | [Application Overview](01-application-overview.md) | What OreScout does, how a user uses it, how the system is built, and **why it was built this way**. Includes the architecture and the decisions log |
| **02** | [The Legality Engine](02-legality-engine.md) | How the app decides a place is open, how it decides a place is off limits, and **every safety check** that guards against a wrong "yes" |
| **03** | [External Data Sources](03-external-data-sources.md) | Every external dataset and service the product depends on — what it provides, why it was chosen, what it costs legally, and where the risks are |

---

## If you only read one thing

OreScout answers one question: **"Can I legally collect rocks / pan for gold / prospect *here*?"** — across eight western states, on a map, in plain language.

The design principle that explains almost every decision in the product is:

> **GREEN must be earned.**

The app says *open* only where it has affirmatively confirmed the land is open public land. Everything it cannot confirm — private, state, tribal, unknown, or simply no data — defaults to cautious. Missing data can never produce a false "open"; only *wrong* data can. That is a far smaller and far more measurable risk surface, and it is why the product does not need to buy a nationwide private-land cadastre in order to be safe.

---

## Scope and maintenance

These documents describe the system **as built**, and are explicit about what is planned rather than shipped. They deliberately include known gaps, open defects, and measured residual risk, because a product document that only describes the happy path is not usable for launch planning.

They were derived from `PROJECT_PLAN.md`, the pre-production review documents, the source registry, and the application, ETL and classifier source code. Because that material continues to change, each document notes the date it reflects. When a substantial change lands — a new state, a data-source swap, a classifier change, or the closure of one of the open defects — the relevant document should be revisited rather than left to drift.
