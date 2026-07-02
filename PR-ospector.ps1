[CmdletBinding(DefaultParameterSetName = 'ConfigPath')]
param(
    [Parameter(ParameterSetName = 'ConfigPath')]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.yml'),

    [Parameter(Mandatory = $true, ParameterSetName = 'Direct')]
    [string]$Org,

    [Parameter(ParameterSetName = 'Direct')]
    [string]$Pat,

    [ValidateSet('Created', 'ReviewRequested', 'Both')]
    [string]$View = 'Both',

    [ValidateSet('active', 'completed', 'abandoned', 'all')]
    [string]$Status = 'active',

    [ValidateSet('Pending', 'All')]
    [string]$ReviewState = 'Pending',

    [ValidateSet('Configured', 'Discover')]
    [string]$Mode = 'Configured',

    [switch]$Watch,

    [int]$RefreshSeconds,

    [string]$RefreshKey,

    [Parameter(ParameterSetName = 'Direct')]
    [object[]]$Groups = @()
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
    param([datetime]$DateTime)

    if (-not $DateTime) { return 'unknown' }

    $DateTime=ConvertTo-AzDOLocalDateTime $DateTime
    $now=Get-Date
    $span=$now-$DateTime

    if ($span.TotalSeconds -lt 0) {
        $span=$DateTime-$now

        if ($span.TotalMinutes -lt 1) { return 'in moments' }

        if ($span.TotalHours -lt 1) { return "in $([math]::Max(1,[math]::Floor($span.TotalMinutes)))m" }

        if ($span.TotalDays -lt 1) { return "in $([math]::Max(1,[math]::Floor($span.TotalHours)))h" }

        return "in $([math]::Max(1,[math]::Floor($span.TotalDays)))d"
    }

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
        Cyan="$esc[38;2;0;255;255m";       # #00FFFF
        Purple="$esc[38;2;140;107;200m";   # #8C6BC8
        White="$esc[38;2;255;255;255m";    # #FFFFFF
        Green="$esc[38;2;85;163;98m";      # #55A362
        Orange="$esc[38;2;214;118;40m";    # #D67628
        Blue="$esc[38;2;0;90;156m";        # #005A9C
        Red="$esc[38;2;205;74;69m";        # #CD4A45
    }
}

function Format-AzDOReviewStatus {
    param([AllowNull()][string]$Status)

    if ([string]::IsNullOrWhiteSpace($Status)) { return $Status }

    $style=Get-AzDOStyle
    $color=switch ($Status) {
        'Approved'                  { $style.Green; break }
        'Approved with suggestions' { $style.Green; break }
        'Review Needed'             { $style.White; break }
        'Re-review Needed'          { $style.White; break }
        'Waiting for author'        { $style.Orange; break }
        'Draft'                     { $style.Blue; break }
        'Rejected'                  { $style.Red; break }
        'Declined'                  { $style.Red; break }
        default { $null }
    }

    if ($null -eq $color) { return $Status }

    "$color$Status$($style.Reset)"
}

function Format-AzDOOutput {
    param(
        [string]$Section,
        [object]$Record
    )

    if ($Section) {
        $title=switch($Section) {
            'Created' { 'CREATED' }
            'ReviewRequested' { 'REQUESTED' }
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

    (@(
        "$($style.Dim)$(Format-RelativeTime $Record.CreationDate) by $($Record.CreatedBy)$($style.Reset) | $(Format-AzDOReviewStatus -Status $Record.ReviewStatus)$($style.Reset)$($style.ClearLine)"
        "[#$($Record.PullRequestId)] $($Record.Title)$($style.Reset)$($style.ClearLine)"
        $urlLines
        ''
    ) | ForEach-Object { $_ }) -join [Environment]::NewLine
}

function Get-AzDOComparable {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }

    $text=[string]$Value

    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $text.Trim().ToLowerInvariant()
}

function Get-AzDOIdentityPropertyValue {
    param(
        [object]$Identity,
        [string]$PropertyName
    )

    if ($null -eq $Identity) { return $null }

    $propertiesProperty=$Identity.PSObject.Properties['properties']

    if ($null -eq $propertiesProperty -or $null -eq $propertiesProperty.Value) { return $null }

    $identityProperties=$propertiesProperty.Value
    $requestedProperty=$identityProperties.PSObject.Properties[$PropertyName]

    if ($null -eq $requestedProperty -or $null -eq $requestedProperty.Value) { return $null }

    $requestedValueProperty=$requestedProperty.Value.PSObject.Properties['value']

    if ($null -eq $requestedValueProperty) { return $null }

    $requestedValueProperty.Value
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

function Get-AzDOObjectPropertyValue {
    param(
        [AllowNull()][object]$InputObject,
        [string]$PropertyName
    )

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($PropertyName)) {
            return $InputObject[$PropertyName]
        }

        return $null
    }

    $property=$InputObject.PSObject.Properties[$PropertyName]

    if ($null -eq $property) { return $null }

    $property.Value
}

