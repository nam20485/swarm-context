# /gh-issue-tracking-init skill existing plan mode plan

```
Repo with no plan hierarchy at all: the sub-issue-only convention needs a plan root for epics to attach to (parent rollup depends on it), so the skill wraps your feature list in a minimal Plan: <Name> issue and parents the epics under it.
```

So in this case, how about when it creates the thin wrapper plan parent issue, instead of it being empty or not useful, instead it derives and adhoc plan based on the features it was given and are attached underneath it. So based on the nature and content of the features, it can derive a plan that is more useful and meaningful. It doesnt have to be detailed, butit can be useful in that it descrtibes the "campaign" or common central theme that the features are trying to achieve. e.g. the feature set or functionality its adding (add GRPC API and replace REST, add GraphQL API, COnvert dpeloyment to ArgoCD, etc, etc,), or just something simple like "Clean-up and refactor backend", "Improve performance frontend performance", Expand Test Coverage", etc. This would allow the plan to be useful instead of an irrelevant necessity while also allowing the items that plans normally house or have attached to them to be attached to it and have a purpose.

- For when the plan already exists (from a previous run) : add an input parameter that specifies to continue on the existing plan (i.e. attach to the existing plan and start numbering from it), OR use the new feature case with that adds its own additional separate plan. Plan carries a constant flag inside that specifiiues the current default for the input parameter when no key or value is provided. 
  - `DEFAULT_EXISTING_PLAN_MODE` = { "continue existing", "new feature plan"} // start with "continue existing"

