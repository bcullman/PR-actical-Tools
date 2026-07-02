[CmdletBinding(DefaultParameterSetName = 'ConfigPath')]
param(
    [Parameter(ParameterSetName = 'ConfigPath')]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.yml'),

    [Parameter(Mandatory = $true, ParameterSetName = 'Direct')]
    [string]$Org,

    [Parameter(ParameterSetName = 'Direct')]
    [string]$Pat,

    [Parameter(ParameterSetName = 'Direct')]
    [object[]]$Projects = @(),

    [ValidateSet('Created', 'Approved', 'Commented', 'All')]
    [string[]]$View = @('All'),

    [ValidateSet('completed', 'abandoned', 'all')]
    [string]$Status = 'all',

    [datetime]$Since = (Get-Date).AddDays(-90),

    [int]$Days,

    [int]$MaxPerProject = 500
)

function ConvertTo-AzDOLocalDateTime {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }

    $date=[datetime]$Value

    if ($date.Kind -eq [DateTimeKind]::Local) { return $date }
    if ($date.Kind -eq [DateTimeKind]::Utc) { return $date.ToLocalTime() }

    [DateTime]::SpecifyKind($date, [DateTimeKind]::Utc).ToLocalTime()
}

function Format-RelativeTime {
    param([AllowNull()][datetime]$DateTime)

    if (-not $DateTime) { return 'unknown' }

    $DateTime=ConvertTo-AzDOLocalDateTime $DateTime
    $now=Get-Date
    $span=$now-$DateTime

    if ($span.TotalMinutes -lt 1) { return 'just now' }
    if ($span.TotalHours -lt 1) { return "$([math]::Floor($span.TotalMinutes))m ago" }
    if ($span.TotalDays -lt 1) { return "$([math]::Floor($span.TotalHours))h ago" }
    if ($span.TotalDays -lt 30) { return "$([math]::Floor($span.TotalDays))d ago" }
    if ($span.TotalDays -lt 365) { return "$([math]::Floor($span.TotalDays/30))mo ago" }

    "$([math]::Floor($span.TotalDays/365))y ago"
}

function Get-AzDOStyle {
    $esc=[char]27

    [pscustomobject]@{
        Reset="$esc[0m";
        Dim="$esc[2m";
        ClearLine="$esc[0K";
        Cyan="$esc[38;2;0;255;255m";
        Purple="$esc[38;2;140;107;200m";
        White="$esc[38;2;255;255;255m";
        Green="$esc[38;2;85;163;98m";
        Orange="$esc[38;2;214;118;40m";
        Red="$esc[38;2;205;74;69m";
    }
}

function Get-AzDOConsoleWidth {
    try {
        if ([Console]::WindowWidth -gt 0) { return [Console]::WindowWidth }
    } catch {
    }

    120
}

function Get-AzDOComparable {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }

    $text=[string]$Value

    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $text.Trim().ToLowerInvariant()
}

function Read-AzDOConfig {
    param([string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config file '$ConfigPath' does not exist." }

    $ext=[IO.Path]::GetExtension($ConfigPath).ToLowerInvariant()

    if ($ext -notin '.yml','.yaml') {
        throw "Unsupported config file extension '$ext'. Supported extensions are .yml and .yaml."
    }

    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        throw "YAML config requires ConvertFrom-Yaml to be available in this PowerShell session."
    }

    Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Yaml
}

function Get-AzDOConfigCollection {
    param(
        [string]$ConfigPath,
        [string]$Org,
        [string]$Pat,
        [object[]]$Projects,
        [bool]$IsDirect
    )

    if ($IsDirect) {
        return @(
            [pscustomobject]@{
                Name = $Org;
                Pat = $Pat;
                Enabled = $true;
                Projects = @(@($Projects) | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)});
                FromConfig = $false
            }
        )
    }

    $parsed=Read-AzDOConfig -ConfigPath $ConfigPath
    $orgs=if ($parsed.organizations) {
        @($parsed.organizations)
    } elseif ($parsed -is [System.Collections.IEnumerable] -and $parsed -isnot [string]) {
        @($parsed)
    } else {
        @($parsed)
    }

    @(
        $orgs | ForEach-Object {
            [pscustomobject]@{
                Name = if ($_.name) { $_.name } else { $_.org };
                Pat = $_.pat;
                Enabled = if ($null -ne $_.enabled) { [bool]$_.enabled } else { $true };
                Projects = @(@($_.projects) | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)});
                FromConfig = $true
            }
        }
    )
}

