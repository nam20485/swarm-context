#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Ensure the Projects v2 board (fields, Status options, and views) exists for a repo.

.DESCRIPTION
    Idempotently creates the GitHub Project (if missing), links it to the repo,
    and ensures the custom fields used by the gh-issue-tracking system:

        Level    (SINGLE_SELECT: plan, epic, story, task)
        Priority (SINGLE_SELECT: P0, P1, P2, P3)
        Estimate (NUMBER)
        Phase    (SINGLE_SELECT: <supplied via -Phases>) -- only when -Phases is provided

    It also ensures the built-in Status field carries the full option set
    (Todo / In Progress / In Review / Blocked / Done) via the GraphQL
    updateProjectV2Field mutation (options are replace-all: existing option ids
    are always re-sent so item values survive), and creates the four standard
    views (By Phase, By Status, By Epic, Current work) via the Projects v2
    REST view API + GraphQL view mutations (GA on github.com since 2026).

    When those API surfaces are unavailable (e.g. GHES or an older deployment),
    the script degrades gracefully: it prints the manual UI instructions for
    whatever it could not automate and still exits 0.

.PARAMETER Owner
    Project owner (user or org) — e.g. the repository owner.

.PARAMETER Repo
    Repository to link, in 'owner/repo' form.

.PARAMETER Title
    Project title (default: the repository name).

.PARAMETER Phases
    Optional phase names. When supplied, a single-select "Phase" field is created
    with these options and the "By Phase" view groups by it. Phases are optional
    and may be omitted entirely.

.PARAMETER DryRun
    Show planned actions without applying them.

.EXAMPLE
    ./.agents/skills/gh-issue-tracking-init/scripts/ensure-project.ps1 -Owner nam20485 -Repo nam20485/SupportAssistant -DryRun

.EXAMPLE
    ./.agents/skills/gh-issue-tracking-init/scripts/ensure-project.ps1 -Owner myorg -Repo myorg/app -Phases 'Current','Future'

.NOTES
    Requires: GitHub CLI (gh) authenticated with the `project` scope.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Owner,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string]$Repo,

    [Parameter()]
    [string]$Title,

    [Parameter()]
    [string[]]$Phases,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Get-JsonProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    # Leading comma prevents PowerShell from unrolling an empty array to $null in the pipeline.
    # An explicit $null guard avoids returning a 1-element array wrapping $null (which would
    # break $null -eq $val checks at call sites).
    if ($prop) {
        if ($null -eq $prop.Value) { return $null }
        return , $prop.Value
    }
    return $null
}

# Canonical Status option set. The merge in Ensure-StatusOptions is purely ADDITIVE:
# existing options are echoed back verbatim (id + color + description preserved);
# these colors/descriptions apply only to newly created options. This keeps re-runs
# no-ops and never stomps platform defaults (Todo/GREEN, In Progress/YELLOW, Done/PURPLE)
# or user customizations.
$script:CanonicalStatusOptions = @(
    @{ Name = 'Todo';        Color = 'GRAY';   Description = '' }
    @{ Name = 'In Progress'; Color = 'BLUE';   Description = '' }
    @{ Name = 'In Review';   Color = 'YELLOW'; Description = 'Awaiting review' }
    @{ Name = 'Blocked';     Color = 'RED';    Description = 'Blocked by another issue' }
    @{ Name = 'Done';        Color = 'GREEN';  Description = '' }
)

function Get-ProjectState {
    <#
    .SYNOPSIS
        One GraphQL read of the project's fields (with option ids) and views.

    .DESCRIPTION
        Resolves owner type through repository(...).owner (Organization or User)
        so a user-owned project produces no query errors, and returns a state
        object: IsUser, UserDbId (REST user-path needs the NUMERIC id), Fields,
        Views. Returns $null on ANY failure so callers fall back to manual
        instructions instead of aborting the run.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][int]$Number
    )
    $parts = Get-RepoParts -Repo $Repo
    # Both connections are paginated (up to 50 per page). GitHub views are not
    # name-unique, so a hidden page-2 view would otherwise defeat the existence
    # checks in Ensure-Views and cause duplicate creates; likewise a project
    # with > 50 fields could hide Status / Phase / Parent issue beyond the
    # first page, silently degrading grouping (re-runs skip existing views by
    # name, so the degradation would never be repaired). Cursor variables are
    # omitted on the first call (server treats them as null).
    $query = @'