function Get-AzDOConfigCollection {
    param(
        [string]$ConfigPath,
        [string]$Org,
        [string]$Pat,
        [object[]]$Groups,
        [bool]$IsDirect
    )

    if ($IsDirect) {
        return @(
            [pscustomobject]@{
                Name = $Org;
                Pat = $Pat;
                Enabled = $true;
                Groups = @(@($Groups) | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)});
                Projects = @();
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
                Groups = @(@($_.groups) | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)});
                Projects = @(@($_.projects) | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)});
                FromConfig = $true
            }
        }
    )
}

function Resolve-AzDOConsoleKey {
    param(
        [object]$KeySpec,
        [string]$SettingName
    )

    $text=[string]$KeySpec

    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "$SettingName must be a non-empty key name or single character."
    }

    $text=$text.Trim()

    if ($text.Length -eq 1) {
        $char=[char]$text

        if ([char]::IsLetter($char)) { return [System.ConsoleKey](([string]$char).ToUpperInvariant()) }
        if ([char]::IsDigit($char)) { return [System.ConsoleKey]("D$char") }
        if ($char -eq ' ') { return [System.ConsoleKey]::Spacebar }
    }

    try {
        return [System.ConsoleKey][Enum]::Parse([System.ConsoleKey], $text, $true)
    } catch {
        throw "$SettingName value '$text' is not a supported console key. Use a single letter, digit, or ConsoleKey name such as F5 or Spacebar."
    }
}

function Get-AzDOConsoleWidth {
    try {
        if ([Console]::WindowWidth -gt 0) {
            return [Console]::WindowWidth
        }
    } catch {
    }

    120
}

function Write-AzDOWatchHeader {
    param(
        [datetime]$LastRefresh,
        [datetime]$NextRefresh,
        [string]$RefreshKeyDisplay
    )

    $now=Get-Date
    $remaining=[int][math]::Ceiling(($NextRefresh-$now).TotalSeconds)
    $width=Get-AzDOConsoleWidth
    $style=Get-AzDOStyle
    $remainingSpan=[TimeSpan]::FromSeconds([math]::Max(0, $remaining))
    $lastRefreshText=$LastRefresh.ToString('ddd, MMMM d, yyyy h:mm:ss tt')
    $remainingText=if ($remainingSpan.TotalHours -ge 1) { $remainingSpan.ToString('hh\:mm\:ss') } else { $remainingSpan.ToString('mm\:ss') }

    $drawableWidth=[math]::Max(1, $width-1)
    $segments=@(
        @{ Text='PR-ospector'; Color=$style.Cyan }
        @{ Text=' | pulled: '; Color=$style.Dim }
        @{ Text=$lastRefreshText; Color=$style.White }
        @{ Text=' next: '; Color=$style.Dim }
        @{ Text=$remainingText; Color=$style.Cyan }
        @{ Text=' | refresh: '; Color=$style.Dim }
        @{ Text=$RefreshKeyDisplay; Color=$style.Purple }
        @{ Text=' quit: '; Color=$style.Dim }
        @{ Text='q'; Color=$style.Purple }
    )
    $lines=@('', '')
    $row=0
    $remainingWidth=$drawableWidth

    foreach ($segment in $segments) {
        $text=[string]$segment.Text
        $offset=0

        while ($offset -lt $text.Length -and $row -lt $lines.Count) {
            if ($remainingWidth -le 0) {
                $row++
                $remainingWidth=$drawableWidth
                continue
            }

            $length=[math]::Min($remainingWidth, $text.Length-$offset)
            $visibleText=$text.Substring($offset, $length)
            $lines[$row]="$($lines[$row])$($segment.Color)$visibleText$($style.Reset)"
            $offset+=$length
            $remainingWidth-=$length
        }

        if ($row -ge $lines.Count) { break }
    }

    $firstLine="$($style.Reset)$($lines[0])$($style.Reset)$($style.ClearLine)"
    $secondLine="$($style.Reset)$($lines[1])$($style.Reset)$($style.ClearLine)"

    try {
        $left=[Console]::CursorLeft
        $top=[Console]::CursorTop
        [Console]::SetCursorPosition(0, 0)
        [Console]::Write($firstLine)
        [Console]::SetCursorPosition(0, 1)
        [Console]::Write($secondLine)
        $left=[math]::Min($left, [math]::Max(0, [Console]::BufferWidth-1))
        $top=[math]::Min($top, [math]::Max(0, [Console]::BufferHeight-1))
        [Console]::SetCursorPosition($left, $top)
    } catch {
    }
}

