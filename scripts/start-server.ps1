param(
    [string] $Root = 'C:\',
    [int] $Port = 8277,
    [int] $FileLimit = 240,
    [int] $GroupLimit = 140,
    [switch] $Open,
    [switch] $NoBuild
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$RunDir = Join-Path $RepoRoot 'run'
$OutLog = Join-Path $RunDir 'server.out.log'
$ErrLog = Join-Path $RunDir 'server.err.log'

New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

if (-not $NoBuild) {
    & (Join-Path $PSScriptRoot 'build.ps1') -Optimize ReleaseSafe
}

$Exe = Join-Path $RepoRoot 'zig-out\bin\cdrive-bloat-infographic.exe'
if (-not (Test-Path -LiteralPath $Exe)) {
    throw "Built executable was not found: $Exe"
}

Remove-Item -LiteralPath $OutLog, $ErrLog -Force -ErrorAction SilentlyContinue

$Args = @('--root', $Root, '--port', "$Port", '--file-limit', "$FileLimit", '--group-limit', "$GroupLimit")
$Process = Start-Process -FilePath $Exe -ArgumentList $Args -WorkingDirectory $RepoRoot -PassThru -WindowStyle Hidden -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog

Write-Host "Started cdrive-bloat-infographic PID $($Process.Id)"
Write-Host "Scanning can take a while on a full C: drive. Logs:"
Write-Host "  $OutLog"
Write-Host "  $ErrLog"

$Url = $null
$Deadline = (Get-Date).AddMinutes(30)
while ((Get-Date) -lt $Deadline) {
    if ($Process.HasExited) {
        $err = if (Test-Path -LiteralPath $ErrLog) { Get-Content -LiteralPath $ErrLog -Tail 80 | Out-String } else { '' }
        throw "Server exited before becoming ready. $err"
    }

    $combined = ''
    if (Test-Path -LiteralPath $OutLog) { $combined += (Get-Content -LiteralPath $OutLog -Tail 80 | Out-String) }
    if (Test-Path -LiteralPath $ErrLog) { $combined += (Get-Content -LiteralPath $ErrLog -Tail 80 | Out-String) }
    if ($combined -match 'Infographic ready:\s+(http://127\.0\.0\.1:\d+/)') {
        $Url = $Matches[1]
        break
    }
    Start-Sleep -Seconds 2
}

if (-not $Url) {
    throw "Timed out waiting for server readiness. The scan may still be running; inspect $ErrLog"
}

Write-Host "Ready: $Url"

if ($Open) {
    $ChromeCandidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    if ($ChromeCandidates.Count -gt 0) {
        Start-Process -FilePath $ChromeCandidates[0] -ArgumentList $Url
    }
    else {
        Start-Process $Url
    }
}

Write-Output $Url