query($owner: String!, $name: String!, $number: Int!, $fieldCursor: String, $viewCursor: String) {
  repository(owner: $owner, name: $name) {
    owner {
      __typename
      ... on Organization { projectV2(number: $number) { ...ProjectBody } }
      ... on User { databaseId projectV2(number: $number) { ...ProjectBody } }
    }
  }
}
fragment ProjectBody on ProjectV2 {
  id
  fields(first: 50, after: $fieldCursor) {
    nodes { ...FieldConfig }
    pageInfo { hasNextPage endCursor }
  }
  views(first: 50, after: $viewCursor) {
    nodes { id number name layout }
    pageInfo { hasNextPage endCursor }
  }
}
fragment FieldConfig on ProjectV2FieldConfiguration {
  __typename
  ... on ProjectV2Field { name id databaseId }
  ... on ProjectV2IterationField { name id databaseId }
  ... on ProjectV2MultiSelectField { name id databaseId }
  ... on ProjectV2SingleSelectField { name id databaseId options { id name color description } }
}
'@
    # NB: the Int! variable must go via -F (raw): gh's typed -f makes GraphQL
    # reject $number with "provided invalid value" (verified live).
    $baseArgs = @('api', 'graphql', '-f', "query=$query", '-f', "owner=$($parts.Owner)", '-f', "name=$($parts.Name)", '-F', "number=$Number")
    $ownerNode = $null
    $projNode = $null
    $fields = @()
    $views = @()
    $fieldCursor = $null
    $viewCursor = $null
    $fieldsDone = $false
    $viewsDone = $false
    try {
        # Loop until BOTH connections are exhausted. A finished connection's
        # cursor is dropped from the next request (it would just return an
        # empty page) and its nodes are skipped on subsequent iterations, so
        # re-delivered page-1 data is never appended twice.
        while (-not ($fieldsDone -and $viewsDone)) {
            $ghArgs = $baseArgs
            if ($null -ne $fieldCursor) { $ghArgs += @('-f', "fieldCursor=$fieldCursor") }
            if ($null -ne $viewCursor) { $ghArgs += @('-f', "viewCursor=$viewCursor") }
            $resp = Invoke-GhJson @ghArgs
            if ($null -eq $resp) { return $null }
            # Direct property access (not Get-JsonProp chaining): Get-JsonProp returns a
            # comma-wrapped single-element array, which chained lookups cannot consume.
            # Set-StrictMode throws on a missing property, so a malformed response lands
            # in the catch and degrades to the manual fallback instead of aborting.
            $pageOwner = $resp.data.repository.owner
            if ($null -eq $pageOwner) { return $null }
            if ($null -eq $ownerNode) {
                $ownerNode = $pageOwner
                $isUser = ($ownerNode.__typename -eq 'User')
                $projNode = $ownerNode.projectV2
                if ($null -eq $projNode) { return $null }
            }
            $pageProject = $pageOwner.projectV2
            if ($null -eq $pageProject) { return $null }
            if (-not $fieldsDone) {
                $fields += @($pageProject.fields.nodes | Where-Object { $null -ne $_ })
                if ($pageProject.fields.pageInfo.hasNextPage) {
                    $fieldCursor = $pageProject.fields.pageInfo.endCursor
                }
                else {
                    $fieldsDone = $true
                    $fieldCursor = $null
                }
            }
            if (-not $viewsDone) {
                $views += @($pageProject.views.nodes | Where-Object { $null -ne $_ })
                if ($pageProject.views.pageInfo.hasNextPage) {
                    $viewCursor = $pageProject.views.pageInfo.endCursor
                }
                else {
                    $viewsDone = $true
                    $viewCursor = $null
                }
            }
        }
        $userDbId = $null
        if ($isUser -and $null -ne $ownerNode.PSObject.Properties['databaseId']) {
            $userDbId = [long]$ownerNode.databaseId
        }
    }
    catch {
        return $null
    }
    return [pscustomobject]@{
        IsUser    = $isUser
        UserDbId  = $userDbId
        ProjectId = $projNode.id
        Fields    = $fields
        Views     = $views
    }
}