function Invoke-AzDOWatch {
    [CmdletBinding(DefaultParameterSetName='ConfigPath')]
    param(
        [Parameter(ParameterSetName='ConfigPath')]
        [string]$ConfigPath,

        [Parameter(Mandatory=$true,ParameterSetName='Direct')]
        [string]$Org,

        [Parameter(ParameterSetName='Direct')]
        [string]$Pat,

        [ValidateSet('Created','ReviewRequested','Both')]
        [string]$View='Both',

        [ValidateSet('active','completed','abandoned','all')]
        [string]$Status='active',

        [ValidateSet('Pending','All')]
        [string]$ReviewState='Pending',

        [ValidateSet('Configured','Discover')]
        [string]$Mode='Configured',

        [int]$RefreshSeconds,

        [string]$RefreshKey,

        [Parameter(ParameterSetName='Direct')]
        [object[]]$Groups=@()
    )

    if ($Mode -eq 'Discover') {
        throw "Watch mode does not support -Mode Discover because Discover can update YAML config. Run Discover as a one-shot command first."
    }

    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        throw "Watch mode requires an interactive console because it reads keys and updates the countdown in place."
    }

    if ($PSCmdlet.ParameterSetName -eq 'ConfigPath' -and [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = $script:ConfigPath
    }

    if ($PSBoundParameters.ContainsKey('RefreshSeconds') -and $RefreshSeconds -le 0) {
        throw "-RefreshSeconds must be a positive integer."
    }

    if ($PSBoundParameters.ContainsKey('RefreshKey') -and [string]::IsNullOrWhiteSpace($RefreshKey)) {
        throw "-RefreshKey must be a non-empty key name or single character."
    }

    $refreshSecondsValue=600
    $refreshKeyValue='r'

    if ($PSCmdlet.ParameterSetName -ne 'Direct') {
        $watchConfig=Get-AzDOObjectPropertyValue -InputObject (Read-AzDOConfig -ConfigPath $ConfigPath) -PropertyName 'watch'

        if ($null -ne $watchConfig) {
            $configuredSeconds=Get-AzDOObjectPropertyValue -InputObject $watchConfig -PropertyName 'refreshSeconds'
            $configuredKey=Get-AzDOObjectPropertyValue -InputObject $watchConfig -PropertyName 'refreshKey'

            if ($null -ne $configuredSeconds) {
                try { $refreshSecondsValue=[int]$configuredSeconds } catch { throw "watch.refreshSeconds must be a positive integer." }
            }

            if ($null -ne $configuredKey) { $refreshKeyValue=[string]$configuredKey }
        }
    }

    if ($RefreshSeconds -gt 0) { $refreshSecondsValue=$RefreshSeconds }
    if (-not [string]::IsNullOrWhiteSpace($RefreshKey)) { $refreshKeyValue=$RefreshKey }
    if ($refreshSecondsValue -le 0) { throw "watch.refreshSeconds must be a positive integer." }

    $refreshKeyValue=[string]$refreshKeyValue
    $refreshKeyResolved=Resolve-AzDOConsoleKey -KeySpec $refreshKeyValue -SettingName 'watch.refreshKey'

    $pullParameters=@{}

    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Key -notin 'RefreshSeconds','RefreshKey') { $pullParameters[$entry.Key]=$entry.Value }
    }

    if ($PSCmdlet.ParameterSetName -eq 'ConfigPath') { $pullParameters.ConfigPath=$ConfigPath }

    $cursorVisibility=$null
    $windowTitle=$null

    try {
        try {
            $cursorVisibility=[Console]::CursorVisible
            [Console]::CursorVisible=$false
        } catch {
        }

        try {
            $windowTitle=$Host.UI.RawUI.WindowTitle
            $Host.UI.RawUI.WindowTitle='PR-ospector'
        } catch {
        }

        while ($true) {
            Clear-Host
            $lastRefresh=Get-Date
            $nextRefresh=$lastRefresh.AddSeconds($refreshSecondsValue)
            Write-AzDOWatchHeader -LastRefresh $lastRefresh -NextRefresh $nextRefresh -RefreshKeyDisplay $refreshKeyValue

            try {
                [Console]::SetCursorPosition(0, 2)
            } catch {
            }

            Get-AzDOPulls @pullParameters

            while ((Get-Date) -lt $nextRefresh) {
                Write-AzDOWatchHeader -LastRefresh $lastRefresh -NextRefresh $nextRefresh -RefreshKeyDisplay $refreshKeyValue

                if ([Console]::KeyAvailable) {
                    $key=[Console]::ReadKey($true)

                    if ($key.Key -eq [System.ConsoleKey]::Q) { return }
                    if ($key.Key -eq $refreshKeyResolved) { break }
                }

                Start-Sleep -Milliseconds 200
            }
        }
    } finally {
        if ($null -ne $cursorVisibility) {
            try {
                [Console]::CursorVisible=$cursorVisibility
            } catch {
            }
        }

        if ($null -ne $windowTitle) {
            try {
                $Host.UI.RawUI.WindowTitle=$windowTitle
            } catch {
            }
        }
    }
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

