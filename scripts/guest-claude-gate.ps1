[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [ValidateSet('Inspect','Launch')][string]$Mode = 'Inspect',
    [ValidatePattern('^[a-f0-9]{32}$')][string]$RequestId
)

$ErrorActionPreference = 'Stop'
$installRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeFortress'
$commonPath = Join-Path $installRoot 'route-b-common.ps1'
if ($PSScriptRoot -ne $installRoot) { throw 'INSTALL_IN_PROTECTED_ROOT_FIRST' }
$trustedOwners = @('S-1-5-18','S-1-5-32-544')
$ancestor = [IO.Path]::GetDirectoryName($installRoot)
while ($ancestor) {
    if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'REPARSE_POINT' }
    $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}
foreach ($trustedPath in $installRoot,$PSCommandPath,$commonPath) {
    if ((Get-Item -LiteralPath $trustedPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'REPARSE_POINT' }
    $acl = Get-Acl -LiteralPath $trustedPath
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trustedOwners) { throw 'UNTRUSTED_SCRIPT_OWNER' }
    if (@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object {
        $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin $trustedOwners -and ($_.FileSystemRights -band 0xD0156)
    }).Count) { throw 'UNTRUSTED_SCRIPT_WRITER' }
}
. $commonPath
Assert-FortressPath $PSCommandPath
$root = Get-FortressRoot
$guardPath = Join-Path $root 'guest-egress-guard.ps1'
Assert-FortressPath $guardPath

