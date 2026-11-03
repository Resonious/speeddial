# Refresh dependencies and plugin links before every Windows build, including
# after git pull. Junctions work without Developer Mode or an elevated shell.
[CmdletBinding()]
param(
    [ValidateSet('Run', 'Build', 'Prepare')]
    [string]$Action = 'Run',
    [ValidateSet('release', 'debug', 'profile')]
    [string]$Configuration = 'release',
    [string]$Flutter = 'flutter'
)

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This script requires Windows.' }
$appRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../packages/app'))
$flutterCommand = (Get-Command $Flutter -ErrorAction Stop).Source
Push-Location $appRoot
try {
    # Flutter may fail after successfully resolving packages if symlink creation
    # is unavailable. Only that specific failure is recoverable with junctions.
    # Windows PowerShell 5 represents redirected native stderr as ErrorRecords.
    # Inspect the exit code ourselves rather than terminating on that stream.
    $savedErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $pubOutput = & $flutterCommand pub get 2>&1
        $pubExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorPreference
    }
    $pubOutput | ForEach-Object { Write-Host "$_" }
    if ($pubExit -ne 0 -and
        ($pubOutput -join "`n") -notmatch 'Building with plugins requires symlink support') {
        throw "flutter pub get failed (exit $pubExit)."
    }

    $plugins = Get-Content '.flutter-plugins-dependencies' -Raw | ConvertFrom-Json
    $packages = Get-Content '.dart_tool/package_config.json' -Raw | ConvertFrom-Json
    # Flutter also prepares Linux links when a Linux runner exists. Resolve paths
    # from package_config, not the escaped paths in plugin metadata.
    foreach ($platform in @('windows', 'linux')) {
        if (!(Test-Path -LiteralPath $platform)) { continue }
        $linkRoot = [IO.Path]::GetFullPath((Join-Path $appRoot "$platform/flutter/ephemeral/.plugin_symlinks"))
        New-Item -ItemType Directory -Force -Path $linkRoot | Out-Null
        foreach ($plugin in $plugins.plugins.$platform) {
            if ($plugin.name -notmatch '^[a-zA-Z0-9_]+$') { throw 'Invalid plugin name.' }
            $package = @($packages.packages | Where-Object { $_.name -eq $plugin.name })
            if ($package.Count -ne 1) { throw "Missing package resolution for $($plugin.name)." }
            $configUri = [Uri]::new((Join-Path $appRoot '.dart_tool/package_config.json'))
            $target = [Uri]::new($configUri, $package[0].rootUri).LocalPath.TrimEnd('\', '/')
            if (!(Test-Path -LiteralPath $target -PathType Container)) {
                throw "Missing plugin package: $target"
            }
            $linkPath = Join-Path $linkRoot $plugin.name
            $existing = Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
            if ($existing) {
                if (!($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw "Expected a plugin link, found a regular directory: $linkPath"
                }
                # Delete only the link itself, never its package-cache contents.
                $existing.Delete()
            }
            New-Item -ItemType Junction -Path $linkPath -Target $target | Out-Null
            if (!(Test-Path -LiteralPath (Join-Path $linkPath 'pubspec.yaml'))) {
                throw "Plugin link verification failed: $linkPath"
            }
            if ($platform -eq 'windows' -and $plugin.native_build -and
                !(Test-Path -LiteralPath (Join-Path $linkPath 'windows/CMakeLists.txt'))) {
                throw "Missing Windows native plugin sources: $linkPath"
            }
        }
    }
    if ($Action -eq 'Prepare') { return }
    # Resolution is fresh; do not let Flutter recreate the verified links.
    if ($Action -eq 'Build') {
        & $flutterCommand build windows "--$Configuration" --no-pub
    } else {
        & $flutterCommand run -d windows "--$Configuration" --no-pub
    }
    if ($LASTEXITCODE -ne 0) { throw "Flutter $Action failed (exit $LASTEXITCODE)." }
} finally {
    Pop-Location
}