function Resolve-AzDOReviewerGroups {
    param(
        [string]$OrganizationName,
        [hashtable]$Headers,
        [object[]]$ConfiguredGroups
    )

    $resolved=[System.Collections.Generic.List[object]]::new()

    foreach ($group in @($ConfiguredGroups)) {
        $groupName=[string]$group

        if ([string]::IsNullOrWhiteSpace($groupName)) { continue }

        $identityMatches=@(
            (Invoke-AzDOGet -Uri "https://vssps.dev.azure.com/$OrganizationName/_apis/identities?searchFilter=General&filterValue=$([Uri]::EscapeDataString($groupName))&queryMembership=None&api-version=7.1-preview.1" -Headers $Headers).value
        )

        $needle=Get-AzDOComparable $groupName
        $best=$null

        foreach ($match in $identityMatches) {
            $candidates=@(
                Get-AzDOComparable $match.providerDisplayName
                Get-AzDOComparable $match.customDisplayName
                Get-AzDOComparable (Get-AzDOIdentityPropertyValue $match 'Account')
                Get-AzDOComparable (Get-AzDOIdentityPropertyValue $match 'Mail')
            ) | Where-Object {$_}

            if ($candidates -contains $needle) {
                $best=$match
                break
            }
        }

        if ($null -eq $best -and $identityMatches.Count -gt 0) {
            $best=$identityMatches[0]
        }

        if ($null -eq $best) {
            Write-Information "Configured group '$groupName' could not be resolved in organization '$OrganizationName'. Group review matching will fall back to generic reviewer data only."
            $resolved.Add([pscustomobject]@{
                Name = $groupName;
                Id = $null
            }) | Out-Null
            continue
        }

        $resolved.Add([pscustomobject]@{
            Name = $groupName;
            Id = $best.id
        }) | Out-Null
    }

    $resolved.ToArray()
}

function New-AzDORecord {
    param(
        [string]$OrganizationName,
        [string]$ProjectName,
        [object]$PullRequest,
        [string]$View
    )

    $repo=[Uri]::EscapeDataString($PullRequest.repository.name)
    $projectPath=[Uri]::EscapeDataString($ProjectName)
    $url="https://dev.azure.com/$OrganizationName/$projectPath/_git/$repo/pullrequest/$($PullRequest.pullRequestId)"

    [pscustomobject]@{
        PullRequestId=$PullRequest.pullRequestId;
        Title=$PullRequest.title;
        CreatedBy=$PullRequest.createdBy.displayName;
        CreationDate=ConvertTo-AzDOLocalDateTime $PullRequest.creationDate;
        PRUrl=$url;
        View=$View;
        ReviewStatus=$null;
        ReviewerVote=$null
    }
}

function Get-AzDOReviewerVote {
    param([object]$Reviewer)

    if ($null -eq $Reviewer) { return $null }

    $voteProperty=$Reviewer.PSObject.Properties['vote']

    if ($null -ne $voteProperty -and $null -ne $voteProperty.Value) {
        return [int]$voteProperty.Value
    }

    $votes=@(
        @($Reviewer.votedFor) |
            ForEach-Object {
                $memberVoteProperty=$_.PSObject.Properties['vote']

                if ($null -ne $memberVoteProperty -and $null -ne $memberVoteProperty.Value) {
                    [int]$memberVoteProperty.Value
                }
            } |
            Where-Object { $null -ne $_ }
    )

    if ($votes.Count -eq 0) { return $null }

    $nonZeroVote=@($votes | Where-Object { $_ -ne 0 } | Select-Object -First 1)

    if ($nonZeroVote.Count -gt 0) { return [int]$nonZeroVote[0] }

    if ($votes -contains 0) { return 0 }

    $votes[0]
}

