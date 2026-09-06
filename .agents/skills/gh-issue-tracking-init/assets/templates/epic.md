---
name: Epic
about: Epic-level issue scoped to a single project/component
title: 'Epic <N>: '
labels: ['epic']
assignees: []
---

# Epic <N>: [Epic Name]

## Overview

Provide a concise summary of the epic, the problem it solves, the component it lives in, and the desired outcomes.

## Project

Project containing the component.

## Component

Component the epic lives in.

## Goals

- [Goal 1]
- [Goal 2]

## Brief Technology Stack

<!-- List ONLY the technologies actually used by THIS epic's stories. Remove any row below that does not apply to this epic. Do NOT reuse the same technology block across multiple epics — each epic's stack must be specific to it (e.g. an AI-centric epic lists AI/Runtime + embeddings; a UI-centric epic lists the UI framework + charting library; a data-pipeline epic lists the ORM + queue). A 5-line stack block that appears verbatim in every epic is filler and will trip the DryRun filler detector. -->

- Language: [e.g., C# .NET 8.0]
- UI Framework: [if applicable; omit if not]
- AI/Runtime: [if applicable; omit if not]
- Architecture: [e.g., RAG / event-driven / microservices — omit if not specific to this epic]
- Databases/Storage: [only the DBs this epic writes to or reads from]
- Logging/Observability: [omit if epic does not add observability surface]
- Containerization/Infra: [omit if epic does not touch infra]

## Epic Stories

<!-- REQUIRED: every entry below MUST carry its numeric identifier verbatim — Story <N>.<M>: <Name> — never a plain-text bullet. These list the epic's child issues. -->

- [ ] Story <N>.<M>: <Story Name>
- [ ] Story <N>.<M>: <Story Name>
- [ ] Story <N>.<M>: <Story Name>

## Component Architecture

### Core Services (if applicable)

1. [ServiceName] — responsibility summary
2. [ServiceName] — responsibility summary

### Key Tasks (system-level)

- [Key task/capability]

## Project Structure Area

*(Highlight/indicate or only include (indicate summarized content with `...` above and below) the folders impacted by this epic.)*

```
[ProjectName]/
├─ src/
│  ├─ [Project].Core/
│  ├─ [Project].Api/
│  ├─ [Project].Frontend/
│  └─ [Project].Shared/
├─ tests/
├─ docs/
├─ scripts/
├─ docker/
├─ assets/
└─ global.json
```

---

## Implementation Plan

<!-- REQUIRED: every story/task entry below MUST carry its numeric triple-octet identifier verbatim (Story <N>.<M>:, Task <N>.<M>.<K>:). Use this epic's actual number for <N>. Plain-text bullets without identifiers are never acceptable. -->

### Story 1: Foundation & Setup

- [ ] 1.1. Repository and solution bootstrap
- [ ] 1.2. Core dependencies and configuration
- [ ] 1.3. Runtime/Model initialization (if AI)
- [ ] 1.4. Data/Knowledge base foundation (if RAG)
- [ ] 1.5. Basic content processing/indexing (if applicable)

### Story 2: Core Services / Core Engine

- [ ] 2.1. Implement core module/service A
  - [ ] 2.1.1. Sub-task A
  - [ ] 2.1.2. Sub-task B
- [ ] 2.2. Implement core module/service B

### Story 3: UI/UX & Integration

- [ ] 3.1. UI foundation and navigation
- [ ] 3.2. ViewModels/State management
- [ ] 3.3. Primary user flows (chat/task/…)
- [ ] 3.4. Async ops, cancellation, error handling
- [ ] 3.5. Settings/configuration

### Story 4: Advanced Capabilities & Security

- [ ] 4.1. Tooling/Function calling/Agentic features (if applicable)
- [ ] 4.2. Human-in-the-loop approval and auditing
- [ ] 4.3. Performance optimizations and caching
- [ ] 4.4. Observability and dashboards

### Story 5: Testing, Docs, Packaging & Deployment

- [ ] 5.1. Test suites (unit/integration/e2e/perf)
- [ ] 5.2. API/Developer documentation
- [ ] 5.3. Containerization/installer packaging
- [ ] 5.4. IaC/Environments/CI-CD pipelines
- [ ] 5.5. Final hardening and release checklist

## Validation Plan

[How the epic's stories and overall component behavior will be validated: integration test scope, acceptance verification, and definition of done for the epic.]

- [ ] Validation task
- [ ] Validation task

---

## Mandatory Requirements Implementation

### Testing & Quality Assurance

- [ ] Unit tests — coverage target: [e.g., 80%+]
- [ ] Integration tests
- [ ] E2E tests
- [ ] Performance/load tests
- [ ] Automated tests in CI

### Documentation & UX

- [ ] Comprehensive README
- [ ] User manual and feature docs
- [ ] XML/API docs (public APIs)
- [ ] Troubleshooting/FAQ
- [ ] In-app help (if applicable)

### Build & Distribution

- [ ] Build scripts
- [ ] Containerization support (if relevant)
- [ ] Installer packaging (if desktop)
- [ ] Release pipeline

### Infrastructure & DevOps

- [ ] CI/CD workflows (build/test/scan/publish)
- [ ] Static analysis and security scanning
- [ ] Performance benchmarking/monitoring

---

## Acceptance Criteria

- [ ] Core architecture implemented and components communicate as designed
- [ ] Key features/functionality work end-to-end
- [ ] Observability/logging in place with actionable signals
- [ ] Security model and controls validated
- [ ] Test coverage target met and CI green
- [ ] Containerization/packaging works for target environment(s)
- [ ] Documentation complete and accurate

## Risk Mitigation Strategies

<!-- Pull ONLY the risk rows from the plan's risk register whose mitigation references a task within this epic. Do not copy the entire risk register into every epic. If the plan provides no epic-specific risks, omit this section entirely rather than inserting generic placeholder rows. The full risk register lives on the Plan body — not on every epic. -->

| Risk | Impact | Mitigation (task id) |
|------|--------|----------------------|
| [Risk specific to this epic] | [Low/Med/High] | [Mitigation referencing a task id within this epic] |

## Timeline Estimate

- Story 1: [x–y] weeks
- Story 2: [x–y] weeks
- Story 3: [x–y] weeks
- Story 4: [x–y] weeks
- Story 5: [x–y] weeks
- Total: [x–y] weeks

## Success Metrics

- [Metric 1]
- [Metric 2]
- [Metric 3]

## Implementation Notes

Key assumptions, adaptations, and references to technical docs or ADRs.