function Get-VerifiedLaunchContext {
    $info = Read-FortressConfig $ConfigPath
    $cfg = $info.Config
    $reportPath = Join-Path $root "reports\$RequestId.json"
    $evidencePath = Join-Path $root "evidence\$RequestId.json"
    Assert-FortressPath $reportPath
    Assert-FortressPath $evidencePath
    $reportHash = (Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash
    $evidenceHash = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash
    $report = Read-FortressRecord $reportPath
    $evidence = Read-FortressRecord $evidencePath
    foreach ($record in $report,$evidence) {
        if ($record.schema_version -isnot [int] -or $record.schema_version -ne 2 -or
            $record.request_id -isnot [string] -or $record.request_id -cne $RequestId -or
            $record.target_alias -isnot [string] -or $record.target_alias -cne $cfg.target_alias -or
            $record.generation -isnot [string] -or $record.generation -cne $cfg.generation -or
            $record.config_sha256 -isnot [string] -or $record.config_sha256 -ne $info.Sha256) { throw 'RECORD_BINDING_MISMATCH' }
    }
    if (!(Test-FortressFresh $report.started_utc 900) -or !(Test-FortressFresh $report.timestamp_utc 900) -or
        [DateTimeOffset]::Parse($report.started_utc) -gt [DateTimeOffset]::Parse($report.timestamp_utc) -or
        !(Test-FortressFresh $evidence.captured_utc 86400)) { throw 'RECORD_TIME_INVALID_OR_EXPIRED' }
    foreach ($name in 'tun_up','policy_ok','ipv4_tun_ok','ipv4_proxy_ok','functional_pass') {
        if (!(Test-FortressTrue $report.$name)) { throw 'FUNCTIONAL_PROBE_NOT_VERIFIED' }
    }
    if ($report.ipv6_probe -isnot [string] -or $report.ipv6_probe -cne 'no_response_in_this_probe') { throw 'IPV6_PROBE_INCONSISTENT' }
    if ($evidence.functional_report_sha256 -isnot [string] -or
        $evidence.functional_report_sha256 -ne $reportHash -or
        $evidence.private_evidence_reference -isnot [string] -or $evidence.private_evidence_reference -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'EVIDENCE_DIGEST_INVALID'
    }
    foreach ($name in 'dns','ipv6','cold_boot','reload_failure','entry_loss','existing_connections','udp','second_nic','management_ssh','browser_webrtc') {
        if ($evidence.checks.$name -isnot [string] -or $evidence.checks.$name -cne 'pass') { throw "BOUNDARY_NOT_VERIFIED_$name" }
    }
    $guard = & $guardPath -ConfigPath $ConfigPath -Status -PolicyOnly -AsObject
    $tun = @(Get-NetAdapter -Name $cfg.tun_adapter -ErrorAction SilentlyContinue)
    $lan = @(Get-NetAdapter -Name $cfg.lan_adapter -ErrorAction SilentlyContinue)
    if (!(Test-FortressTrue $guard.policy_ok) -or $tun.Count -ne 1 -or $tun[0].Status -ne 'Up' -or
        $lan.Count -ne 1 -or $lan[0].Status -ne 'Up') { throw 'LIVE_LOCAL_BASELINE_CHANGED' }
    if ((Read-FortressConfig $ConfigPath).Sha256 -ne $info.Sha256) { throw 'CONFIG_CHANGED_DURING_CHECK' }
    if ((Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash -ne $reportHash -or
        (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash -ne $evidenceHash) { throw 'RECORD_CHANGED_DURING_CHECK' }
    return [pscustomobject]@{ Config=$cfg; Sha256=$info.Sha256; ReportHash=$reportHash; EvidenceHash=$evidenceHash;
        StartedUtc=$report.started_utc; CompletedUtc=$report.timestamp_utc; EvidenceUtc=$evidence.captured_utc }
}

if ($Mode -eq 'Inspect') {
    $null = Read-FortressConfig $ConfigPath
    $current = & $guardPath -ConfigPath $ConfigPath -PolicyOnly -Status -AsObject
    if (!(Test-FortressTrue $current.policy_ok)) { 'STATUS:POLICY_NOT_VERIFIED'; exit 2 }
    'STATUS:POLICY_ONLY_OK_NOT_LAUNCH_APPROVAL'
    exit 0
}
if (!$RequestId -or ![Environment]::UserInteractive -or (Get-Process -Id $PID).SessionId -eq 0) { throw 'LOCAL_DESKTOP_SESSION_REQUIRED' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'DO_NOT_LAUNCH_AS_ADMIN' }
$debounce = New-Object Threading.Mutex($false,'Global\ClaudeFortress.InteractiveLaunch')
$acquired = $false
try {
    try { $acquired = $debounce.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (!$acquired) { 'STATUS:BUSY_RETRY_MANUALLY'; exit 3 }
    $initial = Get-VerifiedLaunchContext
    if ($identity.User.Value -ne $initial.Config.desktop_sid) { throw 'WRONG_DESKTOP_SID' }
    Write-Host "C-tier: launch $($initial.Config.app_id) on $($initial.Config.target_alias); the app may contact its service."
    $promptStarted = [DateTime]::UtcNow.ToString('o')
    if ((Read-Host "Type LAUNCH $RequestId for this invocation only") -cne "LAUNCH $RequestId") { 'STATUS:CANCELLED'; exit 4 }
    $current = Get-VerifiedLaunchContext
    if ($current.Sha256 -ne $initial.Sha256 -or $current.ReportHash -ne $initial.ReportHash -or
        $current.EvidenceHash -ne $initial.EvidenceHash -or !(Test-FortressFresh $promptStarted 120)) { throw 'APPROVAL_EXPIRED_OR_CONFIG_CHANGED' }
    $appId = $current.Config.app_id
    $family = $appId.Split('!')[0]
    $packages = @(Get-AppxPackage | Where-Object { $_.PackageFamilyName -ceq $family -and $_.Publisher -ceq $current.Config.app_publisher -and $_.Status -eq 'Ok' })
    $apps = @(Get-StartApps | Where-Object AppID -CEQ $appId)
    if ($packages.Count -ne 1 -or $apps.Count -ne 1) { throw 'PACKAGE_IDENTITY_NOT_VERIFIED' }
    if (!(Test-FortressFresh $current.StartedUtc 900) -or !(Test-FortressFresh $current.CompletedUtc 900) -or
        !(Test-FortressFresh $current.EvidenceUtc 86400) -or !(Test-FortressFresh $promptStarted 120) -or
        (Read-FortressConfig $ConfigPath).Sha256 -ne $current.Sha256 -or
        (Get-FileHash -LiteralPath (Join-Path $root "reports\$RequestId.json") -Algorithm SHA256).Hash -ne $current.ReportHash -or
        (Get-FileHash -LiteralPath (Join-Path $root "evidence\$RequestId.json") -Algorithm SHA256).Hash -ne $current.EvidenceHash) { throw 'FINAL_RECHECK_FAILED' }
    Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('Windows')) 'explorer.exe') -ArgumentList "shell:AppsFolder\$appId"
    'STATUS:LAUNCH_REQUESTED_NOT_PROOF_OF_OPEN'
} finally {
    if ($acquired) { $debounce.ReleaseMutex() }
    $debounce.Dispose()
}
