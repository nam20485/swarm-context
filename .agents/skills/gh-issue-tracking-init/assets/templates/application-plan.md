---
name: Application Plan
about: Top-level plan issue for a complete application
title: 'Plan: '
labels: ['plan']
assignees: []
---

# Plan: [ProjectName] – Complete Implementation

## Overview

Provide a concise summary of the application, the problem it solves, the desired outcomes, and links to the filled-out template (docs/ai-new-app-template.md) and any supporting docs.

## Goals

- [Goal 1]
- [Goal 2]

## Technology Stack

- Language: [e.g., C# .NET 10.0]
- UI Framework: [e.g., Avalonia/Blazor/etc.]
- AI/Runtime: [e.g., ONNX Runtime / Azure OpenAI / etc.]
- Architecture: [e.g., RAG / MCP / Microservices]
- Databases/Storage: [e.g., Neo4j / SQLite / Postgres / Vector DB]
- Logging/Observability: [e.g., Serilog, OpenTelemetry]
- Containerization/Infra: [e.g., Docker, Compose, Terraform]

## Application Features

- [Feature 1]
- [Feature 2]
- [Feature 3]

## System Architecture

### Core Services (if applicable)

1. [ServiceName] — responsibility summary
2. [ServiceName] — responsibility summary

### Key Features (system-level)

- [Key feature/capability]

## Project Structure

```text
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

<!-- REQUIRED: every story/task entry below MUST carry its numeric triple-octet identifier verbatim (Epic <N>:, Story <N>.<M>:, Task <N>.<M>.<K>:). Plain-text bullets without identifiers are never acceptable in child-issue lists. -->

### Epic 1: Foundation & Setup

- [ ] Story 1.1: Repository and solution bootstrap
- [ ] Story 1.2: Core dependencies and configuration
- [ ] Story 1.3: Runtime/Model initialization (if AI)
- [ ] Story 1.4: Data/Knowledge base foundation (if RAG)
- [ ] Story 1.5: Basic content processing/indexing (if applicable)

### Epic 2: Core Services / Core Engine

#### Story 2.1: Core Module/Service A

- [ ] Task 2.1.1: Sub-task A
- [ ] Task 2.1.2: Sub-task B

#### Story 2.2: Core Module/Service B

### Epic 3: UI/UX & Integration

- [ ] Story 3.1: UI foundation and navigation
- [ ] Story 3.2: ViewModels/State management
- [ ] Story 3.3: Primary user flows (chat/task/…)
- [ ] Story 3.4: Async ops, cancellation, error handling
- [ ] Story 3.5: Settings/configuration

### Epic 4: Advanced Capabilities & Security

- [ ] Story 4.1: Tooling/Function calling/Agentic features (if applicable)
- [ ] Story 4.2: Human-in-the-loop approval and auditing
- [ ] Story 4.3: Performance optimizations and caching
- [ ] Story 4.4: Observability and dashboards

### Epic 5: Testing, Docs, Packaging & Deployment

- [ ] Story 5.1: Test suites (unit/integration/e2e/perf)
- [ ] Story 5.2: API/Developer documentation
- [ ] Story 5.3: Containerization/installer packaging
- [ ] Story 5.4: IaC/Environments/CI-CD pipelines
- [ ] Story 5.5: Final hardening and release checklist

---

## Development Standards

<!-- Canonical landing site for cross-cutting rules that apply to EVERY story and epic. Copy VERBATIM from the plan's mandatory-rules / operating-principles / naming-conventions / DoD / handoff-checklist / escalation-protocol sections. These rules live here ONCE — do not paste them into individual story or epic bodies. Omit any sub-section below for which the plan provides no content rather than leave placeholder text. -->

### Mandatory rules / operating principles

<!-- Verbatim from the plan's mandatory-rules table (e.g. R1–R8, or whatever form the plan uses). -->

### Naming & code conventions

<!-- Verbatim from the plan's naming-conventions table (namespace, entity, repository, command, endpoint, column, queue-key patterns). -->

### Definition of Done

<!-- Verbatim from the plan's global Definition of Done checklist. -->

### Handoff checklist (human reviewer)

<!-- Verbatim from the plan's handoff checklist for human reviewer. -->

### Escalation protocol

<!-- Verbatim from the plan's escalation / "never-guess" list. -->

---

## Exact package versions

<!-- Copy the plan's exact-version table VERBATIM. Do not summarize to prose — exact versions are mandatory and must be pinned. Omit this section entirely if the plan provides no version table. -->

| Component | Technology | Version |
|---|---|---|
| [row 1] | | |
| [row 2] | | |

---

## Repository layout

<!-- Copy the plan's file-level tree VERBATIM (full directory structure, not a 3-line summary). Omit this section entirely if the plan provides no file tree. -->

```text
[ProjectName]/
├─ ...
```

---

## Validation Plan

[Overall validation strategy for the application: how each epic and its stories will be verified, including test pyramid coverage, integration points, and release-gating criteria.]

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

- [ ] CI/CD workflows (build/test/scan/publish) *(Note: All GitHub Actions must be pinned by SHA)*
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

| Risk | Mitigation |
|------|------------|
| [Risk 1] | [Mitigation 1] |
| [Risk 2] | [Mitigation 2] |

## Timeline Estimate

- Epic 1: [x–y] weeks
- Epic 2: [x–y] weeks
- Epic 3: [x–y] weeks
- Epic 4: [x–y] weeks
- Epic 5: [x–y] weeks
- Total: [x–y] weeks

## Success Metrics

- [Metric 1]
- [Metric 2]
- [Metric 3]

## Implementation Notes

Key assumptions, adaptations, and references to technical docs or ADRs.