function Find-ProjectField {
    param($State, [string]$Name)
    return @($State.Fields) | Where-Object { $_.name -eq $Name } | Select-Object -First 1
}

function ConvertTo-GraphQLString {
    <#.SYNOPSIS ConvertTo-Json a single string into a valid GraphQL string literal (properly escaped, quoted). Accepts empty strings.#>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return (ConvertTo-Json $Value -Compress)
}

function Get-OptionProp {
    <#
    .SYNOPSIS
        Null/empty-safe string read of an option node property with a default,
        used when building singleSelectOption literals. Guards both against a
        null or empty value (an empty color would render the invalid literal
        'color: ,') and against a missing property under Set-StrictMode.
    #>
    param($Object, [string]$Name, [string]$Default = '')
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop -and -not [string]::IsNullOrEmpty($prop.Value)) { return "$($prop.Value)" }
    return $Default
}

function Ensure-StatusOptions {
    <#
    .SYNOPSIS
        Ensure the built-in Status single-select carries the canonical option set.

    .DESCRIPTION
        updateProjectV2Field REPLACES the full option list; omitting an existing
        option's id regenerates its identity and CLEARS item field values. The
        merge is therefore additive-only: when every canonical option is already
        present (by name, case-insensitive) the function no-ops (order, colors
        and descriptions are left exactly as they are); otherwise it rebuilds
        the list in canonical order — existing options echoed with their ids and
        current color/description, missing ones added with the canonical
        color/description, unknown extras appended unchanged at the end — and
        sends one mutation.

    .OUTPUTS
        $true when the option set is fully ensured (or would be, in DryRun);
        $false when it could not be automated (caller prints the manual note).
    #>
    param(
        [Parameter(Mandatory = $true)]$State,
        [switch]$DryRun
    )
    $statusField = Find-ProjectField -State $State -Name 'Status'
    if ($null -eq $statusField) { return $false }
    # Direct property access (Get-JsonProp comma-wraps, which would nest the
    # options array one level too deep for the foreach below).
    $existing = @()
    $optProp = $statusField.PSObject.Properties['options']
    if ($optProp -and $null -ne $optProp.Value) { $existing = @($optProp.Value) }
    foreach ($o in $existing) {
        if ($null -eq (Get-JsonProp $o 'id')) { return $false } # cannot preserve identity -> do not risk it
    }

    $missing = @($script:CanonicalStatusOptions | Where-Object {
            $c = $_
            -not (@($existing) | Where-Object { $_.name -ieq $c.Name } | Select-Object -First 1)
        })
    if ($missing.Count -eq 0) {
        Write-Skip "Status options already complete ($((@($existing | ForEach-Object { $_.name }) -join ', ')))."
        return $true
    }

    # Rebuild in canonical order: existing entries echo id + current color/description;
    # missing entries use the canonical color/description; extras keep their place at the end.
    $usedIds = @{}
    $merged = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($c in $script:CanonicalStatusOptions) {
        $match = @($existing | Where-Object { $_.name -ieq $c.Name }) | Select-Object -First 1
        if ($match) {
            $usedIds[$match.id] = $true
            $merged.Add(@{ id = "$($match.id)"; name = "$($match.name)"; color = (Get-OptionProp $match 'color' 'GRAY'); description = (Get-OptionProp $match 'description' '') })
        }
        else {
            $merged.Add(@{ name = $c.Name; color = $c.Color; description = $c.Description })
        }
    }
    foreach ($e in $existing) {
        if (-not $usedIds.ContainsKey("$($e.id)")) {
            $merged.Add(@{ id = "$($e.id)"; name = "$($e.name)"; color = (Get-OptionProp $e 'color' 'GRAY'); description = (Get-OptionProp $e 'description' '') })
        }
    }

    $missingNames = ($missing | ForEach-Object { $_.Name }) -join ', '
    if ($DryRun) {
        Write-DryRun "Would add Status option(s): $missingNames (via updateProjectV2Field; existing option ids preserved)."
        return $true
    }

    $optionLiterals = @($merged | ForEach-Object {
            $idPart = if ($_.ContainsKey('id') -and $_.id) { "id: $(ConvertTo-GraphQLString $_.id), " } else { '' }
            '{ ' + $idPart + 'name: ' + (ConvertTo-GraphQLString $_.name) + ', color: ' + $_.color + ', description: ' + (ConvertTo-GraphQLString $_.description) + ' }'
        })
    $joinedOptions = $optionLiterals -join ', '
    $mutation = 'mutation($fieldId: ID!) { updateProjectV2Field(input: { fieldId: $fieldId, singleSelectOptions: [' + $joinedOptions + '] }) { projectV2Field { ... on ProjectV2SingleSelectField { name options { id name } } } } }'
    $ghArgs = @('api', 'graphql', '-f', "query=$mutation", '-f', "fieldId=$($statusField.id)")
    try {
        Invoke-Gh @ghArgs | Out-Null
    }
    catch {
        Write-Warning "Failed to update Status options via API: $($_.Exception.Message)"
        return $false
    }
    Write-Ok "Status options ensured (added: $missingNames; existing option ids preserved)."
    return $true
}

