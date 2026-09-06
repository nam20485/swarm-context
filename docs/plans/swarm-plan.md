# Custom Agent Swarm Plan

Use custom instructions, skills, and  custom agents to implement a swarm, which can be tasked with a goal. Swarm orchestrator creates as many subagents as he needs, and delegates to/orchestrates them to accomplish the goal.

Simple setup:

```log
.agents/
    agents/
        swarm-orchestrator.md
        swarm-agent.md                 // simplest base def with least amount of params, can be "extended" for specialist subagents
    skills/
        swarm/
            SKILL.md
AGENTS.md
```

Agent defs:

`swarm-orchestrator`
`subagent` 

Create subagent definitions as needed to accomplish the goal. Instrcutions to create the smallest, narrowest, least capable-permission wise subagent that can effecitvelyl accomplish its task. When you need a dedeciated type, create a definition for it and spawn that. Dont create too many subgant types. < 5 dedicated subagent types should be enough.

Create a generic subagent def. template w/ commented out example properties

skill: to set the goal and start the swarm with parameters

inputs:

max subagents: default 50
goal: string loop invariant

``` python
while ! goal.successful
   // do swarm stuff!
```

# AGENTS.md for instructions

Include the zcode docs site url in this file.

Harness

zcode is used tfor the harness. All definitions for agents should be in zcode format: <https://zcode.z.ai/en/docs/subagents>

run in a sandbox!

References:

zcode docs: <https://zcode.z.ai/en/docs>

cursor:

- [cursor swarm blog](https://cursor.com/blog/multi-agent-kernels)
- [agent swarm economics](https://cursor.com/blog/agent-swarm-model-economics)
