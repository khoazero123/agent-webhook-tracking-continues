#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$RepoHttps = "https://github.com/khoazero123/agent-webhook-tracking-continues.git"
$RawBase = "https://raw.githubusercontent.com/khoazero123/agent-webhook-tracking-continues/main"
$script:HookUtf8 = [System.Text.UTF8Encoding]::new($false)

function Set-InstallerConsoleEncoding {
    try { [Console]::InputEncoding = $script:HookUtf8 } catch {}
    try { [Console]::OutputEncoding = $script:HookUtf8 } catch {}
    $script:OutputEncoding = $script:HookUtf8
    if ($Host.Name -eq "ConsoleHost") {
        try {
            $null = cmd.exe /c "chcp 65001 >nul"
        }
        catch {}
    }
}

function Get-JsonSerializer {
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = 104857600
    return $serializer
}

function Read-DefaultConfig([string]$RepoRoot) {
    $defaultsPath = Join-Path $RepoRoot "config.defaults.json"
    $json = [System.IO.File]::ReadAllText($defaultsPath, $script:HookUtf8)
    return ($json | ConvertFrom-Json)
}

function Build-LocaleDefaults {
    param(
        [object]$Config,
        [string]$Locale
    )

    $localeProperty = $Config.locales.PSObject.Properties[$Locale]
    if ($null -eq $localeProperty) {
        $Locale = "en"
    }

    $localeConfig = $Config.locales.$Locale
    return [pscustomobject]@{
        locale             = $Locale
        keywords           = @($localeConfig.keywords | ForEach-Object { [string]$_ })
        continue_message   = [string]$localeConfig.continue_message
        tail_length        = [int]$Config.tail_length
        max_continue_loops = [int]$Config.max_continue_loops
    }
}

Set-InstallerConsoleEncoding

function Write-Info([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "OK  $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Host "!!  $Message" -ForegroundColor Yellow
}

function Get-RepoRoot {
    $localRoot = $PSScriptRoot
    if (-not [string]::IsNullOrWhiteSpace($localRoot) -and (Test-Path (Join-Path $localRoot "runtime\windows\hook-lib.ps1"))) {
        return (Resolve-Path $localRoot).Path
    }

    Write-Info "Downloading repo to a temp directory..."
    $tempRoot = Join-Path $env:TEMP ("agent-webhook-install-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        & git clone --depth 1 $RepoHttps (Join-Path $tempRoot "repo") | Out-Null
        return (Resolve-Path (Join-Path $tempRoot "repo")).Path
    }

    $zipPath = Join-Path $tempRoot "repo.zip"
    Invoke-WebRequest -Uri "$RawBase/archive/refs/heads/main.zip" -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $tempRoot -Force
    return (Resolve-Path (Join-Path $tempRoot "agent-webhook-tracking-continues-main")).Path
}

function Test-VietnameseText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return [regex]::IsMatch(
        $Text,
        '[\u00C0-\u00C3\u00C8-\u00CA\u00CC-\u00CD\u00D2-\u00D5\u00D9-\u00DA\u00DD\u0102\u0103\u0110\u0111\u0128\u0129\u0168\u0169\u01A0\u01A1\u01AF\u01B0\u1EA0-\u1EF9]'
    )
}

function Get-NormalizedUserText {
    param([string]$Text)
    if ($Text -match '(?is)<user_query>\s*(.*?)\s*</user_query>') {
        return $Matches[1].Trim()
    }
    return $Text.Trim()
}