function Invoke-CreateViewRest {
    <#
    .SYNOPSIS
        REST-create one project view (POST .../projectsV2/{n}/views): one call
        carries layout + grouping + filter. Throws on failure.

    .DESCRIPTION
        Unlike the Invoke-Gh wrapper, stderr is captured INTO the exception
        message so callers can distinguish HTTP 404/405 ("endpoint unavailable
        on this target") from transient failures (429/5xx/422) and gate the
        GraphQL fallback accordingly.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PathPrefix,
        [Parameter(Mandatory = $true)][int]$Number,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('table', 'board')][string]$Layout,
        [long]$GroupByDbId,
        [long]$VerticalGroupByDbId,
        [string]$Filter
    )
    $path = "$PathPrefix/projectsV2/$Number/views"
    $ghArgs = @('api', '--method', 'POST', $path,
        '-H', 'Accept: application/vnd.github+json',
        '-H', 'X-GitHub-Api-Version: 2026-03-10',
        '-f', "name=$Name",
        '-f', "layout=$Layout")
    if ($GroupByDbId) { $ghArgs += @('-F', "group_by[]=$GroupByDbId") }
    if ($VerticalGroupByDbId) { $ghArgs += @('-F', "vertical_group_by[]=$VerticalGroupByDbId") }
    if ($Filter) { $ghArgs += @('-f', "filter=$Filter") }
    $cmd = 'gh ' + ($ghArgs -join ' ')
    Write-Log -Op 'gh' -Message "INVOKING: $cmd"
    $output = & gh @ghArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        $detail = ($output | Out-String).Trim()
        Write-Log -Op 'gh' -Message "FAILED (exit $code): $cmd :: $detail"
        throw "POST $path failed (exit $code): $detail"
    }
    Write-Log -Op 'gh' -Message "OK (exit 0): $cmd"
}

function Invoke-CreateViewGraphQl {
    <#
    .SYNOPSIS
        Fallback view creation via the GraphQL createProjectV2View mutation.

    .DESCRIPTION
        Covers targets where the REST view API is unavailable (verified live:
        user-owned projects 404 on /users/{id}/projectsV2/... today). GraphQL
        create supports only name + layout; a filter is applied with a
        follow-up updateProjectV2View, and board GROUPING cannot be set at
        all — the caller warns about that. Throws on failure.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('TABLE_LAYOUT', 'BOARD_LAYOUT')][string]$GraphQlLayout,
        [string]$Filter
    )
    $create = 'mutation($projectId: ID!, $name: String!, $layout: ProjectV2ViewLayout!) { createProjectV2View(input: { projectId: $projectId, name: $name, layout: $layout }) { projectV2View { id } } }'
    $ghArgs = @('api', 'graphql', '-f', "query=$create", '-f', "projectId=$ProjectId", '-f', "name=$Name", '-f', "layout=$GraphQlLayout")
    $created = Invoke-GhJson @ghArgs
    $viewId = $created.data.createProjectV2View.projectV2View.id
    if ($Filter -and $viewId) {
        Start-Sleep -Milliseconds 500
        $update = 'mutation($viewId: ID!, $filter: String) { updateProjectV2View(input: { viewId: $viewId, filter: $filter }) { projectV2View { id } } }'
        $ghArgs = @('api', 'graphql', '-f', "query=$update", '-f', "viewId=$viewId", '-f', "filter=$Filter")
        # The view EXISTS at this point: a filter failure must not propagate as a
        # create-failure (that would print manual instructions to duplicate it).
        try {
            Invoke-Gh @ghArgs | Out-Null
        }
        catch {
            Write-Warning "View '$Name' created but its filter could not be set ($($_.Exception.Message)); set the filter '$Filter' once in the view menu."
        }
    }
}