function Resolve-AzDOPat {
    param(
        [object]$PatSpec,
        [string]$OrganizationName
    )

    if ($PatSpec -is [string] -and -not [string]::IsNullOrWhiteSpace($PatSpec)) {
        if ($PatSpec -match '^(?:\$env:|env:)(.+)$') {
            $PatSpec=[pscustomobject]@{ env = $Matches[1] }
        } else {
            return $PatSpec
        }
    }

    if ($PatSpec.value) { return $PatSpec.value }

    if ($PatSpec.env) {
        $token=[Environment]::GetEnvironmentVariable($PatSpec.env)

        if ([string]::IsNullOrWhiteSpace($token)) {
            throw "PAT environment variable '$($PatSpec.env)' was not found or was empty for organization '$OrganizationName'."
        }

        return $token
    }

    throw "No PAT was provided for organization '$OrganizationName'. Supply -Pat or configure pat."
}

function Invoke-AzDOGet {
    param(
        [string]$Uri,
        [hashtable]$Headers
    )

    Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get
}

function Test-AzDOIdentityMatch {
    param(
        [AllowNull()][object]$Identity,
        [object]$AuthenticatedUser
    )

    if ($null -eq $Identity) { return $false }

    $identityId=[string]$Identity.id
    $userId=[string]$AuthenticatedUser.Id

    if (-not [string]::IsNullOrWhiteSpace($identityId) -and -not [string]::IsNullOrWhiteSpace($userId) -and $identityId -eq $userId) {
        return $true
    }

    $identityName=Get-AzDOComparable $(if ($Identity.displayName) { $Identity.displayName } elseif ($Identity.uniqueName) { $Identity.uniqueName } else { $Identity.name })
    $userName=Get-AzDOComparable $AuthenticatedUser.Name

    $identityName -and $userName -and $identityName -eq $userName
}

function Get-AzDOReviewerVote {
    param(
        [object]$PullRequest,
        [object]$AuthenticatedUser
    )

    foreach ($reviewer in @($PullRequest.reviewers)) {
        if (Test-AzDOIdentityMatch -Identity $reviewer -AuthenticatedUser $AuthenticatedUser) {
            $voteProperty=$reviewer.PSObject.Properties['vote']

            if ($null -ne $voteProperty -and $null -ne $voteProperty.Value) {
                return [int]$voteProperty.Value
            }
        }

        foreach ($votedFor in @($reviewer.votedFor)) {
            if (Test-AzDOIdentityMatch -Identity $votedFor -AuthenticatedUser $AuthenticatedUser) {
                $voteProperty=$votedFor.PSObject.Properties['vote']

                if ($null -ne $voteProperty -and $null -ne $voteProperty.Value) {
                    return [int]$voteProperty.Value
                }
            }
        }
    }

    $null
}

function Get-AzDOThreadCommentCount {
    param(
        [string]$OrganizationName,
        [string]$ProjectName,
        [string]$RepositoryId,
        [int]$PullRequestId,
        [hashtable]$Headers,
        [object]$AuthenticatedUser
    )

    $uri="https://dev.azure.com/$OrganizationName/$([Uri]::EscapeDataString($ProjectName))/_apis/git/repositories/$([Uri]::EscapeDataString($RepositoryId))/pullRequests/$PullRequestId/threads?api-version=7.1"
    $threads=@((Invoke-AzDOGet -Uri $uri -Headers $Headers).value)
    $count=0

    foreach ($thread in $threads) {
        foreach ($comment in @($thread.comments)) {
            if ($comment.commentType -eq 'system') { continue }

            if (Test-AzDOIdentityMatch -Identity $comment.author -AuthenticatedUser $AuthenticatedUser) {
                $count++
            }
        }
    }

    $count
}

