#!/usr/bin/env pwsh
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Pester v5 unit tests for ensure-project.ps1's Status-options merge and
    view-creation automation (the Projects v2 REST view API + GraphQL
    updateProjectV2Field / deleteProjectV2View paths), including the
    graceful fallback to printed manual instructions when the API surface
    is unavailable.

    Conventions (mirrors EnsureIssueAndProject.Tests.ps1):
    - Script path resolved INSIDE BeforeAll via $PSScriptRoot.
    - gh CLI mocked as `function global:gh` with ValueFromRemainingArguments;
      removed in AfterEach.
    - $global:LASTEXITCODE set per call by the gh mock (not reset in BeforeEach).
    - gh call tracking via $global:GhCallLog (mutations raw, REST POSTs raw,
      GraphQL reads prefixed 'READ ').
    - GraphQL reads/mutations share one stub distinguished by 'query=mutation'
      in the joined arguments; REST view creates are POST calls.
    - Write-Host output asserted via the information stream (6>&1).

    Run:  Invoke-Pester -Path .agents/skills/gh-issue-tracking-init/scripts/tests/EnsureProjectViews.Tests.ps1 -Output Detailed
#>

Describe 'ensure-project.ps1 — Status options and views automation' {
    BeforeAll {
        $ghitDir = Split-Path -Parent $PSScriptRoot
        $script:EnsureProjectScript = Join-Path $ghitDir 'ensure-project.ps1'

        # Helpers shared by every context: build the GraphQL read response the way
        # GitHub actually returns it. Defined INSIDE BeforeAll because Pester v5
        # does not preserve file-top definitions at block runtime.
        function New-TestOption {
            param([string]$Id, [string]$Name, [string]$Color = 'GRAY', [string]$Description = '')
            [pscustomobject]@{ id = $Id; name = $Name; color = $Color; description = $Description }
        }
        function New-TestField {
            param([string]$Name, [int]$DbId, [array]$Options = @())
            [pscustomobject]@{
                __typename = if ($Options.Count -gt 0) { 'ProjectV2SingleSelectField' } else { 'ProjectV2Field' }
                name       = $Name
                id         = 'PVT_' + ($Name -replace ' ', '_')
                databaseId = $DbId
                options    = $Options
            }
        }
        function New-TestReadResponse {
            param([array]$Fields, [array]$Views, [bool]$IsUser = $false, [int]$UserDbId = 0)
            $owner = [pscustomobject]@{
                __typename = if ($IsUser) { 'User' } else { 'Organization' }
                projectV2  = [pscustomobject]@{
                    id     = 'PVT_kwDOTESTPROJECT'
                    fields = [pscustomobject]@{
                        nodes    = $Fields
                        pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = $null }
                    }
                    views  = [pscustomobject]@{
                        nodes     = $Views
                        pageInfo  = [pscustomobject]@{ hasNextPage = $false; endCursor = $null }
                    }
                }
            }
            if ($IsUser) { $owner | Add-Member -NotePropertyName databaseId -NotePropertyValue $UserDbId }
            [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ owner = $owner } } } | ConvertTo-Json -Depth 12 -Compress
        }

        function Install-TestGhMock {
            <#.SYNOPSIS Install the shared gh mock. $global:ReadResponse drives the GraphQL read.#>
            $global:GhCallLog = [System.Collections.Generic.List[string]]::new()
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
                if ($cmd -eq 'project' -and $sub -eq 'list') { return '{"projects":[{"number":5,"title":"Test"}]}' }
                if ($cmd -eq 'project' -and $sub -eq 'field-list') {
                    return '{"fields":[{"name":"Title"},{"name":"Status"},{"name":"Level"},{"name":"Priority"},{"name":"Estimate"}]}'
                }
                if ($cmd -eq 'api') {
                    $q = $Arguments -join ' '
                    if ($sub -eq 'graphql') {
                        if ($q -match 'query=mutation') {
                            $global:GhCallLog.Add($q)
                            if ($q -match 'createProjectV2View') { return '{"data":{"createProjectV2View":{"projectV2View":{"id":"PVTV_new"}}}}' }
                            return '{"data":{}}'
                        }
                        $global:GhCallLog.Add('READ ' + $q)
                        return $global:ReadResponse
                    }
                    if ($Arguments -contains 'POST') { $global:GhCallLog.Add($q); return '{"id":11,"number":9}' }
                    return
                }
            }
        }

        function Remove-TestGhMock {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Variable -Name GhCallLog, ReadResponse -Scope Global -ErrorAction SilentlyContinue
        }
    }

    Context 'apply — full automation on an org project' {
        BeforeAll {
            $defaultOptions = @(
                (New-TestOption 't1' 'Todo' 'GREEN' 'not started')
                (New-TestOption 'i1' 'In Progress' 'YELLOW' 'wip')
                (New-TestOption 'd1' 'Done' 'PURPLE' 'done')
            )
            $fields = @(
                (New-TestField 'Title' 329)
                (New-TestField 'Status' 345 $defaultOptions)
                (New-TestField 'Parent issue' 358)
                (New-TestField 'Level' 347)
                (New-TestField 'Priority' 355)
                (New-TestField 'Estimate' 375)
            )
            $views = @([pscustomobject]@{ id = 'PVTV_1'; number = 1; name = 'View 1'; layout = 'TABLE_LAYOUT' })
            $script:ReadResponseJson = New-TestReadResponse -Fields $fields -Views $views
        }
        BeforeEach {
            $global:ReadResponse = $script:ReadResponseJson
            Install-TestGhMock
        }
        AfterEach { Remove-TestGhMock }

        It 'outputs the project number' {
            # Without 6>&1 the host stream stays separate; stdout carries only the number.
            $out = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test'
            $out | Should -Be 5
        }

        It 'merges Status options preserving existing option ids and descriptions' {
            & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1 | Out-Null
            $mutation = @($global:GhCallLog | Where-Object { $_ -match 'updateProjectV2Field' })
            $mutation.Count | Should -Be 1
            $mutation[0] | Should -Match 'In Review'
            $mutation[0] | Should -Match 'Blocked'
            # Existing options keep their identity and current styling (id + echoed color/description).
            $mutation[0] | Should -Match 'id: "t1", name: "Todo", color: GREEN, description: "not started"'
            $mutation[0] | Should -Match 'id: "i1"'
            $mutation[0] | Should -Match 'id: "d1"'
            # New options are inserted in canonical order without ids.
            $mutation[0].IndexOf('In Review') | Should -BeLessThan $mutation[0].IndexOf('"Done"')
        }

        It 'creates the four views with correct grouping and filter' {
            & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1 | Out-Null
            $posts = @($global:GhCallLog | Where-Object { $_ -match 'POST' })
            $posts.Count | Should -Be 4
            ($posts | Where-Object { $_ -match 'name=By Phase' }) | Should -Match 'layout=table'
            ($posts | Where-Object { $_ -match 'name=By Phase' }) | Should -Not -Match 'group_by'
            ($posts | Where-Object { $_ -match 'name=By Status' }) | Should -Match 'layout=board'
            ($posts | Where-Object { $_ -match 'name=By Status' }) | Should -Match 'vertical_group_by\[\]=345'
            ($posts | Where-Object { $_ -match 'name=By Epic' }) | Should -Match 'vertical_group_by\[\]=358'
            ($posts | Where-Object { $_ -match 'name=Current work' }) | Should -Match 'layout=table'
            ($posts | Where-Object { $_ -match 'name=Current work' }) | Should -Match 'filter=is:open -label:blocked'
        }

        It 'posts to the org REST path with the API version header' {
            & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1 | Out-Null
            $posts = @($global:GhCallLog | Where-Object { $_ -match 'POST' })
            $posts | Should -Not -BeNullOrEmpty
            ($posts | Where-Object { $_ -notmatch 'orgs/o/projectsV2/5/views' }).Count | Should -Be 0
            ($posts | Where-Object { $_ -notmatch 'X-GitHub-Api-Version: 2026-03-10' }).Count | Should -Be 0
        }

        It 'deletes the leftover default View 1 after creating By Phase' {
            & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1 | Out-Null
            $delete = @($global:GhCallLog | Where-Object { $_ -match 'deleteProjectV2View' })
            $delete.Count | Should -Be 1
            $delete[0] | Should -Match 'viewId=PVTV_1'
        }
    }

    Context 'apply — Status already complete and views already exist (idempotent re-run)' {
        BeforeAll {
            $completeOptions = @(
                (New-TestOption 't1' 'Todo')
                (New-TestOption 'i1' 'In Progress')
                (New-TestOption 'r1' 'In Review')
                (New-TestOption 'b1' 'Blocked')
                (New-TestOption 'd1' 'Done')
            )
            $fields = @(
                (New-TestField 'Status' 345 $completeOptions)
                (New-TestField 'Parent issue' 358)
            )
            $views = @(
                [pscustomobject]@{ id = 'PVTV_1'; number = 1; name = 'By Phase'; layout = 'TABLE_LAYOUT' }
                [pscustomobject]@{ id = 'PVTV_2'; number = 2; name = 'By Status'; layout = 'BOARD_LAYOUT' }
                [pscustomobject]@{ id = 'PVTV_3'; number = 3; name = 'By Epic'; layout = 'BOARD_LAYOUT' }
                [pscustomobject]@{ id = 'PVTV_4'; number = 4; name = 'Current work'; layout = 'TABLE_LAYOUT' }
            )
            $script:ReadResponseJson = New-TestReadResponse -Fields $fields -Views $views
        }
        BeforeEach {
            $global:ReadResponse = $script:ReadResponseJson
            Install-TestGhMock
        }
        AfterEach { Remove-TestGhMock }

        It 'makes no mutations at all' {
            $out = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1
            $out | Should -Contain 5
            ($global:GhCallLog | Where-Object { $_ -match 'query=mutation' }).Count | Should -Be 0
            ($global:GhCallLog | Where-Object { $_ -match 'POST' }).Count | Should -Be 0
        }

        It 'reports the skip on host output' {
            $all = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1
            (@($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] -and "$_" -match 'Status options already complete' })).Count | Should -Be 1
            (@($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] -and "$_" -match "View 'By Status' already exists" })).Count | Should -Be 1
        }
    }

    Context 'DryRun — existing project makes no mutations' {
        BeforeAll {
            $defaultOptions = @(
                (New-TestOption 't1' 'Todo')
                (New-TestOption 'i1' 'In Progress')
                (New-TestOption 'd1' 'Done')
            )
            $fields = @(
                (New-TestField 'Status' 345 $defaultOptions)
                (New-TestField 'Parent issue' 358)
            )
            $views = @([pscustomobject]@{ id = 'PVTV_1'; number = 1; name = 'View 1'; layout = 'TABLE_LAYOUT' })
            $script:ReadResponseJson = New-TestReadResponse -Fields $fields -Views $views
        }
        BeforeEach {
            $global:ReadResponse = $script:ReadResponseJson
            Install-TestGhMock
        }
        AfterEach { Remove-TestGhMock }

        It 'prints would-actions and performs zero mutations' {
            $all = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' -DryRun 6>&1 3>&1
            $info = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
            (@($info | Where-Object { "$_" -match 'Would add Status option\(s\): In Review, Blocked' })).Count | Should -Be 1
            (@($info | Where-Object { "$_" -match "Would create view 'By Status'" })).Count | Should -Be 1
            (@($info | Where-Object { "$_" -match "Would delete the default 'View 1'" })).Count | Should -Be 1
            ($global:GhCallLog | Where-Object { $_ -match 'query=mutation' }).Count | Should -Be 0
            ($global:GhCallLog | Where-Object { $_ -match 'POST' }).Count | Should -Be 0
        }
    }

    Context 'fallback — GraphQL surface unavailable' {
        BeforeEach {
            Install-TestGhMock
            $global:ReadResponse = $null   # read returns nothing -> state unavailable
        }
        AfterEach { Remove-TestGhMock }

        It 'prints the manual instructions and still exits green with the project number' {
            $all = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1
            $info = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" })
            (@($info | Where-Object { $_ -match 'could not automate the built-in .Status. field options' })).Count | Should -Be 1
            (@($info | Where-Object { $_ -match 'Views to create manually in the Project UI' })).Count | Should -Be 1
            (@($info | Where-Object { $_ -match 'By Status' })).Count | Should -Be 1
            (@($info | Where-Object { $_ -match 'Current work' })).Count | Should -Be 1
            $all | Should -Contain 5
        }

        It 'attempts exactly one GraphQL read and no mutations' {
            & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1 | Out-Null
            (@($global:GhCallLog | Where-Object { $_ -match '^READ ' })).Count | Should -Be 1
            ($global:GhCallLog | Where-Object { $_ -match 'query=mutation' }).Count | Should -Be 0
            ($global:GhCallLog | Where-Object { $_ -match 'POST' }).Count | Should -Be 0
        }
    }

    Context 'user-owned project — REST path uses the numeric user id' {
        BeforeAll {
            $defaultOptions = @(
                (New-TestOption 't1' 'Todo')
                (New-TestOption 'i1' 'In Progress')
                (New-TestOption 'd1' 'Done')
            )
            $fields = @(
                (New-TestField 'Status' 345 $defaultOptions)
                (New-TestField 'Parent issue' 358)
            )
            $views = @()
            # -Views @(): a literal empty array binds as one argument (a bare
            # $views VARIABLE would unroll); -IsUser:$true because a [bool]
            # param (not a [switch]) requires an explicit value when named.
            $script:ReadResponseJson = New-TestReadResponse -Fields $fields -Views @() -IsUser:$true -UserDbId 1829396
        }
        BeforeEach {
            $global:ReadResponse = $script:ReadResponseJson
            Install-TestGhMock
        }
        AfterEach { Remove-TestGhMock }

        It 'posts view creates under /users/{id}/projectsV2' {
            & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1 | Out-Null
            $posts = @($global:GhCallLog | Where-Object { $_ -match 'POST' })
            $posts.Count | Should -Be 4
            ($posts | Where-Object { $_ -notmatch 'users/1829396/projectsV2/5/views' }).Count | Should -Be 0
        }
    }

    Context 'options merge — extras preserved, missing appended' {
        BeforeAll {
            $options = @(
                (New-TestOption 't1' 'Todo' 'GREEN' 'a')
                (New-TestOption 'i1' 'In Progress' 'YELLOW' 'b')
                (New-TestOption 'd1' 'Done' 'PURPLE' 'c')
                (New-TestOption 'x1' 'On Hold' 'PINK' 'custom extra')
            )
            $fields = @(
                (New-TestField 'Status' 345 $options)
                (New-TestField 'Parent issue' 358)
            )
            $views = @([pscustomobject]@{ id = 'PVTV_1'; number = 1; name = 'View 1'; layout = 'TABLE_LAYOUT' })
            $script:ReadResponseJson = New-TestReadResponse -Fields $fields -Views $views
        }
        BeforeEach {
            $global:ReadResponse = $script:ReadResponseJson
            Install-TestGhMock
        }
        AfterEach { Remove-TestGhMock }

        It 'keeps the extra option with its id and styling, appended after canonical options' {
            & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1 | Out-Null
            $mutation = @($global:GhCallLog | Where-Object { $_ -match 'updateProjectV2Field' })[0]
            $mutation | Should -Match 'id: "x1", name: "On Hold", color: PINK, description: "custom extra"'
            $mutation.IndexOf('On Hold') | Should -BeGreaterThan $mutation.IndexOf('"Done"')
        }
    }

    Context 'defensive — Status options without ids fall back to manual note only' {
        BeforeAll {
            # Options missing ids: identity cannot be preserved -> refuse to automate the merge.
            $options = @(
                [pscustomobject]@{ name = 'Todo'; color = 'GREEN'; description = '' }
                [pscustomobject]@{ name = 'In Progress'; color = 'YELLOW'; description = '' }
            )
            $fields = @(
                (New-TestField 'Status' 345 $options)
                (New-TestField 'Parent issue' 358)
            )
            $views = @([pscustomobject]@{ id = 'PVTV_1'; number = 1; name = 'View 1'; layout = 'TABLE_LAYOUT' })
            $script:ReadResponseJson = New-TestReadResponse -Fields $fields -Views $views
        }
        BeforeEach {
            $global:ReadResponse = $script:ReadResponseJson
            Install-TestGhMock
        }
        AfterEach { Remove-TestGhMock }

        It 'prints the Status manual note but still automates the views' {
            $all = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1
            $info = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" })
            (@($info | Where-Object { $_ -match 'could not automate the built-in .Status. field options' })).Count | Should -Be 1
            (@($info | Where-Object { $_ -match 'Views to create manually' })).Count | Should -Be 0
            ($global:GhCallLog | Where-Object { $_ -match 'updateProjectV2Field' }).Count | Should -Be 0
            ($global:GhCallLog | Where-Object { $_ -match 'POST' }).Count | Should -Be 4
        }
    }

    Context 'view create failure — warns and prints manual note for that view only' {
        BeforeAll {
            $defaultOptions = @(
                (New-TestOption 't1' 'Todo')
                (New-TestOption 'i1' 'In Progress')
                (New-TestOption 'd1' 'Done')
            )
            $fields = @(
                (New-TestField 'Status' 345 $defaultOptions)
                (New-TestField 'Parent issue' 358)
            )
            $views = @([pscustomobject]@{ id = 'PVTV_1'; number = 1; name = 'View 1'; layout = 'TABLE_LAYOUT' })
            $script:ReadResponseJson = New-TestReadResponse -Fields $fields -Views $views
        }
        BeforeEach {
            $global:ReadResponse = $script:ReadResponseJson
            Install-TestGhMock
            # Wrap the installed mock: BOTH the REST create (HTTP 404 ->
            # fallback gate open) and the GraphQL fallback fail for "By Status"
            # (total-failure path -> manual note).
            $inner = (Get-Command gh -CommandType Function).ScriptBlock
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $joined = $Arguments -join ' '
                if (($Arguments -contains 'POST') -and $joined -match 'name=By Status') {
                    $global:LASTEXITCODE = 1
                    return 'gh: Not Found (HTTP 404)'
                }
                if ($Arguments -contains 'graphql' -and $joined -match 'createProjectV2View' -and $joined -match 'name=By Status') {
                    $global:LASTEXITCODE = 1
                    return 'simulated graphql failure'
                }
                & $inner @Arguments
            }
        }
        AfterEach { Remove-TestGhMock }

        It 'creates the other views, deletes View 1, and prints the manual line for By Status' {
            $all = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1
            $warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            (@($warnings | Where-Object { $_.Message -match "Failed to create view 'By Status'" })).Count | Should -Be 1
            # The other three views created, and the default View 1 cleanup still runs.
            (@($global:GhCallLog | Where-Object { $_ -match 'deleteProjectV2View' })).Count | Should -Be 1
            # The wrapper short-circuits both failing calls before the shared mock
            # logs them, so exactly the three successful REST creates appear.
            $posts = @($global:GhCallLog | Where-Object { $_ -match 'POST' })
            $posts.Count | Should -Be 3
            ($posts | Where-Object { $_ -match 'name=By Status' }).Count | Should -Be 0
            $info = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" })
            (@($info | Where-Object { $_ -match 'Views to create manually' })).Count | Should -Be 1
            (@($info | Where-Object { $_ -match 'board layout grouped by Status' })).Count | Should -Be 1
        }
    }

    Context 'Phases supplied — By Phase groups by the Phase field' {
        BeforeAll {
            $defaultOptions = @(
                (New-TestOption 't1' 'Todo')
                (New-TestOption 'i1' 'In Progress')
                (New-TestOption 'd1' 'Done')
            )
            $fields = @(
                (New-TestField 'Status' 345 $defaultOptions)
                (New-TestField 'Parent issue' 358)
                (New-TestField 'Phase' 999 @((New-TestOption 'p1' 'Current'), (New-TestOption 'p2' 'Future')))
            )
            $views = @([pscustomobject]@{ id = 'PVTV_1'; number = 1; name = 'View 1'; layout = 'TABLE_LAYOUT' })
            $script:ReadResponseJson = New-TestReadResponse -Fields $fields -Views $views
        }
        BeforeEach {
            $global:ReadResponse = $script:ReadResponseJson
            Install-TestGhMock
        }
        AfterEach { Remove-TestGhMock }

        It 'sends group_by with the Phase field db id on the By Phase create' {
            & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' -Phases 'Current', 'Future' 6>&1 3>&1 | Out-Null
            $phasePost = @($global:GhCallLog | Where-Object { $_ -match 'POST' -and $_ -match 'name=By Phase' })[0]
            $phasePost | Should -Match 'group_by\[\]=999'
        }
    }

    Context 'REST view API unavailable — GraphQL fallback' {
        BeforeAll {
            $defaultOptions = @(
                (New-TestOption 't1' 'Todo')
                (New-TestOption 'i1' 'In Progress')
                (New-TestOption 'd1' 'Done')
            )
            $fields = @(
                (New-TestField 'Status' 345 $defaultOptions)
                (New-TestField 'Parent issue' 358)
            )
            $views = @([pscustomobject]@{ id = 'PVTV_1'; number = 1; name = 'View 1'; layout = 'TABLE_LAYOUT' })
            $script:ReadResponseJson = New-TestReadResponse -Fields $fields -Views $views -IsUser:$true -UserDbId 1829396
        }
        BeforeEach {
            $global:ReadResponse = $script:ReadResponseJson
            Install-TestGhMock
            # Wrap the installed mock: every REST POST fails with an HTTP 404
            # (unavailability), as user-owned projects do today — this is what
            # gates the GraphQL create fallback.
            $inner = (Get-Command gh -CommandType Function).ScriptBlock
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                if ($Arguments -contains 'POST' -and ($Arguments -join ' ') -notmatch 'graphql') {
                    $global:LASTEXITCODE = 1
                    return 'gh: Not Found (HTTP 404)'
                }
                & $inner @Arguments
            }
        }
        AfterEach { Remove-TestGhMock }

        It 'creates all four views via GraphQL, sets the filter, warns about grouping, and deletes View 1' {
            $all = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1
            $creates = @($global:GhCallLog | Where-Object { $_ -match 'createProjectV2View' })
            $creates.Count | Should -Be 4
            ($creates | Where-Object { $_ -match 'name=By Status' -and $_ -match 'layout=BOARD_LAYOUT' }).Count | Should -Be 1
            ($creates | Where-Object { $_ -match 'name=By Phase' -and $_ -match 'layout=TABLE_LAYOUT' }).Count | Should -Be 1
            ($creates | Where-Object { $_ -match 'projectId=PVT_kwDOTESTPROJECT' }).Count | Should -Be 4
            # Current work's filter is applied via updateProjectV2View.
            ($global:GhCallLog | Where-Object { $_ -match 'updateProjectV2View' -and $_ -match 'is:open -label:blocked' }).Count | Should -Be 1
            # Grouped boards (By Status, By Epic) warn about missing grouping; By Phase (no Phase field here) does not.
            $warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            (@($warnings | Where-Object { $_.Message -match "created without grouping" })).Count | Should -Be 2
            # View 1 still deleted; nothing falls into the manual block.
            ($global:GhCallLog | Where-Object { $_ -match 'deleteProjectV2View' }).Count | Should -Be 1
            $info = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" })
            (@($info | Where-Object { $_ -match 'Views to create manually' })).Count | Should -Be 0
        }
    }

    Context 'transient REST failure — no GraphQL fallback, manual note instead' {
        BeforeAll {
            $defaultOptions = @(
                (New-TestOption 't1' 'Todo')
                (New-TestOption 'i1' 'In Progress')
                (New-TestOption 'd1' 'Done')
            )
            $fields = @(
                (New-TestField 'Status' 345 $defaultOptions)
                (New-TestField 'Parent issue' 358)
            )
            $views = @([pscustomobject]@{ id = 'PVTV_1'; number = 1; name = 'View 1'; layout = 'TABLE_LAYOUT' })
            $script:ReadResponseJson = New-TestReadResponse -Fields $fields -Views $views
        }
        BeforeEach {
            $global:ReadResponse = $script:ReadResponseJson
            Install-TestGhMock
            # A 5xx must NOT open the 404-gated fallback: degraded grouping-less
            # creates would be permanent (re-runs skip existing views).
            $inner = (Get-Command gh -CommandType Function).ScriptBlock
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                if ($Arguments -contains 'POST') {
                    $global:LASTEXITCODE = 1
                    return 'gh: Server Error (HTTP 500)'
                }
                & $inner @Arguments
            }
        }
        AfterEach { Remove-TestGhMock }

        It 'routes every view to the manual list without any GraphQL creates' {
            $all = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1
            $warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            (@($warnings | Where-Object { $_.Message -match 'Transient REST failure' })).Count | Should -Be 4
            ($global:GhCallLog | Where-Object { $_ -match 'createProjectV2View' }).Count | Should -Be 0
            ($global:GhCallLog | Where-Object { $_ -match 'deleteProjectV2View' }).Count | Should -Be 0
            $info = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" })
            (@($info | Where-Object { $_ -match 'Views to create manually' })).Count | Should -Be 1
            (@($info | Where-Object { $_ -match 'By Status' })).Count | Should -Be 1
        }
    }

    Context 'GraphQL read failure — full manual fallback, run stays green' {
        BeforeAll {
            $fields = @()
            $views = @()
            $script:ReadResponseJson = New-TestReadResponse -Fields $fields -Views $views
        }
        BeforeEach {
            $global:ReadResponse = $script:ReadResponseJson
            Install-TestGhMock
            # The read itself fails (network/GHES): Invoke-Gh throws ->
            # Get-ProjectState catch -> $null -> manual instructions.
            $inner = (Get-Command gh -CommandType Function).ScriptBlock
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $joined = $Arguments -join ' '
                if ($Arguments -contains 'graphql' -and $joined -notmatch 'query=mutation') {
                    $global:LASTEXITCODE = 1
                    return 'gh: socket hang up'
                }
                & $inner @Arguments
            }
        }
        AfterEach { Remove-TestGhMock }

        It 'prints manual instructions for options and views, performs zero mutations, exits with the number' {
            $all = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1
            $info = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" })
            (@($info | Where-Object { $_ -match 'could not automate the built-in .Status. field options' })).Count | Should -Be 1
            (@($info | Where-Object { $_ -match 'Views to create manually' })).Count | Should -Be 1
            ($global:GhCallLog | Where-Object { $_ -match 'query=mutation' }).Count | Should -Be 0
            ($global:GhCallLog | Where-Object { $_ -match 'POST' }).Count | Should -Be 0
            $all | Should -Contain 5
        }
    }

    Context 'view pagination — second page views are honored' {
        BeforeAll {
            $defaultOptions = @(
                (New-TestOption 't1' 'Todo')
                (New-TestOption 'i1' 'In Progress')
                (New-TestOption 'd1' 'Done')
            )
            $fields = @(
                (New-TestField 'Status' 345 $defaultOptions)
                (New-TestField 'Parent issue' 358)
            )
            $page1Views = @([pscustomobject]@{ id = 'PVTV_1'; number = 1; name = 'View 1'; layout = 'TABLE_LAYOUT' })
            $page2Views = @([pscustomobject]@{ id = 'PVTV_9'; number = 9; name = 'By Status'; layout = 'BOARD_LAYOUT' })
            $makePage = {
                param($Nodes, $HasNext, $Cursor)
                $owner = [pscustomobject]@{
                    __typename = 'Organization'
                    projectV2  = [pscustomobject]@{
                        id     = 'PVT_kwDOTESTPROJECT'
                        fields = [pscustomobject]@{
                            nodes    = $fields
                            pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = $null }
                        }
                        views  = [pscustomobject]@{
                            nodes    = $Nodes
                            pageInfo = [pscustomobject]@{ hasNextPage = $HasNext; endCursor = $Cursor }
                        }
                    }
                }
                [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ owner = $owner } } } | ConvertTo-Json -Depth 12 -Compress
            }
            # Scriptblock closure over $fields/$page1Views/$page2Views won't survive
            # Pester scoping; build the two payloads eagerly instead.
            $script:Page1 = & $makePage $page1Views $true 'CURSOR_2'
            $script:Page2 = & $makePage $page2Views $false $null
        }
        BeforeEach {
            Install-TestGhMock
            # Serve page 1 first, then page 2 (stateful via globals; Pester
            # fixture scoping makes $script: unreliable inside the wrapper).
            $global:PaginationPage2 = $script:Page2
            $global:ReadResponse = $script:Page1
            $inner = (Get-Command gh -CommandType Function).ScriptBlock
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                $joined = $Arguments -join ' '
                if ($Arguments -contains 'graphql' -and $joined -notmatch 'query=mutation') {
                    if ($joined -match 'viewCursor=CURSOR_2') { return $global:PaginationPage2 }
                    return $global:ReadResponse
                }
                & $inner @Arguments
            }
        }
        AfterEach {
            Remove-TestGhMock
            Remove-Variable -Name PaginationPage1, PaginationPage2, PageFlip -Scope Global -ErrorAction SilentlyContinue
        }

        It 'sees By Status on page 2 and skips creating it' {
            $all = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1
            ($global:GhCallLog | Where-Object { $_ -match 'POST' -and $_ -match 'name=By Status' }).Count | Should -Be 0
            $info = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" })
            (@($info | Where-Object { $_ -match "View 'By Status' already exists" })).Count | Should -Be 1
            # Other three views still created; View 1 cleanup still runs.
            ($global:GhCallLog | Where-Object { $_ -match 'POST' }).Count | Should -Be 3
            ($global:GhCallLog | Where-Object { $_ -match 'deleteProjectV2View' }).Count | Should -Be 1
        }
    }

    Context 'fields pagination — second page fields are honored' {
        BeforeAll {
            $defaultOptions = @(
                (New-TestOption 't1' 'Todo')
                (New-TestOption 'i1' 'In Progress')
                (New-TestOption 'd1' 'Done')
            )
            # Status (with its options) only arrives on fields page 2; page 1
            # carries Title + Parent issue. A single-page read would miss Status
            # entirely: no option merge and no By Status board grouping.
            $page1Fields = @(
                (New-TestField 'Title' 329)
                (New-TestField 'Parent issue' 358)
            )
            $page2Fields = @(
                (New-TestField 'Status' 345 $defaultOptions)
            )
            $views = @([pscustomobject]@{ id = 'PVTV_1'; number = 1; name = 'View 1'; layout = 'TABLE_LAYOUT' })
            $makePage = {
                param($FieldNodes, $FieldsHasNext, $FieldsCursor)
                $owner = [pscustomobject]@{
                    __typename = 'Organization'
                    projectV2  = [pscustomobject]@{
                        id     = 'PVT_kwDOTESTPROJECT'
                        fields = [pscustomobject]@{
                            nodes    = $FieldNodes
                            pageInfo = [pscustomobject]@{ hasNextPage = $FieldsHasNext; endCursor = $FieldsCursor }
                        }
                        views  = [pscustomobject]@{
                            nodes    = $views
                            pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = $null }
                        }
                    }
                }
                [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ owner = $owner } } } | ConvertTo-Json -Depth 12 -Compress
            }
            # Eagerly built: scriptblock closures over fixture vars don't survive Pester scoping.
            # Page 2 redelivers the page-1 views (views connection is already exhausted
            # by then), pinning that a finished connection's nodes are never appended twice.
            $script:FieldsPage1 = & $makePage $page1Fields $true 'FCURSOR_2'
            $script:FieldsPage2 = & $makePage $page2Fields $false $null
        }
        BeforeEach {
            Install-TestGhMock
            $global:FieldsPaginationPage2 = $script:FieldsPage2
            $global:ReadResponse = $script:FieldsPage1
            $inner = (Get-Command gh -CommandType Function).ScriptBlock
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                $joined = $Arguments -join ' '
                if ($Arguments -contains 'graphql' -and $joined -notmatch 'query=mutation') {
                    if ($joined -match 'fieldCursor=FCURSOR_2') {
                        # Log like the inner mock does, so the cursor request is assertable.
                        $global:GhCallLog.Add('READ ' + $joined)
                        return $global:FieldsPaginationPage2
                    }
                    return $global:ReadResponse
                }
                & $inner @Arguments
            }
        }
        AfterEach {
            Remove-TestGhMock
            Remove-Variable -Name FieldsPaginationPage2 -Scope Global -ErrorAction SilentlyContinue
        }

        It 'requests the second fields page with the cursor' {
            & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1 | Out-Null
            ($global:GhCallLog | Where-Object { $_ -match '^READ ' -and $_ -match 'fieldCursor=FCURSOR_2' }).Count | Should -Be 1
        }

        It 'merges Status options found only on fields page 2, preserving ids' {
            & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1 | Out-Null
            $mutation = @($global:GhCallLog | Where-Object { $_ -match 'updateProjectV2Field' })
            $mutation.Count | Should -Be 1
            $mutation[0] | Should -Match 'fieldId=PVT_Status'
            $mutation[0] | Should -Match 'In Review'
            $mutation[0] | Should -Match 'Blocked'
            $mutation[0] | Should -Match 'id: "t1"'
            $mutation[0] | Should -Match 'id: "i1"'
            $mutation[0] | Should -Match 'id: "d1"'
        }

        It 'groups the By Status board by the page-2 Status field and does not double-append redelivered views' {
            $all = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 6>&1 3>&1
            ($global:GhCallLog | Where-Object { $_ -match 'POST' -and $_ -match 'name=By Status' }) | Should -Match 'vertical_group_by\[\]=345'
            ($global:GhCallLog | Where-Object { $_ -match 'POST' }).Count | Should -Be 4
            # View 1 arrived on both read pages; the leftover-delete must still fire exactly once.
            $delete = @($global:GhCallLog | Where-Object { $_ -match 'deleteProjectV2View' })
            $delete.Count | Should -Be 1
            $delete[0] | Should -Match 'viewId=PVTV_1'
            $info = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" })
            (@($info | Where-Object { $_ -match 'could not automate the built-in .Status. field options' })).Count | Should -Be 0
        }
    }

    Context 'DryRun — project missing prints would-actions for options and views' {
        BeforeEach {
            Install-TestGhMock
        }
        AfterEach { Remove-TestGhMock }

        It 'emits nothing to stdout and announces the planned automation' {
            $global:ReadResponse = $null
            $all = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Other' -DryRun 6>&1 3>&1
            # project list mock returns 'Test' only -> 'Other' not found -> no project number output
            $stdout = @($all | Where-Object { $_ -is [int] -or $_ -is [string] })
            # Host messages are InformationRecords; integers on stdout: none expected.
            (@($stdout | Where-Object { $_ -is [int] })).Count | Should -Be 0
            $info = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" })
            (@($info | Where-Object { $_ -match 'Would ensure Status options' })).Count | Should -Be 1
            (@($info | Where-Object { $_ -match 'Would create views' })).Count | Should -Be 1
        }
    }
}
