# PR-actical-Tools

`PR-actical-Tools` is a repo of PowerShell utilities for Azure DevOps pull request workflows.

The first tool in the repo is `PR-ospector.ps1`, a cross-organization pull request dashboard that helps you answer:
- What PRs did I create?
- What PRs are waiting on me?
- What PRs are waiting on one of my reviewer groups?
- Which requested reviews still need action versus ones I've already handled?
- Why is a requested-review PR still showing up?

By default, it reads `config.yml` and only scans the projects you list there.

## Who This Is For
This repo is really only useful for Azure DevOps users. If you do not actively work in Azure DevOps repos and pull requests, this repo probably will not be very helpful.

It is aimed at people who:
- work across multiple Azure DevOps organizations
- need a single view of created and requested-review PRs
- want the default requested-review list to stay focused on actionable review requests
- want the dashboard to explain whether a PR needs review, is waiting on the author, or needs re-review
- want a lightweight script instead of opening each org and project manually

## Current Tools
- `PR-ospector.ps1`: cross-org PR discovery and dashboarding for created and requested-review pull requests
- `PR-ofiler.ps1`: cross-org personal PR activity profiler for closed PRs where you created, approved, or commented

## `PR-ospector.ps1`
The rest of this README covers how to use `PR-ospector.ps1`.

## Prerequisites
- PowerShell 7 recommended
- Access to the Azure DevOps organizations you want to query
- A Personal Access Token with permission to read pull requests and project metadata
- `ConvertFrom-Yaml` available in your PowerShell session if using `.yml` or `.yaml` config files

## Config Format
Example:

```yml
watch:
  refreshSeconds: 600
  refreshKey: r

organizations:
  - name: org1
    pat: "$env:PAT_AZDO"
    groups:
      - AD-Group
    projects:
      - ProjectA
      - ProjectB

  - name: org2
    pat: pat-as-string
    groups:
      - Another-Group
    projects:
      - SharedPlatform
```

Fields:
- `name`: Azure DevOps organization name
- `pat`: PAT string or environment variable reference like `"$env:PAT_AZDO"`
- `groups`: reviewer groups to match when using requested-review views
- `projects`: projects to scan in normal configured mode
- `watch.refreshSeconds`: seconds between automatic refreshes when running with `-Watch`; defaults to `600`
- `watch.refreshKey`: key that triggers an immediate refresh in watch mode; defaults to `r`

