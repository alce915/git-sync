param(
    [string]$ProjectPath = (Get-Location).Path,
    [string]$GitHubUser = $env:GITHUB_USER,
    [string]$RepoName,
    [ValidateSet('public', 'private')]
    [string]$Visibility = 'public',
    [string]$DefaultBranch = 'main',
    [string]$CommitMessage,
    [switch]$CreateRemote,
    [string]$GitHubToken = $env:GITHUB_TOKEN,
    [switch]$SkipCommit,
    [switch]$SkipPush,
    [switch]$DryRun,
    [switch]$PublicInit
)

$ErrorActionPreference = 'Stop'
$scriptBoundParameters = @{} + $PSBoundParameters

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$defaultEnvFile = Join-Path $scriptRoot 'git-sync.env'
$localEnvFile = Join-Path $scriptRoot 'git-sync.local.env'
$projectsRegistryPath = Join-Path $scriptRoot 'projects.json'
$repoNameOverridesPath = Join-Path $scriptRoot 'repo-name-overrides.json'
$repoNameAiSuggesterPath = Join-Path $scriptRoot 'scripts\suggest_repo_name.py'
$repoNameTransliteratorPath = Join-Path $scriptRoot 'scripts\transliterate_repo_name.py'
$processGitHubUser = $env:GITHUB_USER
$processGitHubToken = $env:GITHUB_TOKEN

function Write-Step([string]$Message) {
    Write-Host "[git-sync] $Message" -ForegroundColor Cyan
}

function Test-BoundParameter([string]$Name) {
    return $scriptBoundParameters.ContainsKey($Name)
}

function Read-EnvFile {
    param([string]$Path)

    $values = @{}
    if (-not (Test-Path $Path)) {
        return $values
    }

    Get-Content -Path $Path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#') -or -not $line.Contains('=')) {
            return
        }

        $pair = $line.Split('=', 2)
        $name = $pair[0].Trim()
        $value = $pair[1]
        if ($name -and -not [string]::IsNullOrWhiteSpace($value)) {
            $values[$name] = $value
        }
    }

    return $values
}

function Import-EnvValues {
    param([hashtable]$Values)

    foreach ($entry in $Values.GetEnumerator()) {
        Set-Item -Path "Env:$($entry.Key)" -Value $entry.Value
    }
}

function Resolve-ConfiguredValue {
    param(
        [string]$Name,
        [hashtable]$DefaultValues,
        [hashtable]$LocalValues,
        [string]$FallbackValue
    )

    if ($LocalValues.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace($LocalValues[$Name])) {
        return $LocalValues[$Name]
    }
    if ($DefaultValues.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace($DefaultValues[$Name])) {
        return $DefaultValues[$Name]
    }
    return $FallbackValue
}

function Resolve-ConfiguredValueInfo {
    param(
        [string]$Name,
        [hashtable]$DefaultValues,
        [hashtable]$LocalValues,
        [string]$FallbackValue,
        [string]$ExplicitValue,
        [switch]$WasExplicit
    )

    if ($WasExplicit) {
        return [pscustomobject]@{
            Value = $ExplicitValue
            Source = 'command line parameter'
        }
    }

    if ($LocalValues.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace($LocalValues[$Name])) {
        return [pscustomobject]@{
            Value = $LocalValues[$Name]
            Source = (Split-Path -Leaf $localEnvFile)
        }
    }

    if ($DefaultValues.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace($DefaultValues[$Name])) {
        return [pscustomobject]@{
            Value = $DefaultValues[$Name]
            Source = (Split-Path -Leaf $defaultEnvFile)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($FallbackValue)) {
        return [pscustomobject]@{
            Value = $FallbackValue
            Source = 'process or user environment'
        }
    }

    return [pscustomobject]@{
        Value = $null
        Source = 'not configured'
    }
}

function ConvertTo-Hashtable {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) {
            $result[[string]$key] = ConvertTo-Hashtable -Value $Value[$key]
        }
        return $result
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-Hashtable -Value $property.Value
        }
        return $result
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += ,(ConvertTo-Hashtable -Value $item)
        }
        return $items
    }

    return $Value
}

function Get-RepoNameOverrides {
    if (-not (Test-Path $repoNameOverridesPath)) {
        return @{}
    }

    try {
        $raw = Get-Content -Raw -Path $repoNameOverridesPath
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @{}
        }

        $parsed = ConvertTo-Hashtable -Value ($raw | ConvertFrom-Json)
        if ($parsed) {
            return $parsed
        }
    } catch {
        Write-Step "Ignoring unreadable repo name overrides file: $repoNameOverridesPath"
    }

    return @{}
}

