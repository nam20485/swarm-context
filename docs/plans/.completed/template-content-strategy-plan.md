@docs/plans/.deferred/template-content-strategy.md So lets revisit our strategy here and update to account for the options provided by the repo creation script that we use.

Consider the following:

1. Here is the repo where use to prefrom the clone of this template from: `https://github.com/nam20485/workflow-launch2`

It has:

- the various app plan docs in `plan_docs` subdirs (named by "app plan name slug")
- the scripts we use to perform the clone

1. the script: `https://github.com/nam20485/workflow-launch2/blob/main/scripts/create-repo-from-slug.ps1`
   - invoked like so:  `./scripts/create-repo-from-slug.ps1 -Slug "gap-miner-v2" -TemplateRepoName "agent-context" -TriggerProjectSetup $False -Yes`

Note the step that performs rewriting in the @AGENTS.md file (literally this file's counterpart in the post-cloned repo instance)

Here is an example cloned instance repo produced from the script invocation above: `https://github.com/intel-agency/gap-miner-v2-delta12`

Analyze all that and then present a report on how it affects the issues we described in the content strategy doc (i.e. @docs/plans/.deferred/template-content-strategy.md)
