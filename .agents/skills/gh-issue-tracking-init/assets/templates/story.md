---
name: Story
about: Create a detailed story for implementation
title: 'Story <N>.<M>: '
labels: ['story']
assignees: []
---

# Story <N>.<M>: [Story Name]

## Objective

[Clear, concise statement of what this story achieves and the expected outcome]

## Scope

### In Scope

- [What is included in this story]
- [Specific features or functionality to implement]

### Out of Scope

<!-- List only out-of-scope items SPECIFIC to this story. If there are none specific to this story (the common case), OMIT this "### Out of Scope" sub-heading entirely rather than inserting the phrase "Features deferred to other stories" or any other generic placeholder. -->

- [Out-of-scope item specific to THIS story, or omit the sub-heading entirely]

## Plan

<!-- REQUIRED: when a plan entry corresponds to a child issue (a Task), it MUST carry its numeric triple-octet identifier verbatim — Task <N>.<M>.<K>: <Name>. Pure implementation sub-steps that are NOT separate issues may use plain bullets. -->

### Implementation approach

<!-- If the plan provides an inline code/config snippet for this task (a `Reference:` block, or equivalent), reproduce it VERBATIM in a fenced code block with the matching language tag (```xml, ```csharp, ```sql, etc.) under a `#### Reference (from plan T-x.y)` sub-heading. Then list only concrete, task-specific implementation steps derived from this task's acceptance criteria. Omit this subsection entirely if the plan provides neither a snippet nor task-specific steps for this story — do not fill it with generic "Implement / Add tests / Verify" boilerplate. -->

#### Reference (from plan T-x.y)

<!-- Verbatim snippet in a fenced block with the correct language tag. Omit this sub-heading if the task has no plan-provided snippet. -->

```text
[verbatim code/config snippet from the plan, or omit this sub-heading]
```

### Tasks

- [ ] Task <N>.<M>.<K>: Description of first task
- [ ] Task <N>.<M>.<K>: Description of second task
- [ ] Task <N>.<M>.<K>: Description of third task
- [ ] Task <N>.<M>.<K>: Additional tasks as needed

## Acceptance Criteria

- [ ] Criterion 1: Specific, measurable condition that must be met
- [ ] Criterion 2: Another specific, measurable condition
- [ ] Criterion 3: Additional criteria as needed

## Validation Plan

[How the story's deliverables will be verified: which tests must pass, manual checks, and commands to run.]

- [ ] Validation task
- [ ] Validation task

## Validation Commands

<!-- Only include commands that are actually runnable for THIS story in its current state (e.g. `dotnet build src/MyProject.Domain` for a domain-layer story). Omit this section entirely if no story-specific command yet exists (e.g. bootstrap stories with no test project). Do not insert `dotnet build` / `dotnet test` generically — that is filler that misleads when the project does not yet exist. -->

## Dependencies

### Related Issues

- Blocks: #[issue-number]
- Depends on: #[issue-number]
- Related to: #[issue-number]

### Environment Variables

- `VAR_NAME`: Description of what this variable controls

### External Services

- Service name: Purpose and configuration details

### Data Requirements

- Data source or format needed for this story

## Risks & Mitigations

| Risk     | Likelihood     | Impact         | Mitigation              |
| -------- | -------------- | -------------- | ----------------------- |
| [Risk 1] | [Low/Med/High] | [Low/Med/High] | [Mitigation strategy 1] |
| [Risk 2] | [Low/Med/High] | [Low/Med/High] | [Mitigation strategy 2] |

## Test Strategy

### Unit Tests

- [Description of unit tests to be written]
- [Coverage targets and key test cases]

### Integration Tests

- [Description of integration tests]
- [Key integration points to validate]

### E2E Tests

- [Description of end-to-end tests]
- [User flows to validate]

## Rollback

### Rollback Steps

1. [Step 1: How to revert changes]
2. [Step 2: How to restore previous state]
3. [Step 3: How to verify rollback success]

### Rollback Validation

- [ ] Verify system returns to previous state
- [ ] Confirm no data loss
- [ ] Validate dependent systems still function

## Implementation Notes

<!-- Task-specific technical notes, constraints, or design decisions only. Omit this section entirely if there are none — do not append generic global-policy boilerplate (Conventional Commits, CancellationToken rules, no-hardcoded-secrets). Those belong on the Plan body's Development Standards section, not on each story. -->

[Task-specific technical details, or omit this section entirely]

## Related Documentation

- [Link to design docs]
- [Link to API documentation]
- [Link to architecture decisions]