function Test-ContainsCjk {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return [regex]::IsMatch($Value, '[\p{IsCJKUnifiedIdeographs}]')
}

function ConvertTo-RepoSlug {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $slug = $Value.ToLowerInvariant()
    $slug = [regex]::Replace($slug, '[^a-z0-9]+', '-')
    $slug = [regex]::Replace($slug, '-{2,}', '-')
    $slug = $slug.Trim('-')

    if ([string]::IsNullOrWhiteSpace($slug)) {
        return $null
    }

    if ($slug.Length -gt 100) {
        $slug = $slug.Substring(0, 100).Trim('-')
    }

    return $slug
}

function Get-RepoNameFromOverrides {
    param(
        [hashtable]$Overrides,
        [string]$ProjectName
    )

    if (-not $Overrides -or [string]::IsNullOrWhiteSpace($ProjectName)) {
        return $null
    }

    if ($Overrides.ContainsKey($ProjectName)) {
        return ConvertTo-RepoSlug -Value ([string]$Overrides[$ProjectName])
    }

    return $null
}

function Get-TransliteratedRepoName {
    param([string]$ProjectName)

    if (-not (Test-Path $repoNameTransliteratorPath)) {
        return $null
    }

    try {
        $output = Invoke-External -FilePath 'py' -Arguments @('-3', $repoNameTransliteratorPath, $ProjectName) -AllowFailure -SuppressOutput
        return ConvertTo-RepoSlug -Value $output
    } catch {
        return $null
    }
}

function Get-AiSuggestedRepoName {
    param(
        [string]$ProjectPath,
        [string]$ProjectName
    )

    $hasOpenAiKey = -not [string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)
    $hasLocalAiCommand = -not [string]::IsNullOrWhiteSpace($env:REPO_NAME_LOCAL_AI_CMD)
    if (-not $hasOpenAiKey -and -not $hasLocalAiCommand) {
        return $null
    }

    if (-not (Test-Path $repoNameAiSuggesterPath)) {
        return $null
    }

    try {
        $output = Invoke-External -FilePath 'py' -Arguments @('-3', $repoNameAiSuggesterPath, $ProjectPath) -AllowFailure -SuppressOutput
        $suggestedRepoName = ConvertTo-RepoSlug -Value $output
        if ($suggestedRepoName) {
            return $suggestedRepoName
        }
        Write-Step "AI repo naming produced no usable result for '$ProjectName'; falling back to rule-based naming"
        return $null
    } catch {
        Write-Step "AI repo naming failed for '$ProjectName'; falling back to rule-based naming"
        return $null
    }
}

function Get-AutoRepoName {
    param(
        [string]$ProjectPath,
        [string]$ProjectName,
        [hashtable]$Overrides
    )

    $overrideRepoName = Get-RepoNameFromOverrides -Overrides $Overrides -ProjectName $ProjectName
    if ($overrideRepoName) {
        Write-Step "Using repo name override for project '$ProjectName' -> $overrideRepoName"
        return $overrideRepoName
    }

    $asciiSlug = ConvertTo-RepoSlug -Value $ProjectName
    if (-not (Test-ContainsCjk -Value $ProjectName)) {
        return $asciiSlug
    }

    $aiSuggestedRepoName = Get-AiSuggestedRepoName -ProjectPath $ProjectPath -ProjectName $ProjectName
    if ($aiSuggestedRepoName) {
        Write-Step "AI-generated repo name for project '$ProjectName' -> $aiSuggestedRepoName"
        return $aiSuggestedRepoName
    }

    $transliteratedRepoName = Get-TransliteratedRepoName -ProjectName $ProjectName
    if ($transliteratedRepoName) {
        Write-Step "Auto-generated ASCII repo name from Chinese project name '$ProjectName' -> $transliteratedRepoName"
        return $transliteratedRepoName
    }

    if ($asciiSlug) {
        Write-Step "Using sanitized ASCII repo name for '$ProjectName' -> $asciiSlug"
        return $asciiSlug
    }

    $fallbackRepoName = 'project-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Write-Step "Could not transliterate project name '$ProjectName'; falling back to $fallbackRepoName. Pass -RepoName or add repo-name-overrides.json for a better English name."
    return $fallbackRepoName
}

$defaultEnvValues = Read-EnvFile -Path $defaultEnvFile
$localEnvValues = Read-EnvFile -Path $localEnvFile
$repoNameOverrides = Get-RepoNameOverrides
Import-EnvValues -Values $defaultEnvValues
Import-EnvValues -Values $localEnvValues