function Ensure-Views {
    <#
    .SYNOPSIS
        Ensure the four standard views exist: By Phase (table, grouped by Phase
        when -Phases is used), By Status (board grouped by Status), By Epic
        (board grouped by the built-in Parent issue field), Current work
        (table filtered to open, unblocked items).

    .DESCRIPTION
        Preferred path: the Projects v2 REST view API (one call carries layout,
        grouping and filter). Fallback: GraphQL createProjectV2View +
        updateProjectV2View(filter) when REST is unavailable — that fallback
        cannot set board grouping, so grouped views created through it carry a
        one-time manual grouping hint. Removal of the leftover default "View 1"
        uses deleteProjectV2View, and only in a run where "By Phase" was newly
        created (a deliberately kept default is never deleted).

    .OUTPUTS
        Array of view names that could NOT be automated at all (caller prints
        the manual instructions for those).
    #>
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][int]$Number,
        [string[]]$Phases,
        [switch]$DryRun
    )
    $manual = [System.Collections.Generic.List[string]]::new()

    $pathPrefix = if ($State.IsUser) { "users/$($State.UserDbId)" } else { "orgs/$Owner" }
    $layoutMap = @{ table = 'TABLE_LAYOUT'; board = 'BOARD_LAYOUT' }

    $statusField = Find-ProjectField -State $State -Name 'Status'
    $parentField = Find-ProjectField -State $State -Name 'Parent issue'
    $phaseField = if ($Phases -and $Phases.Count -gt 0) { Find-ProjectField -State $State -Name 'Phase' } else { $null }

    # Keep only well-formed view records (defensive against odd node shapes).
    $existingViews = @($State.Views | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['name'] })

    # (name, layout, groupByDbId, verticalGroupByDbId, filter, description, grouping hint)
    $desired = @(
        @{ Name = 'By Phase';     Layout = 'table'; Group = (Get-JsonProp $phaseField 'databaseId'); Vertical = $null; Filter = $null; Describe = 'table' + $(if ($phaseField) { ', grouped by Phase' } else { '' }); GroupingHint = $(if ($phaseField) { 'group by the Phase field' } else { $null }) }
        @{ Name = 'By Status';    Layout = 'board'; Group = $null; Vertical = (Get-JsonProp $statusField 'databaseId'); Filter = $null; Describe = 'board, grouped by Status'; GroupingHint = 'group board columns by Status' }
        @{ Name = 'By Epic';      Layout = 'board'; Group = $null; Vertical = (Get-JsonProp $parentField 'databaseId'); Filter = $null; Describe = 'board, grouped by Parent issue'; GroupingHint = 'group board columns by Parent issue' }
        @{ Name = 'Current work'; Layout = 'table'; Group = $null; Vertical = $null; Filter = 'is:open -label:blocked'; Describe = 'table, filtered to open unblocked items'; GroupingHint = $null }
    )

    $createdByPhase = $false
    foreach ($v in $desired) {
        $already = @($existingViews | Where-Object { $_.name -ieq $v.Name }) | Select-Object -First 1
        if ($already) {
            Write-Skip "View '$($v.Name)' already exists."
            continue
        }
        if ($DryRun) {
            Write-DryRun "Would create view '$($v.Name)' ($($v.Describe))."
            if ($v.Name -eq 'By Phase') { $createdByPhase = $true } # tracked for the View 1 delete message only
            continue
        }
        $groupDb = if ($v.Group) { [long]$v.Group } else { 0 }
        $vertDb = if ($v.Vertical) { [long]$v.Vertical } else { 0 }
        $created = $false
        try {
            Invoke-CreateViewRest -PathPrefix $pathPrefix -Number $Number -Name $v.Name -Layout $v.Layout -GroupByDbId $groupDb -VerticalGroupByDbId $vertDb -Filter $v.Filter
            $created = $true
        }
        catch {
            # The GraphQL fallback is reserved for REST UNAVAILABILITY (HTTP
            # 404/405 — e.g. user-owned projects today): a transient failure
            # (429/5xx/422) must NOT produce a permanently degraded view that
            # re-runs would skip — route those to the manual list instead.
            if ($_.Exception.Message -match 'HTTP 40[45]') {
                try {
                    Invoke-CreateViewGraphQl -ProjectId $State.ProjectId -Name $v.Name -GraphQlLayout $layoutMap[$v.Layout] -Filter $v.Filter
                    $created = $true
                    if ($v.GroupingHint) {
                        Write-Warning "View '$($v.Name)' created without grouping (REST view API unavailable): open the view once and set '$($v.GroupingHint)'."
                    }
                }
                catch {
                    Write-Warning "Failed to create view '$($v.Name)' via API: $($_.Exception.Message)"
                    $manual.Add($v.Name)
                }
            }
            else {
                Write-Warning "Transient REST failure creating view '$($v.Name)' ($($_.Exception.Message)); not falling back to the grouping-less GraphQL path."
                $manual.Add($v.Name)
            }
        }
        if ($created) {
            if ($v.Name -eq 'By Phase') { $createdByPhase = $true }
            Write-Ok "Created view '$($v.Name)' ($($v.Describe))."
            Start-Sleep -Milliseconds 500
        }
    }

    # Remove the untouched default "View 1" only when "By Phase" was created this run.
    $defaultView = @($existingViews | Where-Object { $_.name -eq 'View 1' }) | Select-Object -First 1
    if ($createdByPhase -and $defaultView) {
        if ($DryRun) {
            Write-DryRun "Would delete the default 'View 1' (replaced by 'By Phase') via deleteProjectV2View."
        }
        else {
            $delMutation = 'mutation($viewId: ID!) { deleteProjectV2View(input: { viewId: $viewId }) { projectV2View { id } } }'
            $ghArgs = @('api', 'graphql', '-f', "query=$delMutation", '-f', "viewId=$($defaultView.id)")
            try {
                Invoke-Gh @ghArgs | Out-Null
                Write-Ok "Deleted leftover default 'View 1' (replaced by 'By Phase')."
            }
            catch {
                Write-Warning "Created views but could not delete the default 'View 1': $($_.Exception.Message) (delete it once in the UI)."
            }
        }
    }

    return $manual
}