## Quick Start
1. Copy [sample-config.yml](/mnt/c/source/github/bcullman/AzDO-Multi-Org-PR-View/sample-config.yml) to `config.yml`.
2. Set your Azure DevOps PAT in an environment variable.
3. Add your organizations, PATs, and reviewer groups to `config.yml`.
4. Run the script in discover mode first. For why this is recommended, see [Performance Considerations](#performance-considerations):

```powershell
.\PR-ospector.ps1 -Mode Discover
```

5. Review the output. In YAML config mode, `Discover` also writes any newly found `projects:` entries into `config.yml` automatically.
6. After that, run the script normally:

```powershell
.\PR-ospector.ps1
```

By default, the script looks for `config.yml` in the current directory.

If you want to point at a different file:

```powershell
.\PR-ospector.ps1 -ConfigPath .\config.yml
```

## Performance Considerations
Searching all supplied Azure DevOps organizations and projects for PRs assigned to you can take time. To keep normal runs faster, `PR-ospector.ps1` only searches the projects listed in `config.yml`.

That creates a first-run problem if you are not yet sure which projects you are being called out in. `Discover` mode is meant to solve that. It performs an exhaustive project search across each configured organization, finds projects with matching PR activity, and adds those projects to `config.yml` for future configured-mode runs.

In other words, `Discover` is the slower bootstrap pass, and normal configured mode is the faster day-to-day view.

Group discovery is not exhaustive today. The script assumes you will manage the reviewer groups in `config.yml` yourself. A future version may expand discovery for groups as well, but right now `Discover` helps build your project list, not your group list.

## Usage
Set your PAT in PowerShell:

```powershell
$env:PAT_AZDO = "your-pat-here"
```

Then run:

```powershell
.\PR-ospector.ps1
```

To run the live dashboard with an automatic refresh countdown:

```powershell
.\PR-ospector.ps1 -Watch
```

Useful options:
- `-ConfigPath .\config.yml` to use a different config file
- `-Watch` to keep the dashboard open, refresh on the configured interval, and accept the configured refresh key for an immediate refresh
- `-RefreshSeconds 300` to override `watch.refreshSeconds` for the current watch run
- `-RefreshKey F5` to override `watch.refreshKey` for the current watch run
- `-Mode Discover` to scan all visible projects and write newly found `projects:` entries back into YAML config
- `-View Both` to show both created and requested-review sections
- `-View Created` to show only PRs created by the authenticated user
- `-View ReviewRequested` to show only PRs where review is requested from the authenticated user or configured groups
- `-ReviewState Pending` to keep requested-review results limited to actionable review requests; this is the default
- `-ReviewState All` to include all open requested-review PRs and label their current review status

Direct usage without config is also supported:

```powershell
.\PR-ospector.ps1 -Org org1 -Pat "$env:PAT_AZDO" -Groups AD-Group
```

To see every open requested-review PR instead of only actionable ones:

```powershell
.\PR-ospector.ps1 -View ReviewRequested -ReviewState All
```

When `-Org` is provided, the script uses direct parameters instead of `config.yml`.

Watch mode requires an interactive console because it reads key presses and updates the countdown in place. Press the configured refresh key, `r` by default, to refresh immediately. Press `q` to quit. `-Watch -Mode Discover` is blocked because Discover mode can update YAML config.

## Scheduled Discover Task
To run Discover mode headless on a schedule, use the following to configure a scheduled task (update $repoPath as needed):

```powershell
$repoPath    = 'C:\source\github\<your-GitHub-username>\PR-actical-Tools'
$conhost     = "$env:SystemRoot\System32\conhost.exe"
$pwsh        = 'C:\Program Files\PowerShell\7\pwsh.exe'
$script      = Join-Path $repoPath 'PR-ospector.ps1'
$config      = Join-Path $repoPath 'config.yml'
$startAt     = (Get-Date).Date.AddDays(1).AddHours(7) # start tomorrow at 7:00 AM
$repeatEvery = New-TimeSpan -Hours 2

$action = New-ScheduledTaskAction `
    -Execute $conhost `
    -Argument "--headless `"$pwsh`" -NoProfile -NonInteractive -File `"$script`" -ConfigPath `"$config`" -Mode Discover" `
    -WorkingDirectory $repoPath

$trigger = New-ScheduledTaskTrigger `
    -Once `
    -At $startAt `
    -RepetitionInterval $repeatEvery

Set-ScheduledTask `
    -TaskName 'pr-ospector refresh' `
    -Action $action `
    -Trigger $trigger
```

This updates the existing `pr-ospector refresh` task to start tomorrow at 7:00 AM and repeat every two hours. 

Adjust `$startAt` or `$repeatEvery` as needed. PAT environment variables must be persistent and available to the task's account; session-only values are not inherited.

Normal output is grouped above the org level like this:

```text
CREATED
=======
...

REQUESTED
=========
...
```

By default, the `REQUESTED` section is an actionable review view. It keeps PRs visible when they:
- still need a review vote
- are in `Waiting for author`
- need re-review after new commits, when Azure DevOps marks the reviewer entry accordingly

Settled approvals, declines, and rejects are hidden from the default `REQUESTED` view. Use `-ReviewState All` when you want the broader open-review view instead.

Requested-review entries include a compact `Review:` label such as:
- `Draft`
- `Review Needed`
- `Waiting for author`
- `Re-review Needed`
- `Approved`
- `Approved with suggestions`
- `Rejected`
- `Declined`
