# Work around this VMware VM's stalled outgoing TCP segmentation.
[CmdletBinding()]
param(
    [string]$MacHost = '192.168.159.135',
    [string]$MacUser = 'xiao',
    [string]$IdentityFile = "$env:USERPROFILE/.ssh/audiolife_mac_vm_ed25519",
    [string]$CredentialFile = "$env:USERPROFILE/.ssh/audiolife_mac_vm.credential.xml"
)
$ErrorActionPreference = 'Stop'
# This host-specific workaround must not change other Macs supplied via overrides.
if ($MacHost -ne '192.168.159.135' -or $MacUser -ne 'xiao') { return }
$arguments = @('-T', '-i', $IdentityFile, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=15', "$MacUser@$MacHost")
$state = & ssh.exe @arguments 'sysctl -n net.inet.tcp.tso'
if ($LASTEXITCODE -ne 0) { throw 'Cannot check VM TCP offload state.' }
if ("$state".Trim() -eq '1') {
    if (-not (Test-Path -LiteralPath $CredentialFile)) {
        throw "VM requires TCP offload workaround. Missing local encrypted credential: $CredentialFile"
    }
    $credential = Import-Clixml -LiteralPath $CredentialFile
    if ($credential.UserName -ne $MacUser) { throw 'VM credential user mismatch.' }
    try {
        # Password travels through SSH stdin; never part of command arguments or Git.
        $password = $credential.GetNetworkCredential().Password
        $password | & ssh.exe @arguments "sudo -S -p '' /usr/sbin/sysctl -w net.inet.tcp.tso=0"
        if ($LASTEXITCODE -ne 0) { throw 'Cannot apply VM TCP offload workaround.' }
    } finally {
        $password = $null
        $credential = $null
    }
}