$gitHubUserInfo = Resolve-ConfiguredValueInfo -Name 'GITHUB_USER' -DefaultValues $defaultEnvValues -LocalValues $localEnvValues -FallbackValue $processGitHubUser -ExplicitValue $GitHubUser -WasExplicit:(Test-BoundParameter 'GitHubUser')
$gitHubTokenInfo = Resolve-ConfiguredValueInfo -Name 'GITHUB_TOKEN' -DefaultValues $defaultEnvValues -LocalValues $localEnvValues -FallbackValue $processGitHubToken -ExplicitValue $GitHubToken -WasExplicit:(Test-BoundParameter 'GitHubToken')

$GitHubUser = $gitHubUserInfo.Value
$GitHubToken = $gitHubTokenInfo.Value

function Join-Args([string[]]$Arguments) {
    return ($Arguments | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join ' '
}

function Invoke-External {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory = $resolvedProject,
        [switch]$AllowFailure,
        [switch]$RunInDryRun,
        [switch]$SuppressOutput
    )

    if ($DryRun -and -not $RunInDryRun) {
        Write-Step "DRY RUN: $FilePath $(Join-Args $Arguments)"
        return ''
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.Arguments = Join-Args $Arguments
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if (-not $SuppressOutput) {
        if ($stdout.Trim()) { Write-Host $stdout.Trim() }
        if ($stderr.Trim()) { Write-Host $stderr.Trim() -ForegroundColor DarkYellow }
    }

    if (-not $AllowFailure -and $process.ExitCode -ne 0) {
        throw "$FilePath exited with code $($process.ExitCode)"
    }

    return $stdout.Trim()
}

function Get-GitBaseArgs {
    $safeDirectory = $resolvedProject -replace '\\', '/'
    return @('-c', "safe.directory=$safeDirectory")
}

function Invoke-Git {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$RunInDryRun,
        [switch]$SuppressOutput
    )

    $gitArgs = (Get-GitBaseArgs) + $Arguments
    return Invoke-External -FilePath 'git' -Arguments $gitArgs -AllowFailure:$AllowFailure -RunInDryRun:$RunInDryRun -SuppressOutput:$SuppressOutput
}

function Get-GitHubExtraHeader {
    param(
        [string]$User,
        [string]$Token
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    $raw = '{0}:{1}' -f $User, $Token
    $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($raw))
    return "AUTHORIZATION: basic $encoded"
}

function Invoke-GitAuthenticated {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$RunInDryRun,
        [switch]$SuppressOutput
    )

    $baseArgs = Get-GitBaseArgs
    $extraHeader = Get-GitHubExtraHeader -User $GitHubUser -Token $GitHubToken
    if ($extraHeader) {
        $baseArgs += @('-c', "http.https://github.com/.extraheader=$extraHeader")
    }
    $gitArgs = $baseArgs + $Arguments
    return Invoke-External -FilePath 'git' -Arguments $gitArgs -AllowFailure:$AllowFailure -RunInDryRun:$RunInDryRun -SuppressOutput:$SuppressOutput
}

function Get-RegisteredProjectInfo {
    param([string]$RepoRoot)

    $projectRemoteFile = Join-Path $RepoRoot 'git-remote.json'
    if (Test-Path $projectRemoteFile) {
        try {
            return Get-Content -Raw -Path $projectRemoteFile | ConvertFrom-Json
        } catch {
            Write-Step "Ignoring unreadable project remote file: $projectRemoteFile"
        }
    }

    if (Test-Path $projectsRegistryPath) {
        try {
            $raw = Get-Content -Raw -Path $projectsRegistryPath
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $entries = @($raw | ConvertFrom-Json)
                return $entries | Where-Object { $_.project_path -eq $RepoRoot } | Select-Object -First 1
            }
        } catch {
            Write-Step "Ignoring unreadable projects registry: $projectsRegistryPath"
        }
    }

    return $null
}

function Get-ExistingOriginUrl {
    param([string]$RepoRoot)

    $gitDir = Join-Path $RepoRoot '.git'
    if (-not (Test-Path $gitDir)) {
        return $null
    }

    try {
        return Invoke-Git -Arguments @('remote', 'get-url', 'origin') -AllowFailure -RunInDryRun -SuppressOutput
    } catch {
        return $null
    }
}