function Get-AzDOReviewerStatus {
    param([object]$Reviewer)

    if ($null -eq $Reviewer) {
        return [pscustomobject]@{
            Status = 'Unknown';
            Vote = $null;
            IsActionable = $false
        }
    }

    $vote=Get-AzDOReviewerVote -Reviewer $Reviewer
    $candidates=@($Reviewer) + @($Reviewer.votedFor)
    $hasDeclined=$false
    $isFlagged=$false
    $isReapprove=$false

    foreach ($candidate in @($candidates | Where-Object { $null -ne $_ })) {
        if ($candidate.hasDeclined -eq $true) { $hasDeclined=$true }
        if ($candidate.isFlagged -eq $true) { $isFlagged=$true }
        if ($candidate.isReapprove -eq $true) { $isReapprove=$true }
    }

    $status=switch ($vote) {
        { $hasDeclined } { 'Declined'; break }
        { $_ -eq $null -or $_ -eq 0 } { 'Review Needed'; break }
        -5 { 'Waiting for author'; break }
        -10 { 'Rejected'; break }
        5 {
            if ($isReapprove -or $isFlagged) { 'Re-review Needed' } else { 'Approved with suggestions' }
            break
        }
        10 {
            if ($isReapprove -or $isFlagged) { 'Re-review Needed' } else { 'Approved' }
            break
        }
        default { "Vote $vote" }
    }

    [pscustomobject]@{
        Status = $status;
        Vote = $vote;
        IsActionable = $status -in @('Review Needed','Waiting for author','Re-review Needed')
    }
}

function Get-AzDOPullRequestReviewStatus {
    param(
        [object]$PullRequest,
        [object]$AuthenticatedUser
    )

    if ($PullRequest.isDraft -eq $true) {
        return [pscustomobject]@{
            Status = 'Draft';
            Vote = $null
        }
    }

    $reviewers=@(
        @($PullRequest.reviewers) |
            Where-Object {
                $_ -and
                $_.id -and
                (-not $AuthenticatedUser.Id -or [string]$_.id -ne [string]$AuthenticatedUser.Id)
            }
    )

    if ($reviewers.Count -eq 0) {
        return [pscustomobject]@{
            Status = 'No reviewers';
            Vote = $null
        }
    }

    $statusNames=@($reviewers | ForEach-Object { (Get-AzDOReviewerStatus -Reviewer $_).Status })

    $aggregate=switch ($true) {
        { $statusNames -contains 'Rejected' } { 'Rejected'; break }
        { $statusNames -contains 'Re-review Needed' } { 'Re-review Needed'; break }
        { $statusNames -contains 'Waiting for author' } { 'Waiting for author'; break }
        { $statusNames -contains 'Review Needed' } { 'Review Needed'; break }
        { $statusNames -contains 'Approved with suggestions' } { 'Approved with suggestions'; break }
        { $statusNames -contains 'Approved' } { 'Approved'; break }
        { $statusNames -contains 'Declined' } { 'Declined'; break }
        default { ($statusNames | Select-Object -First 1) }
    }

    [pscustomobject]@{
        Status = $aggregate;
        Vote = $null
    }
}

function Get-AzDOCreatedRecords {
    param(
        [string]$OrganizationName,
        [string]$ProjectName,
        [hashtable]$Headers,
        [object]$AuthenticatedUser,
        [string]$Status
    )

    $results=[System.Collections.Generic.List[object]]::new()
    $uri="https://dev.azure.com/$OrganizationName/$([Uri]::EscapeDataString($ProjectName))/_apis/git/pullrequests?searchCriteria.status=$([Uri]::EscapeDataString($Status))&api-version=7.1&searchCriteria.creatorId=$([Uri]::EscapeDataString($AuthenticatedUser.Id))"

    foreach ($pr in @((Invoke-AzDOGet -Uri $uri -Headers $Headers).value)) {
        $record=New-AzDORecord -OrganizationName $OrganizationName -ProjectName $ProjectName -PullRequest $pr -View 'Created'
        $reviewStatus=Get-AzDOPullRequestReviewStatus -PullRequest $pr -AuthenticatedUser $AuthenticatedUser
        $record.ReviewStatus=$reviewStatus.Status
        $record.ReviewerVote=$reviewStatus.Vote
        $results.Add($record) | Out-Null
    }

    $results.ToArray()
}