function New-AzDOProfileRecord {
    param(
        [string]$OrganizationName,
        [string]$ProjectName,
        [object]$PullRequest,
        [string[]]$Involvement,
        [int]$CommentCount,
        [AllowNull()][object]$ReviewerVote
    )

    $repoName=$PullRequest.repository.name
    $repo=[Uri]::EscapeDataString($repoName)
    $projectPath=[Uri]::EscapeDataString($ProjectName)
    $url="https://dev.azure.com/$OrganizationName/$projectPath/_git/$repo/pullrequest/$($PullRequest.pullRequestId)"
    $closedDate=if ($PullRequest.closedDate) { ConvertTo-AzDOLocalDateTime $PullRequest.closedDate } else { ConvertTo-AzDOLocalDateTime $PullRequest.creationDate }

    [pscustomobject]@{
        Organization=$OrganizationName;
        Project=$ProjectName;
        Repository=$repoName;
        PullRequestId=$PullRequest.pullRequestId;
        Title=$PullRequest.title;
        CreatedBy=$PullRequest.createdBy.displayName;
        CreationDate=ConvertTo-AzDOLocalDateTime $PullRequest.creationDate;
        ClosedDate=$closedDate;
        Status=$PullRequest.status;
        Involvement=$Involvement;
        CommentCount=$CommentCount;
        ReviewerVote=$ReviewerVote;
        PRUrl=$url
    }
}

function Get-AzDOClosedPullRequests {
    param(
        [string]$OrganizationName,
        [string]$ProjectName,
        [hashtable]$Headers,
        [string]$Status,
        [int]$MaxPerProject
    )

    $statuses=if ($Status -eq 'all') { @('completed','abandoned') } else { @($Status) }
    $results=[System.Collections.Generic.List[object]]::new()

    foreach ($statusValue in $statuses) {
        $uri="https://dev.azure.com/$OrganizationName/$([Uri]::EscapeDataString($ProjectName))/_apis/git/pullrequests?searchCriteria.status=$statusValue&%24top=$MaxPerProject&api-version=7.1"

        foreach ($pr in @((Invoke-AzDOGet -Uri $uri -Headers $Headers).value)) {
            $results.Add($pr) | Out-Null
        }
    }

    $results.ToArray()
}

function Test-AzDORequestedView {
    param(
        [string[]]$RequestedView,
        [string]$Name
    )

    $RequestedView -contains 'All' -or $RequestedView -contains $Name
}

function Get-AzDOProjectProfileRecords {
    param(
        [string]$OrganizationName,
        [object]$Project,
        [hashtable]$Headers,
        [object]$AuthenticatedUser,
        [string[]]$View,
        [string]$Status,
        [datetime]$Since,
        [int]$MaxPerProject
    )

    $records=[System.Collections.Generic.List[object]]::new()
    $pullRequests=@(Get-AzDOClosedPullRequests -OrganizationName $OrganizationName -ProjectName $Project.name -Headers $Headers -Status $Status -MaxPerProject $MaxPerProject)

    foreach ($pr in $pullRequests) {
        $closedDate=if ($pr.closedDate) { ConvertTo-AzDOLocalDateTime $pr.closedDate } else { ConvertTo-AzDOLocalDateTime $pr.creationDate }

        if ($closedDate -and $closedDate -lt $Since) { continue }

        $involvement=[System.Collections.Generic.List[string]]::new()
        $commentCount=0
        $vote=Get-AzDOReviewerVote -PullRequest $pr -AuthenticatedUser $AuthenticatedUser

        if ((Test-AzDORequestedView -RequestedView $View -Name 'Created') -and (Test-AzDOIdentityMatch -Identity $pr.createdBy -AuthenticatedUser $AuthenticatedUser)) {
            $involvement.Add('Created') | Out-Null
        }

        if ((Test-AzDORequestedView -RequestedView $View -Name 'Approved') -and $vote -in 5,10) {
            $involvement.Add($(if ($vote -eq 10) { 'Approved' } else { 'Approved with suggestions' })) | Out-Null
        }

        if (Test-AzDORequestedView -RequestedView $View -Name 'Commented') {
            $commentCount=Get-AzDOThreadCommentCount `
                -OrganizationName $OrganizationName `
                -ProjectName $Project.name `
                -RepositoryId $pr.repository.id `
                -PullRequestId $pr.pullRequestId `
                -Headers $Headers `
                -AuthenticatedUser $AuthenticatedUser

            if ($commentCount -gt 0) {
                $involvement.Add("Commented ($commentCount)") | Out-Null
            }
        }

        if ($involvement.Count -eq 0) { continue }

        $records.Add((New-AzDOProfileRecord `
            -OrganizationName $OrganizationName `
            -ProjectName $Project.name `
            -PullRequest $pr `
            -Involvement $involvement.ToArray() `
            -CommentCount $commentCount `
            -ReviewerVote $vote)) | Out-Null
    }

    $records.ToArray()
}