function Get-GitLocalConfigValue {
    param(
        [string]$Name,
        [string]$RepoRoot = $resolvedProject
    )

    $gitDir = Join-Path $RepoRoot '.git'
    if (-not (Test-Path $gitDir)) {
        return $null
    }

    $value = Invoke-Git -Arguments @('config', '--local', '--get', $Name) -AllowFailure -RunInDryRun -SuppressOutput
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value
}

function Get-GitEffectiveConfigValue {
    param(
        [string]$Name,
        [string]$RepoRoot = $resolvedProject
    )

    $gitDir = Join-Path $RepoRoot '.git'
    if (-not (Test-Path $gitDir)) {
        return $null
    }

    $value = Invoke-Git -Arguments @('config', '--get', $Name) -AllowFailure -RunInDryRun -SuppressOutput
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value
}

function Ensure-LocalGitIdentity {
    param(
        [string]$FallbackName,
        [string]$FallbackEmail
    )

    if ($DryRun) {
        return
    }

    $effectiveName = Get-GitEffectiveConfigValue -Name 'user.name' -RepoRoot $resolvedProject
    $effectiveEmail = Get-GitEffectiveConfigValue -Name 'user.email' -RepoRoot $resolvedProject

    if ($effectiveName -and $effectiveEmail) {
        return
    }

    if (-not $effectiveName -and $FallbackName) {
        Write-Step "Configuring repo-local git user.name -> $FallbackName"
        Invoke-Git -Arguments @('config', '--local', 'user.name', $FallbackName)
    }

    if (-not $effectiveEmail -and $FallbackEmail) {
        Write-Step "Configuring repo-local git user.email -> $FallbackEmail"
        Invoke-Git -Arguments @('config', '--local', 'user.email', $FallbackEmail)
    }
}

function Write-GitHubAuthSummary {
    param(
        [string]$User,
        [string]$UserSource,
        [string]$Token,
        [string]$TokenSource,
        [bool]$NeedsToken
    )

    if (-not [string]::IsNullOrWhiteSpace($User)) {
        Write-Step "GitHub auth user: $User (source: $UserSource)"
    } else {
        Write-Step "GitHub auth user: missing (source: $UserSource)"
    }

    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        Write-Step "GitHub auth token: available (source: $TokenSource)"
    } elseif ($NeedsToken) {
        Write-Step "GitHub auth token: missing (source: $TokenSource)"
    } else {
        Write-Step 'GitHub auth token: not required for this run'
    }
}

function Assert-GitHubAuthReady {
    param(
        [string]$User,
        [string]$UserSource,
        [string]$Token,
        [string]$TokenSource,
        [bool]$NeedsToken
    )

    if ([string]::IsNullOrWhiteSpace($User)) {
        throw "GitHubUser is required before syncing. Configure GITHUB_USER in $localEnvFile or $defaultEnvFile, set a process/user environment variable, or pass -GitHubUser."
    }

    if ($NeedsToken -and [string]::IsNullOrWhiteSpace($Token)) {
        throw "GitHubToken is required before pushing or creating a GitHub remote. Configure GITHUB_TOKEN in $localEnvFile, set a process/user environment variable, or pass -GitHubToken. Resolved GitHub user: $User (source: $UserSource)."
    }
}

function Get-GitHubRemoteInfo {
    param([string]$RemoteUrl)

    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
        return $null
    }

    $patterns = @(
        '^https://github\.com/(?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?/?$',
        '^git@github\.com:(?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($RemoteUrl.Trim(), $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            return [pscustomobject]@{
                owner = $match.Groups['owner'].Value
                repo = $match.Groups['repo'].Value
                normalized_url = "https://github.com/$($match.Groups['owner'].Value)/$($match.Groups['repo'].Value).git"
            }
        }
    }

    return $null
}