function Get-AzDORequestedReviewRecords {
    param(
        [string]$OrganizationName,
        [string]$ProjectName,
        [hashtable]$Headers,
        [object]$AuthenticatedUser,
        [string]$Status,
        [object[]]$ResolvedGroups,
        [string]$ReviewState
    )

    $results=@{}
    $me=Get-AzDOComparable $AuthenticatedUser.Name

    $targets=@(
        if ($AuthenticatedUser.Id) {
            [pscustomobject]@{
                Id=$AuthenticatedUser.Id;
                Name=$AuthenticatedUser.Name;
                Kind='User'
            }
        }

        @($ResolvedGroups) | Where-Object Id | ForEach-Object {
            [pscustomobject]@{
                Id=$_.Id;
                Name=$_.Name;
                Kind='Group'
            }
        }
    )

    foreach ($target in $targets) {
        $uri="https://dev.azure.com/$OrganizationName/$([Uri]::EscapeDataString($ProjectName))/_apis/git/pullrequests?searchCriteria.status=$([Uri]::EscapeDataString($Status))&api-version=7.1&searchCriteria.reviewerId=$([Uri]::EscapeDataString($target.Id))"

        foreach ($pr in @((Invoke-AzDOGet -Uri $uri -Headers $Headers).value)) {
            $creatorId=[string]$pr.createdBy.id
            $creatorName=Get-AzDOComparable $pr.createdBy.displayName

            if (($AuthenticatedUser.Id -and $creatorId -eq $AuthenticatedUser.Id) -or ($me -and $creatorName -eq $me)) {
                continue
            }

            $matched=@($pr.reviewers) | Where-Object {$_.id -eq $target.Id} | Select-Object -First 1

            if (-not $matched) { continue }

            $reviewStatus=Get-AzDOReviewerStatus -Reviewer $matched

            if ($pr.isDraft -eq $true) {
                $reviewStatus=[pscustomobject]@{
                    Status = 'Draft';
                    Vote = $null;
                    IsActionable = $true
                }
            }

            if ($ReviewState -eq 'Pending' -and -not $reviewStatus.IsActionable) {
                continue
            }

            if ($results.ContainsKey($pr.pullRequestId)) { continue }

            $record=New-AzDORecord `
                -OrganizationName $OrganizationName `
                -ProjectName $ProjectName `
                -PullRequest $pr `
                -View 'ReviewRequested'

            $record.ReviewStatus=$reviewStatus.Status
            $record.ReviewerVote=$reviewStatus.Vote
            $results[$pr.pullRequestId]=$record
        }
    }

    @($results.Values | Sort-Object CreationDate -Descending)
}

function Get-AzDOProjectViewRecords {
    param(
        [string]$OrganizationName,
        [string]$ProjectName,
        [hashtable]$Headers,
        [object]$AuthenticatedUser,
        [string]$View,
        [string]$Status,
        [object[]]$ResolvedGroups,
        [string]$ReviewState
    )

    switch($View) {
        'Created' {
            @(Get-AzDOCreatedRecords -OrganizationName $OrganizationName -ProjectName $ProjectName -Headers $Headers -AuthenticatedUser $AuthenticatedUser -Status $Status)
        }

        'ReviewRequested' {
            @(Get-AzDORequestedReviewRecords -OrganizationName $OrganizationName -ProjectName $ProjectName -Headers $Headers -AuthenticatedUser $AuthenticatedUser -Status $Status -ResolvedGroups $ResolvedGroups -ReviewState $ReviewState)
        }

        'Both' {
            @(
                @(Get-AzDOCreatedRecords -OrganizationName $OrganizationName -ProjectName $ProjectName -Headers $Headers -AuthenticatedUser $AuthenticatedUser -Status $Status) +
                @(Get-AzDORequestedReviewRecords -OrganizationName $OrganizationName -ProjectName $ProjectName -Headers $Headers -AuthenticatedUser $AuthenticatedUser -Status $Status -ResolvedGroups $ResolvedGroups -ReviewState $ReviewState)
            )
        }
    }
}

function Get-AzDOProjectResult {
    param(
        [string]$OrganizationName,
        [object]$Project,
        [hashtable]$Headers,
        [object]$AuthenticatedUser,
        [string]$View,
        [string]$Status,
        [object[]]$ResolvedGroups,
        [string]$ReviewState
    )

    $start=Get-Date

    try{
        $records=@(
            Get-AzDOProjectViewRecords -OrganizationName $OrganizationName -ProjectName $Project.name -Headers $Headers -AuthenticatedUser $AuthenticatedUser -View $View -Status $Status -ResolvedGroups $ResolvedGroups -ReviewState $ReviewState
        )

        $end=Get-Date

        [pscustomobject]@{
            OrganizationName=$OrganizationName;
            ProjectName=$Project.name;
            Records=$records;
            ErrorMessage=$null;
            StartTime=$start;
            EndTime=$end;
            DurationSeconds=($end-$start).TotalSeconds
        }
    }catch{
        $end=Get-Date

        [pscustomobject]@{
            OrganizationName=$OrganizationName;
            ProjectName=$Project.name;
            Records=@();
            ErrorMessage=$_.Exception.Message;
            StartTime=$start;
            EndTime=$end;
            DurationSeconds=($end-$start).TotalSeconds
        }
    }
}

