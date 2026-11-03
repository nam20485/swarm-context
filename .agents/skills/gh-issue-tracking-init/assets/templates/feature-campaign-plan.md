---
name: Feature Campaign Plan
about: Top-level plan issue for a feature campaign derived from a feature list
title: 'Plan: '
labels: ['plan']
assignees: []
---

<!-- FEATURE CAMPAIGN template — used ONLY when the plan source is a feature list / user feature description (see SKILL.md "Feature-list plan source"). Every section is DERIVED from the features; never fabricate content the list does not support. Heavyweight application-plan sections (Technology Stack table, System Architecture, Project Structure, Development Standards, Exact package versions, Repository layout) are NEVER fabricated for a campaign — omit them entirely. Omit any section below that has no derivable content. -->

# Plan: [CampaignName] – Feature Campaign

<!-- [CampaignName] derivation: the tightest honest theme shared by the features, 2–5 words. Calibration: "gRPC Migration", "Backend Cleanup & Refactor", "Frontend Performance", "Expand Test Coverage", "ArgoCD Deployment Conversion". Truly heterogeneous fallback: "Feature Batch: <dominant theme or YYYY-MM>". -->

## Overview

<!-- Derived theme, 3–6 sentences: what the feature set collectively achieves and why — the campaign's central theme and intended outcome. NO per-feature detail here; each feature's detail lives on its own Epic body. -->

## Goals

<!-- 2–5 bullets derived from the features (each goal may span several features). -->

- [Goal 1]
- [Goal 2]

---

## Implementation Plan

<!-- REQUIRED: every story/task entry below MUST carry its numeric identifier verbatim (Epic <N>:, Story <N>.<M>:, Task <N>.<M>.<K>:). Plain-text bullets without identifiers are never acceptable in child-issue lists. One Epic per feature (a trivial feature may be a single-story epic); assign <N> starting from the run's resolved NextEpicNumber — epic numbering continues the repo-wide max across ALL plans (open + closed), never restarts at 1. -->

### Epic 1: [Feature Name]

- [ ] Story 1.1: [Story name — only when the feature has evident sub-work; a trivial feature is a single-story epic]
- [ ] Story 1.2: [Story name]

## Out of Scope

<!-- Omit this section entirely when the feature list implies nothing explicitly out of scope; do not fabricate exclusions. -->

- [Explicitly deferred item]

## Success Criteria

<!-- Omit this section entirely when no criteria are derivable from the feature list; do not fabricate. -->

- [Criterion 1]