function Test-SkipTranscriptText {
    param([string]$Text)
    $trimmed = $Text.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return $true }
    $prefixes = @(
        '<environment_context>',
        '<permissions',
        '<app-context>',
        '<collaboration_mode>',
        '<skills_instructions>',
        '<plugins_instructions>'
    )
    foreach ($prefix in $prefixes) {
        if ($trimmed.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-TranscriptTextFromCursorLine {
    param([string]$Line)
    try {
        $obj = $Line | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return ""
    }
    if ($obj.role -notin @("user", "assistant")) { return "" }
    $chunks = @()
    $content = @($obj.message.content)
    foreach ($part in $content) {
        if ($part.type -ne "text") { continue }
        $text = [string]$part.text
        if (Test-SkipTranscriptText -Text $text) { continue }
        $chunks += (Get-NormalizedUserText -Text $text)
    }
    return ($chunks -join "`n")
}

function Get-TranscriptTextFromCodexLine {
    param([string]$Line)
    try {
        $obj = $Line | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return ""
    }
    if ($obj.type -ne "response_item") { return "" }
    if ($obj.payload.type -ne "message") { return "" }
    if ($obj.payload.role -notin @("user", "assistant")) { return "" }
    $chunks = @()
    $content = @($obj.payload.content)
    foreach ($part in $content) {
        if ($part.type -notin @("input_text", "output_text", "text")) { continue }
        $text = [string]$part.text
        if (Test-SkipTranscriptText -Text $text) { continue }
        $chunks += (Get-NormalizedUserText -Text $text)
    }
    return ($chunks -join "`n")
}

function Find-TranscriptFiles {
    $files = New-Object System.Collections.Generic.List[string]
    $cursorRoot = Join-Path $env:USERPROFILE ".cursor\projects"
    if (Test-Path $cursorRoot) {
        Get-ChildItem -Path $cursorRoot -Filter "*.jsonl" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "agent-transcripts" } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 40 |
            ForEach-Object { $files.Add($_.FullName) | Out-Null }
    }

    $codexRoots = @((Join-Path $env:USERPROFILE ".codex"))
    if ($env:CODEX_HOME) { $codexRoots += $env:CODEX_HOME }
    foreach ($codexRoot in ($codexRoots | Select-Object -Unique)) {
        $sessionsRoot = Join-Path $codexRoot "sessions"
        if (-not (Test-Path $sessionsRoot)) { continue }
        Get-ChildItem -Path $sessionsRoot -Filter "*.jsonl" -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 40 |
            ForEach-Object { $files.Add($_.FullName) | Out-Null }
    }

    return @($files | Select-Object -Unique)
}

function Detect-LocaleFromTranscripts {
    $files = Find-TranscriptFiles
    if ($files.Count -eq 0) { return "en" }

    $sampledBytes = 0
    $maxBytes = 512000
    foreach ($file in $files) {
        if ($sampledBytes -ge $maxBytes) { break }
        try {
            $reader = [System.IO.File]::OpenText($file)
            try {
                while (($line = $reader.ReadLine()) -ne $null) {
                    if ($sampledBytes -ge $maxBytes) { break }
                    $text = Get-TranscriptTextFromCursorLine -Line $line
                    if ([string]::IsNullOrWhiteSpace($text)) {
                        $text = Get-TranscriptTextFromCodexLine -Line $line
                    }
                    if ([string]::IsNullOrWhiteSpace($text)) { continue }
                    $sampledBytes += [System.Text.Encoding]::UTF8.GetByteCount($text)
                    if (Test-VietnameseText -Text $text) {
                        return "vi"
                    }
                }
            }
            finally {
                $reader.Close()
            }
        }
        catch {
            continue
        }
    }

    return "en"
}

function Resolve-LocaleDefaults {
    param([string]$RepoRoot)

    $locale = Detect-LocaleFromTranscripts
    $config = Read-DefaultConfig -RepoRoot $RepoRoot
    return (Build-LocaleDefaults -Config $config -Locale $locale)
}

function Prompt-WebhookUrl {
    Write-Host ""
    Write-Host "Webhook URL (leave empty to disable webhooks):" -ForegroundColor White
    $url = Read-Host "Webhook URL"
    return $url.Trim()
}

function Prompt-Keywords([object]$Defaults) {
    Write-Host ""
    Write-Host "Auto-continue keywords (comma-separated, Enter = default):" -ForegroundColor White
    Write-Host "Detected locale: $($Defaults.locale)" -ForegroundColor DarkGray
    if ($Defaults.locale -eq "vi") {
        Write-Host "Default: Vietnamese keyword set (5 configured phrases)" -ForegroundColor DarkGray
    }
    else {
        $defaultText = ($Defaults.keywords -join ", ")
        Write-Host "Default: $defaultText" -ForegroundColor DarkGray
    }
    $input = Read-Host "Keywords"
    if ([string]::IsNullOrWhiteSpace($input)) {
        return @($Defaults.keywords)
    }
    return @($input.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Prompt-ContinueMessage {
    param([object]$Defaults)

    Write-Host ""
    Write-Host "Auto-continue prompt sent when keywords match (Enter = default):" -ForegroundColor White
    Write-Host "Detected locale: $($Defaults.locale)" -ForegroundColor DarkGray
    Write-Host "Default: $($Defaults.continue_message)" -ForegroundColor DarkGray
    $input = Read-Host "Continue prompt"
    if ([string]::IsNullOrWhiteSpace($input)) {
        return [string]$Defaults.continue_message
    }
    return $input.Trim()
}

function Prompt-YesNo([string]$Question, [bool]$DefaultYes = $true) {
    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    $answer = Read-Host "$Question $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $DefaultYes
    }
    return @("y", "yes") -contains $answer.Trim().ToLowerInvariant()
}

function New-HookConfigJson {
    param(
        [string]$WebhookUrl,
        [string]$Source,
        [object[]]$Keywords,
        [object]$Defaults
    )

    $payload = @{
        source             = $Source
        webhook_url        = $WebhookUrl
        keywords           = @($Keywords)
        tail_length        = [int]$Defaults.tail_length
        continue_message   = [string]$Defaults.continue_message
        max_continue_loops = [int]$Defaults.max_continue_loops
    }
    $serializer = Get-JsonSerializer
    return $serializer.Serialize($payload)
}

function Install-CursorHooks {
    param(
        [string]$RepoRoot,
        [string]$WebhookUrl,
        [object[]]$Keywords,
        [object]$Defaults
    )

    $cursorRoot = Join-Path $env:USERPROFILE ".cursor"
    $hooksDir = Join-Path $cursorRoot "hooks"
    New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null

    $runtimeDir = Join-Path $RepoRoot "runtime\windows"
    Copy-Item -Path (Join-Path $runtimeDir "hook-lib.ps1") -Destination $hooksDir -Force
    Copy-Item -Path (Join-Path $runtimeDir "webhook-on-prompt.*") -Destination $hooksDir -Force
    Copy-Item -Path (Join-Path $runtimeDir "webhook-on-response.*") -Destination $hooksDir -Force
    Copy-Item -Path (Join-Path $runtimeDir "auto-continue-flag.*") -Destination $hooksDir -Force
    Copy-Item -Path (Join-Path $runtimeDir "auto-continue-stop.*") -Destination $hooksDir -Force

    $configJson = New-HookConfigJson -WebhookUrl $WebhookUrl -Source "cursor" -Keywords $Keywords -Defaults $Defaults
    [System.IO.File]::WriteAllText((Join-Path $hooksDir "hook-config.json"), $configJson, $script:HookUtf8)

    $hooksJson = @{
        version = 1
        hooks   = @{
            beforeSubmitPrompt = @(
                @{ command = "./hooks/webhook-on-prompt.cmd"; timeout = 15 }
            )
            afterAgentResponse = @(
                @{ command = "./hooks/webhook-on-response.cmd"; timeout = 15 },
                @{ command = "./hooks/auto-continue-flag.cmd"; timeout = 10 }
            )
            stop = @(
                @{ command = "./hooks/auto-continue-stop.cmd"; timeout = 10; loop_limit = [int]$Defaults.max_continue_loops }
            )
        }
    }

    $hooksPath = Join-Path $cursorRoot "hooks.json"
    $hooksText = ($hooksJson | ConvertTo-Json -Depth 6)
    [System.IO.File]::WriteAllText($hooksPath, $hooksText, $script:HookUtf8)
    Write-Ok "Installed Cursor hooks at $hooksDir"
}

function Install-CodexHooks {
    param(
        [string]$RepoRoot,
        [string]$WebhookUrl,
        [object[]]$Keywords,
        [object]$Defaults
    )

    $codexRoot = Join-Path $env:USERPROFILE ".codex"
    $hooksDir = Join-Path $codexRoot "hooks"
    New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null

    $runtimeDir = Join-Path $RepoRoot "runtime\windows"
    Copy-Item -Path (Join-Path $runtimeDir "hook-lib.ps1") -Destination $hooksDir -Force
    Copy-Item -Path (Join-Path $runtimeDir "codex-user-prompt-webhook.*") -Destination $hooksDir -Force
    Copy-Item -Path (Join-Path $runtimeDir "codex-stop-webhook-continue.*") -Destination $hooksDir -Force

    $configJson = New-HookConfigJson -WebhookUrl $WebhookUrl -Source "codex" -Keywords $Keywords -Defaults $Defaults
    [System.IO.File]::WriteAllText((Join-Path $hooksDir "hook-config.json"), $configJson, $script:HookUtf8)

    $promptPs1 = (Join-Path $hooksDir "codex-user-prompt-webhook.ps1")
    $stopPs1 = (Join-Path $hooksDir "codex-stop-webhook-continue.ps1")
    $promptCmd = (Join-Path $hooksDir "codex-user-prompt-webhook.cmd")
    $stopCmd = (Join-Path $hooksDir "codex-stop-webhook-continue.cmd")

    $hooksJson = @{
        hooks = @{
            UserPromptSubmit = @(
                @{
                    hooks = @(
                        @{
                            type            = "command"
                            command         = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$promptPs1`""
                            commandWindows  = $promptCmd
                            timeout         = 15
                            statusMessage   = "Webhook user prompt"
                        }
                    )
                }
            )
            Stop = @(
                @{
                    hooks = @(
                        @{
                            type            = "command"
                            command         = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$stopPs1`""
                            commandWindows  = $stopCmd
                            timeout         = 15
                            statusMessage   = "Webhook + auto continue"
                        }
                    )
                }
            )
        }
    }

    $hooksPath = Join-Path $codexRoot "hooks.json"
    $hooksText = ($hooksJson | ConvertTo-Json -Depth 8)
    [System.IO.File]::WriteAllText($hooksPath, $hooksText, $script:HookUtf8)
    Write-Ok "Installed Codex hooks at $hooksDir"
    Write-Warn "In Codex, run /hooks to trust hooks after installing."
}

Write-Host ""
Write-Host "Agent Webhook + Auto Continue Installer (Windows)" -ForegroundColor Magenta
Write-Host "=================================================" -ForegroundColor Magenta

$repoRoot = Get-RepoRoot
Write-Info "Scanning Cursor/Codex transcripts to detect conversation language..."
$defaults = Resolve-LocaleDefaults -RepoRoot $repoRoot
Write-Ok "Using $($defaults.locale) locale defaults"

$webhookUrl = Prompt-WebhookUrl
$keywords = Prompt-Keywords -Defaults $defaults
$defaults.continue_message = Prompt-ContinueMessage -Defaults $defaults

$installCursor = Prompt-YesNo "Install for Cursor?" $true
$installCodex = Prompt-YesNo "Install for Codex?" $true

if (-not $installCursor -and -not $installCodex) {
    Write-Warn "No tools selected. Exiting."
    exit 1
}

if ($installCursor) {
    Install-CursorHooks -RepoRoot $repoRoot -WebhookUrl $webhookUrl -Keywords $keywords -Defaults $defaults
}

if ($installCodex) {
    Install-CodexHooks -RepoRoot $repoRoot -WebhookUrl $webhookUrl -Keywords $keywords -Defaults $defaults
}

Write-Host ""
Write-Ok "Installation complete. Restart Cursor/Codex to apply hooks."
if ([string]::IsNullOrWhiteSpace($webhookUrl)) {
    Write-Warn "Webhooks disabled (empty URL). Auto-continue only."
}