function Update-AzDOConfigFromDiscover {
    param(
        [string]$ConfigPath,
        [hashtable]$DiscoveredProjectsByOrganization
    )

    if ($DiscoveredProjectsByOrganization.Count -eq 0) { return $false }

    if (-not (Get-Command ConvertTo-Yaml -ErrorAction SilentlyContinue)) {
        throw "Discover mode YAML updates require ConvertTo-Yaml to be available in this PowerShell session."
    }

    $parsed=Read-AzDOConfig -ConfigPath $ConfigPath
    $orgs=if ($parsed.organizations) {@($parsed.organizations)} else {@($parsed)}
    $updated=$false

    foreach ($org in $orgs) {
        $name=if ($org.name) {[string]$org.name} else {[string]$org.org}

        if ([string]::IsNullOrWhiteSpace($name) -or -not $DiscoveredProjectsByOrganization.ContainsKey($name)) {
            continue
        }

        if ($null -ne $org.enabled -and -not [bool]$org.enabled) { continue }

        $existing=[string[]]@(@($org.projects) | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)} | ForEach-Object {[string]$_})
        $incoming=[string[]]@(@($DiscoveredProjectsByOrganization[$name]) | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)} | ForEach-Object {[string]$_})
        $merged=[string[]]@(@($existing+$incoming) | Sort-Object -Unique)

        if ((@($existing)-join "`n") -eq (@($merged)-join "`n")) { continue }

        $org.projects=$merged
        $updated=$true
    }

    if (-not $updated) { return $false }

    $ordered=@(
        foreach ($org in $orgs) {
            $o=[ordered]@{ name=if ($org.name) {$org.name} else {$org.org} }

            if ($null -ne $org.enabled) { $o.enabled=[bool]$org.enabled }

            if ($null -ne $org.pat) { $o.pat=$org.pat }

            if ($null -ne $org.groups) { $o.groups=[string[]]@(@($org.groups) | ForEach-Object {[string]$_}) }

            if ($null -ne $org.projects) {
                $o.projects=[string[]]@(@($org.projects) | ForEach-Object {[string]$_})
            }

            foreach ($k in $org.Keys | Where-Object {$_ -notin 'name','org','enabled','pat','groups','projects'}) {
                $o[$k]=$org[$k]
            }

            [pscustomobject]$o
        }
    )

    Set-Content -LiteralPath $ConfigPath -Value ([pscustomobject]@{ organizations=$ordered } | ConvertTo-Yaml)
    $true
}

