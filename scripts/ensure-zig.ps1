param(
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'

$Version = '0.17.0-dev.305+bdfbf432d'
$ZipName = "zig-x86_64-windows-$Version.zip"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$RepoToolchain = Join-Path $RepoRoot ".zig\$Version"
$RepoZig = Join-Path $RepoToolchain 'zig.exe'
$DownloadsZig = Join-Path $env:USERPROFILE "Downloads\zig-x86_64-windows-$Version\zig.exe"
$ToolchainUrl = "https://ziglang.org/builds/$ZipName"

if ($env:ZIG_EXE -and (Test-Path -LiteralPath $env:ZIG_EXE)) {
    if (-not $Quiet) { Write-Host "Using ZIG_EXE=$env:ZIG_EXE" }
    Write-Output $env:ZIG_EXE
    exit 0
}

if (Test-Path -LiteralPath $RepoZig) {
    if (-not $Quiet) { Write-Host "Using repo Zig toolchain: $RepoZig" }
    Write-Output $RepoZig
    exit 0
}

if (Test-Path -LiteralPath $DownloadsZig) {
    if (-not $Quiet) { Write-Host "Using Downloads Zig toolchain: $DownloadsZig" }
    Write-Output $DownloadsZig
    exit 0
}

$ToolchainRoot = Join-Path $RepoRoot '.zig'
$ZipPath = Join-Path $ToolchainRoot $ZipName
New-Item -ItemType Directory -Force -Path $ToolchainRoot | Out-Null

if (-not (Test-Path -LiteralPath $ZipPath)) {
    if (-not $Quiet) { Write-Host "Downloading Zig $Version..." }
    Invoke-WebRequest -Uri $ToolchainUrl -OutFile $ZipPath
}

if (-not (Test-Path -LiteralPath $RepoZig)) {
    if (-not $Quiet) { Write-Host "Extracting Zig to $ToolchainRoot..." }
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $ToolchainRoot -Force
}

if (-not (Test-Path -LiteralPath $RepoZig)) {
    throw "Zig toolchain was not found after extraction: $RepoZig"
}

Write-Output $RepoZig