function Ensure-GitIgnore {
    param([string]$RepoRoot)

    $gitignorePath = Join-Path $RepoRoot '.gitignore'
    $startMarker = '# >>> codex git-sync >>>'
    $endMarker = '# <<< codex git-sync <<<'
    $blockLines = @(
        $startMarker,
        '.venv/',
        '__pycache__/',
        '*.pyc',
        '*.pyo',
        '*.log',
        '.env',
        '.env.*',
        'config/active_account.json',
        'config/binance_accounts.json',
        '*.db',
        '.pytest_cache/',
        '*.egg-info/',
        'tmp_*.py',
        'tmp_*.txt',
        'binance-account-monitor/config/binance_monitor_accounts.json',
        'node_modules/',
        'dist/',
        'build/',
        '.idea/',
        '.vscode/',
        'git-sync.local.env',
        'projects.json',
        'git-remote.json',
        'repo-name-overrides.json',
        $endMarker
    )
    $block = $blockLines -join [Environment]::NewLine

    if ($DryRun) {
        Write-Step "DRY RUN: ensure .gitignore block in $gitignorePath"
        return
    }

    if (-not (Test-Path $gitignorePath)) {
        Set-Content -Path $gitignorePath -Value ($block + [Environment]::NewLine) -Encoding UTF8
        Write-Step '.gitignore created'
        return
    }

    $existing = Get-Content -Raw -Path $gitignorePath
    if ($existing.Contains($startMarker)) {
        $pattern = [regex]::Escape($startMarker) + '.*?' + [regex]::Escape($endMarker)
        $updated = [regex]::Replace($existing, $pattern, $block, 'Singleline')
        Set-Content -Path $gitignorePath -Value $updated -Encoding UTF8
        Write-Step '.gitignore sync block refreshed'
        return
    }

    $prefix = if ($existing.EndsWith([Environment]::NewLine)) { '' } else { [Environment]::NewLine }
    Add-Content -Path $gitignorePath -Value ($prefix + $block + [Environment]::NewLine) -Encoding UTF8
    Write-Step '.gitignore block appended'
}