Initialize-Auth -DryRun:$DryRun

if (-not $Title) { $Title = (Get-RepoParts -Repo $Repo).Name }

# --- Locate or create the project ------------------------------------------
$existing = $null
try {
    $listed = Invoke-GhJson project list --owner $Owner --format json --limit 200
    $projects = Get-JsonProp $listed 'projects'
    if ($null -eq $projects) { $projects = $listed }
    $existing = @($projects | Where-Object { $_.title -eq $Title }) | Select-Object -First 1
}
catch {
    throw "Could not list existing projects: $($_.Exception.Message)"
}

$projectNumber = $null
if ($existing) {
    $projectNumber = [int]$existing.number
    Write-Skip "Project '$Title' already exists (#$projectNumber)."
}
else {
    if ($DryRun) {
        Write-DryRun "Would create project '$Title' under '$Owner' and link it to $Repo."
    }
    else {
        Write-Step "Creating project '$Title' under '$Owner'..."
        $created = Invoke-GhJson project create --owner $Owner --title $Title --format json
        $projectNumber = [int]$created.number
        Write-Ok "Created project #$projectNumber ($($created.url))"
        try {
            Invoke-Gh project link $projectNumber --owner $Owner --repo $Repo | Out-Null
            Write-Ok "Linked project #$projectNumber to $Repo"
        }
        catch {
            Write-Warning "Failed to link project to ${Repo}: $($_.Exception.Message). Link it manually."
        }
    }
}

