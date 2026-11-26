[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [switch]$Status,
    [switch]$PolicyOnly,
    [switch]$AsObject
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
$cfg = (Read-FortressConfig $ConfigPath).Config
foreach ($binary in $cfg.core_path,$cfg.sshd_path) {
    Assert-FortressPath $binary ([IO.Path]::GetDirectoryName($binary))
    if (!(Test-Path -LiteralPath $binary -PathType Leaf)) { throw 'TRUSTED_BINARY_NOT_FOUND' }
}

function Normalize-Filter($Value) {
    return ((@($Value | ForEach-Object {
        ([string]$_).Replace('/255.0.0.0','/8').Replace('/255.255.0.0','/16') -replace '/32$',''
    } | Sort-Object)) -join ',')
}

$ruleset = [ordered]@{
    'CG-Managed-Node' = @{ Interface=$cfg.lan_adapter; Program=$cfg.core_path; Protocol='TCP'; RemotePort=$cfg.entry_port; Remote=$cfg.entry_ipv4 }
    'CG-Managed-Tun' = @{ Interface=$cfg.tun_adapter; Local=$cfg.tun_ipv4_cidr }
    'CG-Managed-Loop' = @{ Remote='127.0.0.0/8' }
    'CG-Managed-DhcpOut' = @{ Interface=$cfg.lan_adapter; Service='Dhcp'; Protocol='UDP'; LocalPort=68; RemotePort=67; Remote=@($cfg.dhcp_ipv4,'255.255.255.255') }
    'CG-Managed-DhcpIn' = @{ Direction='Inbound'; Interface=$cfg.lan_adapter; Service='Dhcp'; Protocol='UDP'; LocalPort=68; RemotePort=67; Remote=$cfg.dhcp_ipv4 }
    'CG-Managed-Ssh' = @{ Direction='Inbound'; Interface=$cfg.lan_adapter; Program=$cfg.sshd_path; Protocol='TCP'; LocalPort=22; Remote=$cfg.management_ipv4 }
}
$issues = @(
    $extraAdapter = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Name -notin @($cfg.lan_adapter,$cfg.tun_adapter) })
    if ($extraAdapter.Count) { 'UNEXPECTED_ACTIVE_ADAPTER' }
    $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
    foreach ($name in 'Domain','Private','Public') {
        $profile = @($profiles | Where-Object Name -eq $name)
        if ($profile.Count -ne 1 -or $profile[0].Enabled -ne 'True' -or
            $profile[0].DefaultInboundAction -ne 'Block' -or $profile[0].DefaultOutboundAction -ne 'Block' -or
            $profile[0].AllowLocalFirewallRules -ne 'False' -or $profile[0].AllowLocalIPsecRules -ne 'False' -or
            @($profile[0].DisabledInterfaceAliases | Where-Object { $_ -and $_ -ne 'NotConfigured' }).Count) { "PROFILE_$name" }
    }
    $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -TracePolicyStore -Action Allow -Enabled True)
    foreach ($rule in $rules) {
        if ($rule.Name -notin $ruleset.Keys) { 'EXTRA_ENABLED_ALLOW' }
    }
    foreach ($name in $ruleset.Keys) {
        $match = @($rules | Where-Object Name -eq $name)
        if ($match.Count -ne 1 -or $match[0].PolicyStoreSourceType -ne 'GroupPolicy' -or
            'Enforced' -notin @($match[0].EnforcementStatus)) { "UNVERIFIED_RULE_$name"; continue }
        $rule = $match[0]
        $address = $rule | Get-NetFirewallAddressFilter
        $port = $rule | Get-NetFirewallPortFilter
        $app = $rule | Get-NetFirewallApplicationFilter
        $interface = $rule | Get-NetFirewallInterfaceFilter
        $interfaceType = $rule | Get-NetFirewallInterfaceTypeFilter
        $service = $rule | Get-NetFirewallServiceFilter
        $security = $rule | Get-NetFirewallSecurityFilter
        $actual = @{
            Direction=$rule.Direction; Profile=$rule.Profile; Interface=$interface.InterfaceAlias
            InterfaceType=$interfaceType.InterfaceType; Service=$service.Service; Program=$app.Program
            Protocol=$port.Protocol; LocalPort=$port.LocalPort; RemotePort=$port.RemotePort
            Local=$address.LocalAddress; Remote=$address.RemoteAddress; Edge=$rule.EdgeTraversalPolicy
            Authentication=$security.Authentication; Encryption=$security.Encryption
            LocalUser=$security.LocalUser; RemoteUser=$security.RemoteUser; RemoteMachine=$security.RemoteMachine
            OverrideBlock=$security.OverrideBlockRules
        }
        $expected = @{
            Direction='Outbound'; Profile='Any'; Interface='Any'; InterfaceType='Any'; Service='Any'; Program='Any'
            Protocol='Any'; LocalPort='Any'; RemotePort='Any'; Local='Any'; Remote='Any'; Edge='Block'
            Authentication='NotRequired'; Encryption='NotRequired'; LocalUser='Any'; RemoteUser='Any'; RemoteMachine='Any'; OverrideBlock='False'
        }
        foreach ($field in $ruleset[$name].Keys) { $expected[$field] = $ruleset[$name][$field] }
        foreach ($field in $expected.Keys) {
            if ((Normalize-Filter $actual[$field]) -ne (Normalize-Filter $expected[$field])) { "RULE_FILTER_${name}_$field" }
        }
    }
)
$transport = 'not_run'
if (!$PolicyOnly) {
    $adapter = Get-NetAdapter -Name $cfg.tun_adapter -ErrorAction SilentlyContinue
    $processes = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($cfg.core_path)) -ErrorAction SilentlyContinue | Where-Object Path -eq $cfg.core_path)
    $connection = @(Get-NetTCPConnection -State Established -RemoteAddress $cfg.entry_ipv4 -RemotePort $cfg.entry_port -ErrorAction SilentlyContinue |
        Where-Object { $_.OwningProcess -in $processes.Id })
    $transport = if ($adapter.Status -eq 'Up' -and $connection.Count) {'pass'} else {'unknown'}
}
$result = [pscustomobject]@{ policy_ok=($issues.Count -eq 0); transport=$transport; issue_codes=@($issues | Select-Object -Unique) }
if ($AsObject) { return $result }
$result | ConvertTo-Json -Compress
if (!$result.policy_ok) { exit 2 }
if (!$PolicyOnly -and $transport -ne 'pass') { exit 3 }
exit 0