function Get-AzDOPulls {
    [CmdletBinding(DefaultParameterSetName='ConfigPath')]
    param(
        [Parameter(ParameterSetName='ConfigPath')]
        [string]$ConfigPath,

        [Parameter(Mandatory=$true,ParameterSetName='Direct')]
        [string]$Org,

        [Parameter(ParameterSetName='Direct')]
        [string]$Pat,

        [ValidateSet('Created','ReviewRequested','Both')]
        [string]$View='Both',

        [ValidateSet('active','completed','abandoned','all')]
        [string]$Status='active',

        [ValidateSet('Pending','All')]
        [string]$ReviewState='Pending',

        [ValidateSet('Configured','Discover')]
        [string]$Mode='Configured',

        [Parameter(ParameterSetName='Direct')]
        [object[]]$Groups=@()
    )

    if ($PSCmdlet.ParameterSetName -eq 'ConfigPath' -and [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = $script:ConfigPath
    }

    $configs=Get-AzDOConfigCollection -ConfigPath $ConfigPath -Org $Org -Pat $Pat -Groups $Groups -IsDirect ($PSCmdlet.ParameterSetName -eq 'Direct')
    $allResults=[System.Collections.Generic.List[object]]::new()
    $discovered=@{}
    $discoverLabel=if ($PSCmdlet.ParameterSetName -eq 'ConfigPath') {'Projects added to config'} else {'Projects discovered for config'}

    foreach ($config in $configs) {
        $orgStart=Get-Date
        Write-Verbose "$($orgStart.ToString('o')) Org $($config.Name) started"

        try{
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

            $resolved=@(Resolve-AzDOReviewerGroups -OrganizationName $config.Name -Headers $headers -ConfiguredGroups $config.Groups)
            $allProjects=@((Invoke-AzDOGet -Uri "https://dev.azure.com/$($config.Name)/_apis/projects?api-version=7.1-preview.4" -Headers $headers).value)
            $projects=$allProjects

            if ($Mode -eq 'Configured' -and $config.FromConfig) {
                if (@($config.Projects).Count -eq 0) {
                    Write-Information "Skipping organization '$($config.Name)' because Mode is 'Configured' and no projects were configured."
                    continue
                }

                $lookup=@{}
                $allProjects | ForEach-Object {$lookup[$_.name.ToLowerInvariant()]=$_}

                $seen=@{}
                $missing=[System.Collections.Generic.List[string]]::new()
                $selected=[System.Collections.Generic.List[object]]::new()

                foreach ($p in @($config.Projects)) {
                    $name=[string]$p

                    if ([string]::IsNullOrWhiteSpace($name)) { continue }

                    $key=$name.ToLowerInvariant()

                    if ($seen[$key]) { continue }

                    $seen[$key]=$true

                    if ($lookup.ContainsKey($key)) {
                        $selected.Add($lookup[$key]) | Out-Null
                    } else {
                        $missing.Add($name) | Out-Null
                    }
                }

                foreach ($m in $missing) {
                    Write-Information "Configured project '$m' was not found in organization '$($config.Name)'."
                }

                $projects=$selected.ToArray()

                if ($projects.Count -eq 0) {
                    Write-Information "Skipping organization '$($config.Name)' because none of the configured projects were found."
                    continue
                }
            }

            if ($allProjects.Count -eq 0) {
                continue
            }

            $projectResults=[System.Collections.Generic.List[object]]::new()

            foreach ($project in $projects) {
                $r=Get-AzDOProjectResult -OrganizationName $config.Name -Project $project -Headers $headers -AuthenticatedUser $me -View $View -Status $Status -ResolvedGroups $resolved -ReviewState $ReviewState
                $projectResults.Add($r) | Out-Null

                if ($r.ErrorMessage) {
                    Write-Warning "Failed to inspect project '$($r.ProjectName)' in organization '$($r.OrganizationName)': $($r.ErrorMessage)"
                    continue
                }

                Write-Verbose "$($r.StartTime.ToString('o')) Project $($r.OrganizationName)/$($r.ProjectName) started"
                Write-Verbose "$($r.EndTime.ToString('o')) Project $($r.OrganizationName)/$($r.ProjectName) ended"
                Write-Verbose "$($r.EndTime.ToString('o')) Project $($r.OrganizationName)/$($r.ProjectName) processed in $([math]::Round($r.DurationSeconds,2))s"

                if ($Mode -ne 'Discover') {
                    foreach ($record in @($r.Records)) {
                        $allResults.Add($record) | Out-Null
                    }
                }
            }

            if ($Mode -eq 'Discover') {
                $configured=@{}

                foreach ($p in @($config.Projects)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$p)) {
                        $configured[[string]$p.ToLowerInvariant()]=[string]$p
                    }
                }

                $matching=@(@($projectResults.ToArray()) | Where-Object {-not $_.ErrorMessage -and @($_.Records).Count -gt 0} | Sort-Object ProjectName)
                $toAdd=@($matching | Where-Object {-not $configured.ContainsKey($_.ProjectName.ToLowerInvariant())} | Select-Object -ExpandProperty ProjectName)

                if ($toAdd.Count -gt 0) { $discovered[$config.Name]=$toAdd }

                Write-Output (@(
                    "Organization: $($config.Name)"
                    "Configured projects: $(if (@($config.Projects).Count -gt 0) {(@($config.Projects) | Sort-Object) -join ', '} else {'(none)'})"
                    "Projects with matching PRs: $(if ($matching.Count -gt 0) {@($matching | ForEach-Object {"$($_.ProjectName) ($(@($_.Records).Count))"}) -join ', '} else {'(none)'})"
                    "${discoverLabel}: $(if ($toAdd.Count -gt 0) {$toAdd -join ', '} else {'(none)'})"
                    ''
                ) -join [Environment]::NewLine)
            }
        }catch{
            $message="Failed to inspect Azure DevOps organization '$($config.Name)': $($_.Exception.Message)"

            if ($ErrorActionPreference -eq 'Stop') {
                throw $message
            }

            Write-Warning $message
        }finally{
            $orgEnd=Get-Date
            Write-Verbose "$($orgEnd.ToString('o')) Org $($config.Name) ended"
            Write-Verbose "$($orgEnd.ToString('o')) Org $($config.Name) processed in $([math]::Round(($orgEnd-$orgStart).TotalSeconds,2))s"
        }
    }

    if ($Mode -eq 'Discover') {
        if ($PSCmdlet.ParameterSetName -ne 'ConfigPath') {
            if ($discovered.Count -gt 0) {
                Write-Information "Discover mode found projects, but direct parameter-based runs do not update a config file automatically."
            }

            return
        }

        if (Update-AzDOConfigFromDiscover -ConfigPath $ConfigPath -DiscoveredProjectsByOrganization $discovered) {
            Write-Information "Discover mode updated '$ConfigPath' with newly discovered projects."
        }

        return
    }

    foreach ($section in $(if ($View -eq 'Both') {'Created','ReviewRequested'} else {$View})) {
        $sectionRecords=@(@($allResults.ToArray()) | Where-Object {$_.View -eq $section} | Sort-Object CreationDate -Descending)

        if ($sectionRecords.Count -eq 0) { continue }

        Write-Output (Format-AzDOOutput -Section $section)

        foreach ($record in $sectionRecords) {
            Write-Output (Format-AzDOOutput -Record $record)
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $runParameters=@{}
    $excluded=if ($Watch) { @('Watch') } else { @('Watch','RefreshSeconds','RefreshKey') }

    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Key -notin $excluded) { $runParameters[$entry.Key]=$entry.Value }
    }

    if ($Watch) { Invoke-AzDOWatch @runParameters } else { Get-AzDOPulls @runParameters }
}