# --- Ensure custom fields ---------------------------------------------------
$desiredFields = @(
    @{ Name = 'Level';    Type = 'SINGLE_SELECT'; Options = @('plan', 'epic', 'story', 'task') }
    @{ Name = 'Priority'; Type = 'SINGLE_SELECT'; Options = @('P0', 'P1', 'P2', 'P3') }
    @{ Name = 'Estimate'; Type = 'NUMBER';        Options = @() }
)
if ($Phases -and $Phases.Count -gt 0) {
    $desiredFields += @{ Name = 'Phase'; Type = 'SINGLE_SELECT'; Options = $Phases }
}

if ($null -eq $projectNumber) {
    Write-DryRun "Would ensure fields: $(( $desiredFields | ForEach-Object { $_.Name } ) -join ', ')."
    Write-DryRun 'Would ensure Status options: In Review, Blocked (added to the built-in Status field).'
    Write-DryRun 'Would create views: By Phase (table), By Status (board, grouped by Status), By Epic (board, grouped by Parent issue), Current work (open unblocked items).'
}
else {
    $existingFieldNames = @()
    try {
        $fieldData = Invoke-GhJson project field-list $projectNumber --owner $Owner --format json --limit 200
        $fields = Get-JsonProp $fieldData 'fields'
        if ($null -eq $fields) { $fields = $fieldData }
        $existingFieldNames = @($fields | ForEach-Object { $_.name })
    }
    catch {
        throw "Could not list project fields: $($_.Exception.Message)"
    }

    foreach ($f in $desiredFields) {
        if ($existingFieldNames -contains $f.Name) {
            Write-Skip "Field '$($f.Name)' already exists."
            continue
        }
        if ($DryRun) {
            Write-DryRun "Would create field '$($f.Name)' ($($f.Type))$(if ($f.Options.Count) { " [$($f.Options -join ', ')]" })."
            continue
        }
        Write-Step "Creating field '$($f.Name)' ($($f.Type))..."
        $fieldArgs = @('project', 'field-create', $projectNumber, '--owner', $Owner, '--name', $f.Name, '--data-type', $f.Type)
        if ($f.Type -eq 'SINGLE_SELECT') { $fieldArgs += @('--single-select-options', ($f.Options -join ',')) }
        Invoke-Gh @fieldArgs | Out-Null
        Write-Ok "Created field '$($f.Name)'."
    }

    # --- Ensure Status options + views (automated; manual fallback) ---------
    $state = Get-ProjectState -Repo $Repo -Number $projectNumber
    $manualStatus = $false
    $manualViews = @()
    if ($null -eq $state) {
        # API surface unavailable (GHES / older deployment): keep the run green,
        # print the manual instructions instead.
        $manualStatus = $true
        $manualViews = @('By Phase', 'By Status', 'By Epic', 'Current work')
    }
    else {
        $manualStatus = -not (Ensure-StatusOptions -State $state -DryRun:$DryRun)
        $manualViews = @(Ensure-Views -State $state -Owner $Owner -Number $projectNumber -Phases $Phases -DryRun:$DryRun)
    }

    if ($manualStatus) {
        Write-Skip "Note: could not automate the built-in 'Status' field options; ensure they include: Todo, In Progress, In Review, Blocked, Done (add any missing ones in the UI)."
    }
    if ($manualViews.Count -gt 0) {
        Write-Host ''
        Write-Step 'Views to create manually in the Project UI (could not be created via gh/API):'
        if ($manualViews -contains 'By Phase') { Write-Host '  - "By Phase"    : group by the Phase field' }
        if ($manualViews -contains 'By Status') { Write-Host '  - "By Status"   : board layout grouped by Status' }
        if ($manualViews -contains 'By Epic') { Write-Host '  - "By Epic"     : group by parent issue / Level = epic' }
        if ($manualViews -contains 'Current work') { Write-Host '  - "Current work": filter to open, unblocked items in the active phase/milestone' }
    }
}

# --- Emit project number on stdout so composing drivers can capture it via $() ---
# (Host-stream Write-* above are human-readable status; this is the machine-readable contract,
#  matching ensure-issue.ps1 which Write-Outputs its issue number.)
if ($null -ne $projectNumber) {
    Write-Output $projectNumber
}