function Get-CandidateFiles {
    $gitDir = Join-Path $resolvedProject '.git'
    if (-not (Test-Path $gitDir)) {
        return @(
            Get-ChildItem -LiteralPath $resolvedProject -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/]\.git([\\/]|$)' } |
            ForEach-Object {
                $fullPath = $_.FullName
                if ($fullPath.StartsWith($resolvedProject, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $relativePath = $fullPath.Substring($resolvedProject.Length).TrimStart('\')
                    $relativePath -replace '\\', '/'
                }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }

    $listed = Invoke-Git -Arguments @('-c', 'core.quotepath=false', 'ls-files', '--cached', '--others', '--exclude-standard') -AllowFailure -RunInDryRun -SuppressOutput
    if ([string]::IsNullOrWhiteSpace($listed)) {
        return @()
    }
    return @($listed -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-SecretLikeValue {
    param([string]$Value)

    if ($null -eq $Value) {
        return $false
    }

    $candidate = $Value.Trim().Trim('"').Trim("'").TrimEnd(',').Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $false
    }

    $placeholderPattern = '(?i)(your[_ -]?(token|password|secret|key)|example|placeholder|changeme|dummy|test[_ -]?only|main-(key|secret)|sub\d*-(key|secret)|xxxxx+)'
    if ($candidate -match $placeholderPattern) {
        return $false
    }

    if ($candidate -match '^(null|none|false|true)$') {
        return $false
    }

    if ($candidate -match '^[A-Za-z_][A-Za-z0-9_.\[\]]*$') {
        return $false
    }

    return $candidate.Length -ge 12
}

function Test-SensitiveFiles {
    param([string]$RepoRoot)

    $issues = [System.Collections.Generic.List[string]]::new()
    $candidates = Get-CandidateFiles
    $assignmentPatterns = @(
        [regex]'(?i)\b[A-Z0-9_]*(API_KEY|API_SECRET|ACCESS_KEY|ACCESS_SECRET|SECRET|TOKEN|PASSWORD)[A-Z0-9_]*\b\s*[:=]\s*["''](?<value>[^"''\r\n]+)["'']',
        [regex]'^\s*[A-Z0-9_]*(API_KEY|API_SECRET|ACCESS_KEY|ACCESS_SECRET|SECRET|TOKEN|PASSWORD)[A-Z0-9_]*\b\s*[:=]\s*(?<value>[^\s#]+)',
        [regex]'(?i)\bAuthorization\b\s*[:=]\s*["'']Bearer\s+(?<value>[A-Za-z0-9._\-]{12,})["'']'
    )
    $tokenPatterns = @(
        '(?i)gh[pousr]_[A-Za-z0-9]{20,}',
        '(?i)github_pat_[A-Za-z0-9_]{20,}'
    )
    $ignoredExtensions = @(
        '.7z', '.bin', '.bmp', '.class', '.dll', '.dylib', '.exe', '.gif', '.gz', '.ico', '.jar',
        '.jpeg', '.jpg', '.lock', '.mp3', '.mp4', '.pdf', '.png', '.pyc', '.pyd', '.so', '.tar',
        '.wav', '.webp', '.woff', '.woff2', '.zip'
    )
    $ignoredNamePatterns = @('package-lock.json', 'pnpm-lock.yaml', 'yarn.lock')

    foreach ($relative in $candidates) {
        $full = Join-Path $RepoRoot $relative
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $fileName = [IO.Path]::GetFileName($relative)
        if ($ignoredNamePatterns -contains $fileName) { continue }
        $extension = [IO.Path]::GetExtension($relative)
        if ($ignoredExtensions -contains $extension) { continue }
        try {
            $raw = Get-Content -Raw -LiteralPath $full -ErrorAction Stop
        } catch {
            continue
        }
        if ($null -eq $raw) {
            $raw = ''
        }

        $matchedToken = $false
        foreach ($tokenPattern in $tokenPatterns) {
            if ($raw -match $tokenPattern) {
                $issues.Add("GitHub token marker matched in $relative")
                $matchedToken = $true
                break
            }
        }
        if ($matchedToken) { continue }

        if ($raw.IndexOf([char]0) -ge 0) {
            continue
        }

        foreach ($line in ($raw -split "`r?`n")) {
            foreach ($pattern in $assignmentPatterns) {
                $match = $pattern.Match($line)
                if ($match.Success -and (Test-SecretLikeValue -Value $match.Groups['value'].Value)) {
                    $issues.Add("Sensitive assignment matched in $relative")
                    break
                }
            }
            if ($issues -contains "Sensitive assignment matched in $relative") { break }
        }
    }

    return @($issues | Select-Object -Unique)
}
function Ensure-RemoteRepository {
    param(
        [string]$Owner,
        [string]$Name,
        [string]$Token,
        [bool]$Public
    )

    if (-not $CreateRemote) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw 'CreateRemote requires GitHubToken or GITHUB_TOKEN.'
    }

    $headers = @{
        Authorization = "Bearer $Token"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'codex-git-sync'
    }

    $repoUrl = "https://api.github.com/repos/$Owner/$Name"
    $exists = $false
    try {
        if (-not $DryRun) {
            Invoke-RestMethod -Method Get -Uri $repoUrl -Headers $headers | Out-Null
        }
        $exists = $true
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -ne 404) {
            throw
        }
    }

    if ($exists) {
        Write-Step "Remote repository $Owner/$Name already exists"
        return
    }

    if ($DryRun) {
        Write-Step "DRY RUN: create GitHub repository $Owner/$Name ($Visibility)"
        return
    }

    $body = @{
        name = $Name
        private = -not $Public
        auto_init = $false
    } | ConvertTo-Json

    Invoke-RestMethod -Method Post -Uri 'https://api.github.com/user/repos' -Headers $headers -Body $body -ContentType 'application/json' | Out-Null
    Write-Step "Remote repository $Owner/$Name created"
}

function Write-ProjectRegistry {
    param(
        [string]$RepoRoot,
        [string]$RemoteUrl,
        [string]$VisibilityValue,
        [string]$Branch
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    $projectEntry = [ordered]@{
        project_name = (Split-Path -Leaf $RepoRoot)
        project_path = $RepoRoot
        git_remote_url = $RemoteUrl
        visibility = $VisibilityValue
        last_synced_at = $timestamp
    }

    $projectFileEntry = [ordered]@{
        project_name = (Split-Path -Leaf $RepoRoot)
        project_path = $RepoRoot
        git_remote_url = $RemoteUrl
        visibility = $VisibilityValue
        default_branch = $Branch
    }

    if ($DryRun) {
        Write-Step "DRY RUN: update central registry $projectsRegistryPath"
        Write-Step "DRY RUN: write project remote file $(Join-Path $RepoRoot 'git-remote.json')"
        return
    }

    if (-not (Test-Path $projectsRegistryPath)) {
        Set-Content -Path $projectsRegistryPath -Value '[]' -Encoding UTF8
    }

    $registry = @()
    $raw = Get-Content -Raw -Path $projectsRegistryPath
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $parsed = $raw | ConvertFrom-Json
        if ($null -ne $parsed) {
            if ($parsed -is [System.Collections.IEnumerable] -and -not ($parsed -is [string])) {
                $registry = @($parsed)
            } else {
                $registry = @($parsed)
            }
        }
    }

    $filtered = @($registry | Where-Object { $_.project_path -ne $RepoRoot })
    $filtered += [pscustomobject]$projectEntry
    $filtered | ConvertTo-Json -Depth 4 | Set-Content -Path $projectsRegistryPath -Encoding UTF8

    ([pscustomobject]$projectFileEntry | ConvertTo-Json -Depth 4) | Set-Content -Path (Join-Path $RepoRoot 'git-remote.json') -Encoding UTF8
    Write-Step 'Project registry files updated'
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git is not installed or not available in PATH.'
}

$resolvedProject = (Resolve-Path -LiteralPath $ProjectPath).Path
$projectName = Split-Path -Leaf $resolvedProject
$gitDir = Join-Path $resolvedProject '.git'
$registeredProjectInfo = Get-RegisteredProjectInfo -RepoRoot $resolvedProject
$registeredRemoteInfo = if ($registeredProjectInfo) { Get-GitHubRemoteInfo -RemoteUrl $registeredProjectInfo.git_remote_url } else { $null }
$existingOriginUrl = Get-ExistingOriginUrl -RepoRoot $resolvedProject
$existingOriginInfo = Get-GitHubRemoteInfo -RemoteUrl $existingOriginUrl
$inferredRemoteInfo = if ($registeredRemoteInfo) { $registeredRemoteInfo } else { $existingOriginInfo }
$existingLocalGitUserName = Get-GitLocalConfigValue -Name 'user.name' -RepoRoot $resolvedProject
$existingLocalGitUserEmail = Get-GitLocalConfigValue -Name 'user.email' -RepoRoot $resolvedProject

if (-not (Test-BoundParameter 'GitHubUser') -and $inferredRemoteInfo) {
    $GitHubUser = $inferredRemoteInfo.owner
    $gitHubUserInfo = [pscustomobject]@{
        Value = $GitHubUser
        Source = 'existing GitHub remote metadata'
    }
}
if (-not $RepoName) {
    if ($inferredRemoteInfo) {
        $RepoName = $inferredRemoteInfo.repo
    } else {
        $RepoName = Get-AutoRepoName -ProjectPath $resolvedProject -ProjectName $projectName -Overrides $repoNameOverrides
    }
}
if (-not $CommitMessage) {
    $CommitMessage = 'public backup: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
}
$defaultGitUserName = if ($existingLocalGitUserName) { $existingLocalGitUserName } elseif ($GitHubUser) { $GitHubUser } else { $null }
$defaultGitUserEmail = if ($existingLocalGitUserEmail) { $existingLocalGitUserEmail } elseif ($GitHubUser) { "$GitHubUser@users.noreply.github.com" } else { $null }
$needsGitHubToken = (-not $SkipPush) -or $CreateRemote

Assert-GitHubAuthReady -User $GitHubUser -UserSource $gitHubUserInfo.Source -Token $GitHubToken -TokenSource $gitHubTokenInfo.Source -NeedsToken:$needsGitHubToken
Write-GitHubAuthSummary -User $GitHubUser -UserSource $gitHubUserInfo.Source -Token $GitHubToken -TokenSource $gitHubTokenInfo.Source -NeedsToken:$needsGitHubToken

$remoteHttps = if ($inferredRemoteInfo -and -not (Test-BoundParameter 'RepoName') -and -not (Test-BoundParameter 'GitHubUser')) {
    $inferredRemoteInfo.normalized_url
} else {
    "https://github.com/$GitHubUser/$RepoName.git"
}

Write-Step "Project: $resolvedProject"
Write-Step "GitHub repo: $GitHubUser/$RepoName"
Write-Step "Visibility: $Visibility"

Ensure-GitIgnore -RepoRoot $resolvedProject

if (-not (Test-Path $gitDir)) {
    Write-Step 'Initializing git repository'
    Invoke-External -FilePath 'git' -Arguments @('init', '--initial-branch', $DefaultBranch) -WorkingDirectory $resolvedProject
} else {
    Write-Step 'Git repository already exists'
}

$sensitiveIssues = Test-SensitiveFiles -RepoRoot $resolvedProject
if ($sensitiveIssues.Count -gt 0) {
    $message = ($sensitiveIssues | ForEach-Object { "- $_" }) -join [Environment]::NewLine
    throw "Sensitive content check failed:`n$message"
}

$publicInitBackupDir = $null
$shouldRestorePublicInit = $false

try {
    if ($PublicInit) {
        Write-Step 'PublicInit enabled: rebuilding repository history from current sanitized working tree'
        if ($DryRun) {
            Write-Step "DRY RUN: replace $gitDir with a clean repository after validation succeeds"
        } elseif (Test-Path $gitDir) {
            $backupRoot = Split-Path -Parent $resolvedProject
            $backupName = ((Split-Path -Leaf $resolvedProject) + '.git.codex-backup-' + (Get-Date -Format 'yyyyMMddHHmmss'))
            $publicInitBackupDir = Join-Path $backupRoot $backupName
            Move-Item -LiteralPath $gitDir -Destination $publicInitBackupDir
            $shouldRestorePublicInit = $true
        }
    }

    if ($PublicInit -and -not $DryRun) {
        Write-Step 'Initializing clean git repository'
        Invoke-External -FilePath 'git' -Arguments @('init', '--initial-branch', $DefaultBranch) -WorkingDirectory $resolvedProject
        if ($existingLocalGitUserName) {
            Invoke-Git -Arguments @('config', '--local', 'user.name', $existingLocalGitUserName)
        }
        if ($existingLocalGitUserEmail) {
            Invoke-Git -Arguments @('config', '--local', 'user.email', $existingLocalGitUserEmail)
        }
    }

    $currentBranch = Invoke-Git -Arguments @('branch', '--show-current') -AllowFailure -RunInDryRun -SuppressOutput
    if (-not [string]::IsNullOrWhiteSpace($currentBranch) -and $currentBranch -ne $DefaultBranch) {
        Write-Step "Switching branch to $DefaultBranch"
        Invoke-Git -Arguments @('branch', '-M', $DefaultBranch)
    }

    Ensure-RemoteRepository -Owner $GitHubUser -Name $RepoName -Token $GitHubToken -Public:($Visibility -eq 'public')

    $remoteExists = $true
    try {
        Invoke-Git -Arguments @('remote', 'get-url', 'origin') -RunInDryRun -SuppressOutput | Out-Null
    } catch {
        $remoteExists = $false
    }

    if (-not $remoteExists) {
        Write-Step "Adding remote origin -> $remoteHttps"
        Invoke-Git -Arguments @('remote', 'add', 'origin', $remoteHttps)
    } else {
        $currentRemote = Invoke-Git -Arguments @('remote', 'get-url', 'origin') -RunInDryRun -SuppressOutput
        if ($currentRemote -ne $remoteHttps) {
            Write-Step "Updating origin -> $remoteHttps"
            Invoke-Git -Arguments @('remote', 'set-url', 'origin', $remoteHttps)
        }
    }

    if (Test-Path $gitDir) {
        Ensure-LocalGitIdentity -FallbackName $defaultGitUserName -FallbackEmail $defaultGitUserEmail
    }

    if (-not $SkipCommit) {
        if ($DryRun) {
            Write-Step 'DRY RUN: git add .'
            $status = if (Test-Path $gitDir) {
                Invoke-Git -Arguments @('status', '--porcelain') -AllowFailure -RunInDryRun -SuppressOutput
            } else {
                'new repository'
            }

            if (-not [string]::IsNullOrWhiteSpace($status)) {
                Write-Step "DRY RUN: create commit: $CommitMessage"
            } else {
                Write-Step 'DRY RUN: no changes to commit'
            }
        } else {
            Invoke-Git -Arguments @('add', '.')
            $status = Invoke-Git -Arguments @('status', '--porcelain') -RunInDryRun -SuppressOutput
            if (-not [string]::IsNullOrWhiteSpace($status)) {
                Write-Step "Creating commit: $CommitMessage"
                Invoke-Git -Arguments @('commit', '-m', $CommitMessage)
            } else {
                Write-Step 'No changes to commit'
            }
        }
    }

    if (-not $SkipPush) {
        Write-Step 'Pushing to GitHub (HTTPS)'
        Invoke-GitAuthenticated -Arguments @('push', '-u', 'origin', $DefaultBranch)
    } else {
        Write-Step 'SkipPush enabled; push not executed'
    }

    $shouldRestorePublicInit = $false

    if (-not $DryRun -and -not $SkipPush) {
        Write-ProjectRegistry -RepoRoot $resolvedProject -RemoteUrl $remoteHttps -VisibilityValue $Visibility -Branch $DefaultBranch
    } else {
        Write-Step 'Skipping registry update because the push was skipped or this was a dry run'
    }

    if ($publicInitBackupDir -and -not $DryRun -and (Test-Path $publicInitBackupDir)) {
        Remove-Item -LiteralPath $publicInitBackupDir -Recurse -Force
        $shouldRestorePublicInit = $false
    }

    Write-Step 'Done'
} catch {
    if ($shouldRestorePublicInit -and $publicInitBackupDir -and (Test-Path $publicInitBackupDir)) {
        Write-Step 'Restoring original repository metadata after failed PublicInit'
        if (Test-Path $gitDir) {
            Remove-Item -LiteralPath $gitDir -Recurse -Force
        }
        Move-Item -LiteralPath $publicInitBackupDir -Destination $gitDir
    }
    throw
}