function Format-AzDOProfileOutput {
    param(
        [string]$Section,
        [object]$Record
    )

    if ($Section) {
        $title=switch($Section) {
            'Created' { 'CREATED' }
            'Involved' { 'INVOLVED' }
            default { $Section.ToUpperInvariant() }
        }

        $style=Get-AzDOStyle

        return @(
            "$($style.Cyan)$title$($style.Reset)"
            "$($style.Cyan)$('='*$title.Length)$($style.Reset)"
        ) -join [Environment]::NewLine
    }

    $style=Get-AzDOStyle
    $width=[math]::Max(1, (Get-AzDOConsoleWidth)-1)
    $urlLines=@(
        for ($i=0; $i -lt $Record.PRUrl.Length; $i+=$width) {
            $length=[math]::Min($width, $Record.PRUrl.Length-$i)
            "$($style.Purple)$($Record.PRUrl.Substring($i, $length))$($style.Reset)$($style.ClearLine)"
        }
    )
    $statusColor=switch ($Record.Status) {
        'completed' { $style.Green; break }
        'abandoned' { $style.Orange; break }
        default { $style.White }
    }

    (@(
        "$($style.Dim)$($Record.Organization) / $($Record.Project) / $($Record.Repository)$($style.Reset) | $statusColor$($Record.Status)$($style.Reset) | closed $(Format-RelativeTime $Record.ClosedDate)$($style.ClearLine)"
        "[#$($Record.PullRequestId)] $($Record.Title)$($style.Reset)$($style.ClearLine)"
        "$($style.Dim)Created $(Format-RelativeTime $Record.CreationDate) by $($Record.CreatedBy)$($style.Reset) | $($style.Cyan)$($Record.Involvement -join ', ')$($style.Reset)$($style.ClearLine)"
        $urlLines
        ''
    ) | ForEach-Object { $_ }) -join [Environment]::NewLine
}

