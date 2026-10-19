# Run with PowerShell 7. SSH private key stays outside the repository.
[CmdletBinding()]
param(
    [string]$MacHost = '192.168.159.135',
    [string]$MacUser = 'xiao',
    [string]$IdentityFile = "$env:USERPROFILE/.ssh/audiolife_mac_vm_ed25519",
    [string]$RemoteRoot = '/Users/xiao/Developer/AudioLife-ssh',
    [switch]$SkipSimulator
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if ($MacHost -notmatch '^[a-zA-Z0-9.-]+$' -or $MacUser -notmatch '^[a-zA-Z0-9_-]+$' -or $RemoteRoot -notmatch '^/Users/[a-zA-Z0-9_/-]+$') {
    throw 'Invalid SSH host, user, or remote workspace path.'
}
if (-not (Test-Path -LiteralPath $IdentityFile)) { throw "Missing SSH key: $IdentityFile" }
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
$localRun = Join-Path $repo ".build/mac-vm/$runId"
$remoteRun = "$RemoteRoot/runs/$runId"
New-Item -ItemType Directory -Path $localRun -Force | Out-Null
$sshArgs = @('-i', $IdentityFile, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=15')
$target = "$MacUser@$MacHost"
& "$PSScriptRoot/Initialize-MacVm.ps1" -MacHost $MacHost -MacUser $MacUser -IdentityFile $IdentityFile
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
Push-Location $repo
try {
    $files = @(git -c core.quotepath=false ls-files --cached --others --exclude-standard | Where-Object {
        $_ -notmatch '(^|/)(xcuserdata|\.DS_Store)(/|$)' -and
        ($_ -match '^(audiolife/|audiolife\.xcodeproj/|AudioLifeWidgets/|Shared/|scripts/|\.github/)' -or $_ -match '^[^/]+\.md$' -or $_ -eq '.gitignore') -and
        (Test-Path -LiteralPath $_ -PathType Leaf)
    } | Sort-Object -Unique)
    if ($LASTEXITCODE -ne 0 -or $files.Count -eq 0) { throw 'Cannot enumerate project source.' }
    $records = @($files | ForEach-Object { @{path=$_; sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()} })
    $manifest = @{
        run_id=$runId; commit=(git rev-parse HEAD).Trim(); git_status=@(git status --porcelain)
        created_at=(Get-Date).ToUniversalTime().ToString('o'); files=$records
    }
    $manifestPath = Join-Path $localRun 'source-manifest.json'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8NoBOM -LiteralPath $manifestPath
    $listPath = Join-Path $localRun 'source-files.txt'
    $files | Set-Content -Encoding utf8NoBOM -LiteralPath $listPath
    $archive = Join-Path $localRun 'source.tar.gz'
    Invoke-Checked tar.exe @('-czf', $archive, '-T', $listPath)
    Write-Host "Uploading $($files.Count) source files to $remoteRun"
    Invoke-Checked ssh.exe ($sshArgs + @($target, "mkdir -p '$remoteRun/src' '$remoteRun/output'"))
    Invoke-Checked scp.exe ($sshArgs + @($archive, $manifestPath, "${target}:$remoteRun/"))
    Invoke-Checked ssh.exe ($sshArgs + @($target, "tar -xzf '$remoteRun/source.tar.gz' -C '$remoteRun/src'"))
    $skip = if ($SkipSimulator) { '1' } else { '0' }
    Write-Host "Running Xcode validation. Remote log: $remoteRun/output/workflow.log"
    & ssh.exe @sshArgs $target "bash '$remoteRun/src/scripts/mac-validate.sh' '$remoteRun' '$skip' > '$remoteRun/output/workflow.log' 2>&1"
    $buildExit = $LASTEXITCODE
    $resultName = 'results.tar.gz'
    if ($buildExit -eq 0 -and -not $SkipSimulator) {
        & ssh.exe @sshArgs $target "bash '$remoteRun/src/scripts/mac-library-tests.sh' '$remoteRun' > '$remoteRun/library-tests.log' 2>&1"
        $buildExit = $LASTEXITCODE
        if ($buildExit -eq 0) { $resultName = 'results-with-tests.tar.gz' }
        else {
            # Preserve the runtime failure report along with the successful build.
            & ssh.exe @sshArgs $target "tar -czf '$remoteRun/results.tar.gz' -C '$remoteRun' output library-tests.log"
        }
    }
    # Fetch diagnostics even when Xcode fails; never discard a failed run.
    Invoke-Checked scp.exe ($sshArgs + @("${target}:$remoteRun/$resultName", $localRun))
    Invoke-Checked tar.exe @('-xzf', (Join-Path $localRun $resultName), '-C', $localRun)
    $output = Join-Path $localRun 'output'
    foreach ($checksum in Get-ChildItem -LiteralPath $output -Filter '*.ipa.sha256') {
        $line = (Get-Content -LiteralPath $checksum.FullName -Raw).Trim()
        $expected, $name = $line -split '\s+', 2
        $actual = (Get-FileHash -LiteralPath (Join-Path $output $name) -Algorithm SHA256).Hash
        if ($actual -ine $expected) { throw "Downloaded IPA checksum mismatch: $name" }
    }
    Write-Host "Windows results: $output"
    if ($buildExit -ne 0) { throw "Mac validation failed ($buildExit). See $output/workflow.log" }
    Get-Content -Encoding utf8 -LiteralPath (Join-Path $output 'build-info.json')
} finally {
    Pop-Location
}
