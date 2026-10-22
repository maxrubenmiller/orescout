# Agent briefs

Larger pieces of OreScout work were written up as a brief before an AI agent (Claude, via Claude
Code) carried them out. A brief fixes the goal, the scope, what must not change, and how the result
will be verified. The agent works against that, not an open-ended prompt.

| Brief | Kind | Outcome |
|---|---|---|
| [FABLE_REVIEW_BRIEF.md](FABLE_REVIEW_BRIEF.md) | Architecture & correctness review | [../REVIEW_PASS_A.md](../REVIEW_PASS_A.md) |
| [FABLE_PREPROD_AUDIT_BRIEF.md](FABLE_PREPROD_AUDIT_BRIEF.md) | Pre-production audit (multi-agent, verified findings) | [../REVIEW_PREPROD_AUDIT.md](../REVIEW_PREPROD_AUDIT.md), [../REVIEW_PREPROD_BACKLOG.md](../REVIEW_PREPROD_BACKLOG.md) |
| [OPUS_BRIEF_security_review.md](OPUS_BRIEF_security_review.md) | Security audit | Findings kept private; fixes tracked in commits |
| [TIER_B_FABLE_BRIEF.md](TIER_B_FABLE_BRIEF.md) | Feature build: prospecting-potential score | Prospecting overlay |
| [FABLE_MVUM_BRIEF.md](FABLE_MVUM_BRIEF.md) | Feature build: access & trails overlay | Access overlay |
| [OPUS_BRIEF_mrds_enrichment.md](OPUS_BRIEF_mrds_enrichment.md) | Feature: gold-occurrence popup details | MRDS popups |
| [OPUS_BRIEF_cannotmodel_visibility.md](OPUS_BRIEF_cannotmodel_visibility.md) | UI fix: show "not modeled" rules | Assessment panel |
| [OPUS_BRIEF_plan_classifier_sync.md](OPUS_BRIEF_plan_classifier_sync.md) | Docs: sync the plan with the live classifier | Updated plan |

The project's reusable agents (ETL runner, classifier auditor, validation QA, security reviewer)
are defined in [`.claude/agents/`](../../.claude/agents/).