function Get-AzDOProfile {
    [CmdletBinding(DefaultParameterSetName='ConfigPath')]
    param(
        [Parameter(ParameterSetName='ConfigPath')]
        [string]$ConfigPath,

        [Parameter(Mandatory=$true, ParameterSetName='Direct')]
        [string]$Org,

        [Parameter(ParameterSetName='Direct')]
        [string]$Pat,

        [Parameter(ParameterSetName='Direct')]
        [object[]]$Projects=@(),

        [ValidateSet('Created','Approved','Commented','All')]
        [string[]]$View=@('All'),

        [ValidateSet('completed','abandoned','all')]
        [string]$Status='all',

        [datetime]$Since,

        [int]$MaxPerProject=500
    )

    if ($PSCmdlet.ParameterSetName -eq 'ConfigPath' -and [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = $script:ConfigPath
    }

    if ($MaxPerProject -le 0) { throw "-MaxPerProject must be a positive integer." }

    $configs=Get-AzDOConfigCollection -ConfigPath $ConfigPath -Org $Org -Pat $Pat -Projects $Projects -IsDirect ($PSCmdlet.ParameterSetName -eq 'Direct')
    $allResults=[System.Collections.Generic.List[object]]::new()

    foreach ($config in $configs) {
        try {
            if (-not $config.Enabled) {
                Write-Information "Skipping organization '$($config.Name)' because it is disabled in config."
                continue
            }

            $token=Resolve-AzDOPat -PatSpec $(if ($Pat) {$Pat} else {$config.Pat}) -OrganizationName $config.Name
            $headers=@{
                Authorization="Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$token")))"
            }

            $me=(Invoke-AzDOGet -Uri "https://dev.azure.com/$($config.Name)/_apis/connectionData?api-version=7.1-preview.1&connectOptions=1" -Headers $headers).authenticatedUser
            $me=[pscustomobject]@{
                Id=$me.id;
                Name=if ($me.customDisplayName) {$me.customDisplayName} else {$me.providerDisplayName}
            }

            $allProjects=@((Invoke-AzDOGet -Uri "https://dev.azure.com/$($config.Name)/_apis/projects?api-version=7.1-preview.4" -Headers $headers).value)
            $projects=$allProjects

            if ($config.FromConfig) {
                if (@($config.Projects).Count -eq 0) {
                    Write-Information "Skipping organization '$($config.Name)' because no projects were configured."
                    continue
                }
            }

            if (@($config.Projects).Count -gt 0) {
                $lookup=@{}
                $allProjects | ForEach-Object {$lookup[$_.name.ToLowerInvariant()]=$_}
                $selected=[System.Collections.Generic.List[object]]::new()

                foreach ($p in @($config.Projects)) {
                    $name=[string]$p

                    if ([string]::IsNullOrWhiteSpace($name)) { continue }

                    $key=$name.ToLowerInvariant()

                    if ($lookup.ContainsKey($key)) {
                        $selected.Add($lookup[$key]) | Out-Null
                    } else {
                        Write-Information "Configured project '$name' was not found in organization '$($config.Name)'."
                    }
                }

                $projects=$selected.ToArray()
            }

            foreach ($project in $projects) {
                try {
                    $records=Get-AzDOProjectProfileRecords `
                        -OrganizationName $config.Name `
                        -Project $project `
                        -Headers $headers `
                        -AuthenticatedUser $me `
                        -View $View `
                        -Status $Status `
                        -Since $Since `
                        -MaxPerProject $MaxPerProject

                    foreach ($record in @($records)) {
                        $allResults.Add($record) | Out-Null
                    }
                } catch {
                    Write-Warning "Failed to inspect project '$($project.name)' in organization '$($config.Name)': $($_.Exception.Message)"
                }
            }
        } catch {
            $message="Failed to inspect Azure DevOps organization '$($config.Name)': $($_.Exception.Message)"

            if ($ErrorActionPreference -eq 'Stop') { throw $message }

            Write-Warning $message
        }
    }

    $results=@($allResults.ToArray() | Sort-Object ClosedDate -Descending)

    if ($results.Count -eq 0) {
        Write-Output "No closed PRs found with direct personal involvement."
        return
    }

    $createdRecords=@($results | Where-Object { $_.Involvement -contains 'Created' })
    $involvedRecords=@($results | Where-Object { $_.Involvement -notcontains 'Created' })

    if ($createdRecords.Count -gt 0) {
        Write-Output (Format-AzDOProfileOutput -Section 'Created')

        foreach ($record in $createdRecords) {
            Write-Output (Format-AzDOProfileOutput -Record $record)
        }
    }

    if ($involvedRecords.Count -gt 0) {
        Write-Output (Format-AzDOProfileOutput -Section 'Involved')

        foreach ($record in $involvedRecords) {
            Write-Output (Format-AzDOProfileOutput -Record $record)
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($PSBoundParameters.ContainsKey('Days')) {
        if ($Days -le 0) { throw "-Days must be a positive integer." }
        $Since=(Get-Date).AddDays(-$Days)
    }

    $runParameters=@{}

    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Key -ne 'Days') { $runParameters[$entry.Key]=$entry.Value }
    }

    $runParameters.Since=$Since
    Get-AzDOProfile @runParameters
}
