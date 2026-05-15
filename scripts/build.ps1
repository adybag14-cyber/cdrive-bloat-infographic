param(
    [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')]
    [string] $Optimize = 'ReleaseSafe'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$Zig = & (Join-Path $PSScriptRoot 'ensure-zig.ps1') -Quiet

Push-Location $RepoRoot
try {
    & $Zig build "-Doptimize=$Optimize"
}
finally {
    Pop-Location
}
