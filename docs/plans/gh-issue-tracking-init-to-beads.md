# GH ↔ beads: `beads.jsonl` graph schema import/export script

1. Model the gh-issue-tracking-init issue and parent/sub-issue blocks (epic → story → task?) using the existing `beads.jsonl` graph schema.
2. Use this schema as the "intermediate language" for syncing back and forth.
3. Also use it as the format for serializing and deserializing gh-issue-tracking-init skill output:
   - Instead of writing to GitHub directly, model the objects and relationships in this `beads.jsonl` intermediate representation.
   - Write it out and save it, so it is capturable — saveable and loadable.
   - The skill can then use the schema's saved IL file format to drive creation of the GitHub objects and relationships.
4. This also enables import to and export from beads, since it already uses the native `beads.jsonl` format.
5. Model the extra-beads-format objects (projects, labels, milestones) as a superset of the `beads.jsonl` format, so beads ignores them while the skill can serialize/deserialize them and save/load them to GitHub. Consider writing these to a separate second file so beads doesn't choke when ingesting.
6. Support `bd import --file github_issues.jsonl` for direct ingestion.
7. The alternative is to drive it manually using `bd` commands:

```sh
# 1. Initialize beads workspace (Dolt-backed)
bd init --quiet

# 2. Ingest parent issues
PARENT_ID=$(bd create "Parent Feature Title" -t epic -q)

# 3. Create sub-issues using the --parent flag
# Beads sets dependency_type to "parent-child"
CHILD_ID=$(bd create "Subtask Implementation" --parent "$PARENT_ID" -q)

# 4. If execution order/blocking is needed between sub-issues:
bd dep add "$CHILD_ID" "$BLOCKER_ID" --type blocks
```

## Mechanism of action

- Use Python scripting with Pydantic definitions so the schema is strongly typed.
- As per policy, the skill can drive the Python scripts.

Consider making this a separate skill, invocable by the gh-issue-tracking-init skill; the alternative is for the main script to call Python directly. Either way, the sync/import/export functionality must be usable outside of the skill.

## Requirements

1. Serialize the gh-issue-tracking-init output to a file.
2. Read the serialized file and generate the GH issue-tracking-init hierarchy from it.
3. Ingest the gh-issue-tracking-init-generated hierarchy into beads.
