[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$FixturePath,
    [string]$OutPath,
    [string]$RequestId,
    [string]$TargetAlias,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$ToolName = 'verify-offline-route-b-guest.ps1/1.0'

function Get-Utf8Sha256([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2', [Globalization.CultureInfo]::InvariantCulture) }) -join '')
    } finally {
        $sha.Dispose()
    }
}

function New-CheckRecord([string]$Status, [string]$Method, $CapturedUtc, [string]$Tool, $RawSha256, [string]$Note) {
    return [ordered]@{
        status       = $Status
        method       = $Method
        captured_utc = $CapturedUtc
        tool         = $Tool
        raw_sha256   = $RawSha256
        note         = $Note
    }
}

if ([string]::IsNullOrWhiteSpace($ConfigPath) -and [string]::IsNullOrWhiteSpace($FixturePath)) {
    throw 'SPECIFY_CONFIGPATH_OR_FIXTUREPATH'
}
if (![string]::IsNullOrWhiteSpace($ConfigPath) -and ![string]::IsNullOrWhiteSpace($FixturePath)) {
    throw 'CONFIGPATH_AND_FIXTUREPATH_ARE_MUTUALLY_EXCLUSIVE'
}

if ([string]::IsNullOrWhiteSpace($RequestId)) {
    $RequestId = [guid]::NewGuid().ToString('N').ToLowerInvariant()
}
if ($RequestId -cnotmatch '^[a-f0-9]{32}$') {
    throw 'INVALID_REQUEST_ID'
}

$nowUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
$browserUsed = !$NoBrowser
$remoteMgmt = $true

$configSha256 = $null
$alias = $TargetAlias
$policyOk = $false
$policyIssues = @()
$extraAdapters = @()
$ipv6Enabled = @()
$rawSnapshot = $null

if (![string]::IsNullOrWhiteSpace($FixturePath)) {
    if (!(Test-Path -LiteralPath $FixturePath -PathType Leaf)) { throw 'FIXTURE_NOT_FOUND' }
    $fx = [IO.File]::ReadAllText($FixturePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $configSha256 = ([string]$fx.config_sha256).ToLowerInvariant()
    if ($configSha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'INVALID_FIXTURE_CONFIG_SHA256' }
    if ([string]::IsNullOrWhiteSpace($alias)) { $alias = [string]$fx.target_alias }
    if ([string]::IsNullOrWhiteSpace($alias)) { $alias = 'guest-fixture' }
    if ($null -ne $fx.browser_used) { $browserUsed = [bool]$fx.browser_used }
    if ($null -ne $fx.remote_management) { $remoteMgmt = [bool]$fx.remote_management }

    $policyOk = ($fx.policy_ok -is [bool] -and $fx.policy_ok)
    $policyIssues = @($fx.issue_codes | ForEach-Object { [string]$_ })
    $expected = @($fx.expected_adapters | ForEach-Object { [string]$_ })
    $active = @($fx.active_adapters | ForEach-Object { [string]$_ })
    $extraAdapters = @($active | Where-Object { $_ -notin $expected })
    $ipv6Enabled = @($fx.ipv6_enabled_adapters | ForEach-Object { [string]$_ })

    $rawSnapshot = ([ordered]@{
        mode = 'fixture'
        policy_ok = $policyOk
        issue_codes = $policyIssues
        extra_adapter_count = $extraAdapters.Count
        ipv6_enabled_count = $ipv6Enabled.Count
    } | ConvertTo-Json -Compress)
} else {
    if (!(Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw 'CONFIG_NOT_FOUND' }
    $configSha256 = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $cfg = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($alias)) {
        $alias = if ($cfg.target_alias) { [string]$cfg.target_alias } else { 'guest-route-b' }
    }

    # Pure offline read-only inspection (Tier-A, zero network calls)
    $expected = @([string]$cfg.lan_adapter, [string]$cfg.tun_adapter)
    $upAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    $extraAdapters = @($upAdapters | Where-Object { $_.Name -notin $expected } | ForEach-Object { 'extra-nic' })

    $ipv6Bindings = @(Get-NetAdapterBinding -ComponentID 'ms_tcpip6' -ErrorAction SilentlyContinue |
        Where-Object { $_.Enabled -eq $true -and $_.Name -in ($upAdapters.Name + $expected) })
    $ipv6Enabled = @($ipv6Bindings | ForEach-Object { 'ipv6-enabled-nic' })

    $guardPath = Join-Path $PSScriptRoot 'guest-egress-guard.ps1'
    $installRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeFortress'
    if ($PSScriptRoot -eq $installRoot -and (Test-Path -LiteralPath $guardPath -PathType Leaf)) {
        $guard = & $guardPath -ConfigPath $ConfigPath -Status -PolicyOnly -AsObject
        $policyOk = ($guard.policy_ok -is [bool] -and $guard.policy_ok)
        $policyIssues = @($guard.issue_codes | ForEach-Object { [string]$_ })
    } else {
        # Fallback read-only GPO profile check when running outside protected root
        $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction SilentlyContinue)
        $issues = @()
        foreach ($pname in 'Domain', 'Private', 'Public') {
            $prof = @($profiles | Where-Object Name -eq $pname)
            if ($prof.Count -ne 1 -or $prof[0].Enabled -ne 'True' -or
                $prof[0].DefaultInboundAction -ne 'Block' -or $prof[0].DefaultOutboundAction -ne 'Block' -or
                $prof[0].AllowLocalFirewallRules -ne 'False' -or $prof[0].AllowLocalIPsecRules -ne 'False') {
                $issues += "PROFILE_$pname"
            }
        }
        $expectedNames = @('CG-Managed-Node','CG-Managed-Tun','CG-Managed-Loop','CG-Managed-DhcpOut','CG-Managed-DhcpIn','CG-Managed-Ssh')
        $allowRules = @(Get-NetFirewallRule -PolicyStore ActiveStore -TracePolicyStore -Action Allow -Enabled True -ErrorAction SilentlyContinue)
        foreach ($r in $allowRules) {
            if ($r.Name -notin $expectedNames) { $issues += 'EXTRA_ENABLED_ALLOW' }
        }
        foreach ($rname in $expectedNames) {
            $m = @($allowRules | Where-Object { $_.Name -eq $rname -and $_.PolicyStoreSourceType -eq 'GroupPolicy' })
            if ($m.Count -ne 1) { $issues += "MISSING_OR_UNVERIFIED_$rname" }
        }
        $policyIssues = @($issues | Select-Object -Unique)
        $policyOk = ($policyIssues.Count -eq 0)
    }

    $rawSnapshot = ([ordered]@{
        mode = 'live-offline'
        policy_ok = $policyOk
        issue_codes = $policyIssues
        extra_adapter_count = $extraAdapters.Count
        ipv6_enabled_count = $ipv6Enabled.Count
    } | ConvertTo-Json -Compress)
}

$rawHash = Get-Utf8Sha256 $rawSnapshot

$guestPolicyStatus = if ($policyOk) { 'pass' } else { 'fail' }
$guestPolicyNote = if ($policyOk) {
    'All 3 ActiveStore GPO profiles default-block with local merge disabled and exact 6 CG-Managed-* rules enforced'
} else {
    'GPO policy issues: ' + (($policyIssues -join ', '))
}

$secondNicStatus = if ($extraAdapters.Count -eq 0) { 'pass' } else { 'fail' }
$secondNicNote = if ($extraAdapters.Count -eq 0) {
    'Only expected LAN/TUN adapters are Up; no unexpected second NIC detected'
} else {
    "Detected $($extraAdapters.Count) unexpected active adapter(s) outside expected LAN/TUN set"
}

$ipv6Status = if ($ipv6Enabled.Count -gt 0) { 'fail' } else { 'unknown' }
$ipv6Note = if ($ipv6Enabled.Count -gt 0) {
    "ms_tcpip6 binding is enabled on $($ipv6Enabled.Count) inspected adapter(s)"
} else {
    'Offline guest NIC IPv6 binding disabled; combine with OpenWrt gateway IPv6 drop and WAN capture to mark pass'
}

$notRun = { New-CheckRecord 'not_run' '' $null '' $null '' }

$evidence = [ordered]@{
    schema_version = 3
    request_id     = $RequestId
    route          = 'B'
    component      = 'system'
    target_alias   = $alias
    config_sha256  = $configSha256
    conditions     = [ordered]@{
        browser_used      = $browserUsed
        remote_management = $remoteMgmt
    }
    level_claimed  = $null
    captured_utc   = $nowUtc
    checks         = [ordered]@{
        egress_dual          = & $notRun
        ipv6                 = New-CheckRecord $ipv6Status 'offline_guest_nic_ipv6_binding' $nowUtc $ToolName $rawHash $ipv6Note
        dns                  = & $notRun
        browser_webrtc       = & $notRun
        cold_boot            = & $notRun
        reload_failure       = & $notRun
        entry_loss           = & $notRun
        management_ssh       = & $notRun
        stability            = & $notRun
        wan_capture          = & $notRun
        guest_policy         = New-CheckRecord $guestPolicyStatus 'offline_gpo_activestore_audit' $nowUtc $ToolName $rawHash $guestPolicyNote
        udp                  = & $notRun
        second_nic           = New-CheckRecord $secondNicStatus 'offline_netadapter_topology' $nowUtc $ToolName $rawHash $secondNicNote
        existing_connections = & $notRun
        app_fail_closed      = New-CheckRecord 'not_applicable' '' $null '' $null 'Route B is system-level; app-level launcher check does not apply'
    }
    private_evidence_reference = '<PRIVATE_EVIDENCE_PATH>'
}

$json = $evidence | ConvertTo-Json -Depth 6
if (![string]::IsNullOrWhiteSpace($OutPath)) {
    [IO.File]::WriteAllText($OutPath, $json + "`n", [Text.UTF8Encoding]::new($false))
} else {
    Write-Output $json
}
exit 0
