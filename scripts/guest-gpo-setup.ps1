#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('DryRun', 'Apply', 'Rollback')][string]$Mode = 'DryRun',
    [string]$ConfigPath,
    [switch]$AsJson,
    [switch]$ConfirmTierC,
    [string]$BackupDir,
    [string]$BackupPath
)

$ErrorActionPreference = 'Stop'
$store = 'localhost'
$profileNames = @('Domain', 'Private', 'Public')

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        if (!([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'ADMINISTRATOR_REQUIRED'
        }
    } finally { $identity.Dispose() }
}

function Test-Placeholder([string]$Value) {
    return $Value -match '(?i)REPLACE[-_ ]?ME|example[-_ ]not[-_ ]deployed|\bplaceholder\b|\byour[-_ ]?(?:path|folder|user(?:name)?|app|program|proxy|core)\b|<[^>]*>|\bTODO\b'
}

function Test-LocalPathSyntax([string]$Path) {
    if ($Path -notmatch '\A[A-Za-z]:\\' -or $Path.Substring(2) -match '[:<>"|?*%/\x00-\x1F]') { return $false }
    $relative = $Path.Substring(3).TrimEnd('\')
    if ($relative -match '\\\\') { return $false }
    foreach ($segment in $relative.Split('\')) {
        if ($segment -match '(?:[ .]\z)|\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|\z)') { return $false }
    }
    return $true
}

function Get-SafeLocalPath([string]$Path, [switch]$AllowMissing) {
    if (!(Test-LocalPathSyntax $Path)) { throw 'ABSOLUTE_LOCAL_PATH_REQUIRED' }
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($fullPath)).DriveType -ne [IO.DriveType]::Fixed) {
        throw 'FIXED_LOCAL_DRIVE_REQUIRED'
    }
    $ancestors = [Collections.Generic.Stack[string]]::new()
    for ($ancestor = $fullPath; $ancestor; $ancestor = [IO.Path]::GetDirectoryName($ancestor)) { $ancestors.Push($ancestor) }
    foreach ($ancestor in $ancestors) {
        try { $item = Get-Item -LiteralPath $ancestor -Force }
        catch [System.Management.Automation.ItemNotFoundException] {
            if ($AllowMissing) { continue }
            throw
        }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "REPARSE_POINT: $ancestor" }
    }
    return $fullPath
}

function Read-SetupConfig([string]$Path) {
    # Match the schema in route-b-common.ps1 without its host and deployment ACL checks.
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt 16384) { throw 'CONFIG_TOO_LARGE' }
    $cfg = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json
    if ($cfg -isnot [pscustomobject] -or $cfg.schema_version -isnot [int] -or $cfg.schema_version -ne 2) {
        throw 'INVALID_CONFIG_SCHEMA'
    }
    foreach ($property in $cfg.PSObject.Properties) {
        if ($property.Value -is [string] -and (Test-Placeholder $property.Value)) {
            throw "PLACEHOLDER_CONFIG_$($property.Name)"
        }
    }
    foreach ($name in 'target_alias', 'generation', 'guest_hostname') {
        if ($cfg.$name -isnot [string] -or $cfg.$name -notmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z') {
            throw "INVALID_CONFIG_$name"
        }
    }
    foreach ($name in 'entry_ipv4', 'expected_egress_ipv4', 'dhcp_ipv4', 'management_ipv4') {
        $value = $cfg.$name
        if ($value -isnot [string] -or $value -notmatch '\A(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}\z' -or
            $value -match '^(192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|0\.|127\.|255\.)' -or
            @($value.Split('.') | Where-Object { [int]$_ -gt 255 }).Count) {
            throw "INVALID_CONFIG_$name"
        }
    }
    foreach ($name in 'entry_port', 'proxy_port') {
        if ($cfg.$name -isnot [int] -or $cfg.$name -lt 1 -or $cfg.$name -gt 65535) { throw "INVALID_CONFIG_$name" }
    }
    foreach ($name in 'lan_adapter', 'tun_adapter') {
        if ($cfg.$name -isnot [string] -or $cfg.$name -notmatch '\A[\p{L}\p{N} ._-]{1,64}\z' -or
            $cfg.$name -ne $cfg.$name.Trim() -or $cfg.$name -eq 'Any') { throw "INVALID_CONFIG_$name" }
    }
    if ($cfg.lan_adapter -eq $cfg.tun_adapter -or $cfg.tun_ipv4_cidr -isnot [string] -or
        $cfg.tun_ipv4_cidr -ne '198.18.0.0/16') { throw 'INVALID_TUN_CONFIG' }
    foreach ($name in 'core_path', 'sshd_path') {
        $value = $cfg.$name
        if ($value -isnot [string] -or !(Test-LocalPathSyntax $value) -or
            $value -notmatch '\.exe\z' -or $value -match '\\(?:path\\to|example|sample|dummy|changeme|fake)(?:\\|\.)') {
            throw "INVALID_CONFIG_$name"
        }
    }
    if ($cfg.desktop_sid -isnot [string] -or $cfg.desktop_sid -notmatch '\AS-1-5-21-([0-9]+-){3}[0-9]+\z' -or
        $cfg.app_id -isnot [string] -or $cfg.app_id -notmatch '\A[A-Za-z0-9._-]+![A-Za-z0-9._-]+\z' -or
        $cfg.app_publisher -isnot [string] -or $cfg.app_publisher -notmatch '\ACN=.{1,512}\z') {
        throw 'INVALID_DESKTOP_IDENTITY'
    }
    return $cfg
}

function New-SetupPlan($Config) {
    $profiles = foreach ($name in $profileNames) {
        [ordered]@{
            Name = $name; PolicyStore = $store; Enabled = 'True'
            DefaultInboundAction = 'Block'; DefaultOutboundAction = 'Block'
            AllowLocalFirewallRules = 'False'; AllowLocalIPsecRules = 'False'
            DisabledInterfaceAliases = @('NotConfigured')
        }
    }
    $overrides = [ordered]@{
        'CG-Managed-Node' = @{
            InterfaceAlias = $Config.lan_adapter; Program = $Config.core_path; Protocol = 'TCP'
            RemotePort = $Config.entry_port; RemoteAddress = $Config.entry_ipv4
        }
        'CG-Managed-Tun' = @{ InterfaceAlias = $Config.tun_adapter; LocalAddress = $Config.tun_ipv4_cidr }
        'CG-Managed-Loop' = @{ RemoteAddress = '127.0.0.0/8' }
        'CG-Managed-DhcpOut' = @{
            InterfaceAlias = $Config.lan_adapter; Service = 'Dhcp'; Protocol = 'UDP'
            LocalPort = 68; RemotePort = 67; RemoteAddress = @($Config.dhcp_ipv4, '255.255.255.255')
        }
        'CG-Managed-DhcpIn' = @{
            Direction = 'Inbound'; InterfaceAlias = $Config.lan_adapter; Service = 'Dhcp'; Protocol = 'UDP'
            LocalPort = 68; RemotePort = 67; RemoteAddress = $Config.dhcp_ipv4
        }
        'CG-Managed-Ssh' = @{
            Direction = 'Inbound'; InterfaceAlias = $Config.lan_adapter; Program = $Config.sshd_path
            Protocol = 'TCP'; LocalPort = 22; RemoteAddress = $Config.management_ipv4
        }
    }
    $rules = foreach ($name in $overrides.Keys) {
        $rule = [ordered]@{
            Name = $name; DisplayName = $name; PolicyStore = $store; Enabled = 'True'; Action = 'Allow'
            Direction = 'Outbound'; Profile = 'Any'; InterfaceAlias = 'Any'; InterfaceType = 'Any'
            Service = 'Any'; Program = 'Any'; Protocol = 'Any'; LocalPort = 'Any'; RemotePort = 'Any'
            LocalAddress = 'Any'; RemoteAddress = 'Any'; EdgeTraversalPolicy = 'Block'
            Authentication = 'NotRequired'; Encryption = 'NotRequired'
            LocalUser = 'Any'; RemoteUser = 'Any'; RemoteMachine = 'Any'; OverrideBlockRules = 'False'
        }
        foreach ($field in $overrides[$name].Keys) { $rule[$field] = $overrides[$name][$field] }
        $rule
    }
    return [ordered]@{
        Mode = $Mode; GuestHostname = $Config.guest_hostname; PolicyStore = $store
        Profiles = @($profiles); Rules = @($rules)
        Cleanup = 'Disable enabled Allow rules outside the six managed names in localhost GPO.'
        EffectiveRuleRequirements = @{ PolicyStoreSourceType = 'GroupPolicy'; EnforcementStatus = 'Enforced' }
        Rollback = 'Use -Mode Rollback -BackupPath <timestamped.json> on the original guest as Administrator. This restores the companion WFW and replaces the localhost GPO firewall policy.'
    }
}

function Read-NetshPrompt($Process, [string]$Prompt) {
    $reader = $Process.StandardOutput
    $buffer = [char[]]::new(1)
    $output = [Text.StringBuilder]::new()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt 60000 -and $output.Length -lt 65536) {
        $pending = $reader.ReadAsync($buffer, 0, 1)
        if (!$pending.Wait([Math]::Max(1, 60000 - [int]$timer.ElapsedMilliseconds)) -or !$pending.Result) { break }
        $null = $output.Append($buffer[0])
        if ($buffer[0] -eq '>' -and $output.ToString().EndsWith($Prompt, [StringComparison]::OrdinalIgnoreCase)) {
            return $output.ToString().Substring(0, $output.Length - $Prompt.Length).Trim()
        }
    }
    throw "NETSH_PROMPT_NOT_REACHED: $Prompt"
}

function Invoke-GpoWfw([ValidateSet('export', 'import')][string]$Operation, [string]$Path) {
    # Store selection is session-scoped. Never send import until show store proves the switch.
    $info = [Diagnostics.ProcessStartInfo]::new((Join-Path ([Environment]::SystemDirectory) 'netsh.exe'))
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $netsh = [Diagnostics.Process]::Start($info)
    try {
        $stderr = $netsh.StandardError.ReadToEndAsync()
        $inputWriter = $netsh.StandardInput
        $null = Read-NetshPrompt $netsh 'netsh>'
        $inputWriter.WriteLine('advfirewall')
        $null = Read-NetshPrompt $netsh 'netsh advfirewall>'
        $inputWriter.WriteLine('show store')
        $initialStore = Read-NetshPrompt $netsh 'netsh advfirewall>'
        $guest = [Environment]::MachineName
        if ($guest -notmatch '\A[A-Za-z0-9_-]+\z') { throw 'UNSUPPORTED_MACHINE_NAME_FOR_NETSH' }
        $inputWriter.WriteLine("set store gpo=$guest")
        $null = Read-NetshPrompt $netsh 'netsh advfirewall>'
        $inputWriter.WriteLine('show store')
        $currentStore = Read-NetshPrompt $netsh 'netsh advfirewall>'
        $hostToken = '(?<![\w.-])' + [regex]::Escape($guest) + '(?![\w-])'
        if ($currentStore -eq $initialStore -or $currentStore -notmatch $hostToken) {
            throw "NETSH_GPO_STORE_UNVERIFIED: $currentStore"
        }
        $inputWriter.WriteLine(('{0} "{1}"' -f $Operation, $Path))
        $result = Read-NetshPrompt $netsh 'netsh advfirewall>'
        $inputWriter.WriteLine('exit')
        if (!$netsh.WaitForExit(10000)) { throw 'NETSH_EXIT_TIMEOUT' }
        if ($netsh.ExitCode -ne 0 -or $stderr.Result) { throw "NETSH_$($Operation.ToUpperInvariant())_FAILED: $result $($stderr.Result)" }
    } finally {
        if (!$netsh.HasExited) { $netsh.Kill() }
        $netsh.Dispose()
    }
}

function Normalize-GuardFilter($Value) {
    return ((@($Value | ForEach-Object {
        ([string]$_).Replace('/255.0.0.0', '/8').Replace('/255.255.0.0', '/16') -replace '/32$', ''
    } | Sort-Object)) -join ',')
}

function Get-RuleFields($Rule) {
    $address = $Rule | Get-NetFirewallAddressFilter
    $port = $Rule | Get-NetFirewallPortFilter
    $app = $Rule | Get-NetFirewallApplicationFilter
    $interface = $Rule | Get-NetFirewallInterfaceFilter
    $interfaceType = $Rule | Get-NetFirewallInterfaceTypeFilter
    $service = $Rule | Get-NetFirewallServiceFilter
    $security = $Rule | Get-NetFirewallSecurityFilter
    return [ordered]@{
        Name = [string]$Rule.Name; DisplayName = [string]$Rule.DisplayName; PolicyStore = $store
        Enabled = [string]$Rule.Enabled; Action = [string]$Rule.Action
        Direction = [string]$Rule.Direction; Profile = [string]$Rule.Profile; InterfaceAlias = $interface.InterfaceAlias
        InterfaceType = [string]$interfaceType.InterfaceType; Service = $service.Service; Program = $app.Program
        Protocol = [string]$port.Protocol; LocalPort = $port.LocalPort; RemotePort = $port.RemotePort
        LocalAddress = $address.LocalAddress; RemoteAddress = $address.RemoteAddress
        EdgeTraversalPolicy = [string]$Rule.EdgeTraversalPolicy; Authentication = [string]$security.Authentication
        Encryption = [string]$security.Encryption; LocalUser = $security.LocalUser; RemoteUser = $security.RemoteUser
        RemoteMachine = $security.RemoteMachine; OverrideBlockRules = [string]$security.OverrideBlockRules
    }
}

function Get-GpoSnapshot {
    $profiles = foreach ($profile in (Get-NetFirewallProfile -PolicyStore $store | Sort-Object Name)) {
        [ordered]@{
            Name = [string]$profile.Name; Enabled = [string]$profile.Enabled
            DefaultInboundAction = [string]$profile.DefaultInboundAction; DefaultOutboundAction = [string]$profile.DefaultOutboundAction
            AllowLocalFirewallRules = [string]$profile.AllowLocalFirewallRules; AllowLocalIPsecRules = [string]$profile.AllowLocalIPsecRules
            DisabledInterfaceAliases = @($profile.DisabledInterfaceAliases | Where-Object { $_ } | Sort-Object)
        }
    }
    if (@($profiles).Count -ne 3 -or @($profileNames | Where-Object { $_ -notin $profiles.Name }).Count) {
        throw 'INCOMPLETE_GPO_PROFILES'
    }
    $rules = @(Get-NetFirewallRule -PolicyStore $store | Sort-Object Name | ForEach-Object {
        $fields = Get-RuleFields $_
        foreach ($name in @($fields.Keys)) {
            if ($fields[$name] -is [array]) { $fields[$name] = @($fields[$name] | Sort-Object) }
        }
        $fields
    })
    return [ordered]@{ Profiles = @($profiles); Rules = $rules }
}

function Add-ManagedRule($Rule) {
    $parameters = @{}
    foreach ($field in $Rule.Keys) {
        # Unspecified filters become Any. OverrideBlockRules is a switch, so omit it for False.
        if ($field -in @('LocalUser', 'RemoteUser', 'RemoteMachine', 'OverrideBlockRules')) { continue }
        if ($field -notin @('Profile', 'InterfaceType') -and $Rule[$field] -is [string] -and $Rule[$field] -eq 'Any') { continue }
        $parameters[$field] = $Rule[$field]
    }
    New-NetFirewallRule @parameters | Out-Null
}

function Assert-InstalledPlan($Plan) {
    $snapshot = Get-GpoSnapshot
    foreach ($expected in $Plan.Profiles) {
        $actual = @($snapshot.Profiles | Where-Object Name -eq $expected.Name)[0]
        foreach ($field in $expected.Keys) {
            if ($field -eq 'PolicyStore') { continue }
            if ($field -eq 'DisabledInterfaceAliases') {
                if (@($actual[$field] | Where-Object { $_ -and $_ -ne 'NotConfigured' }).Count) {
                    throw "PROFILE_READBACK_FAILED: $($expected.Name).$field"
                }
            } elseif ($actual[$field] -ne $expected[$field]) { throw "PROFILE_READBACK_FAILED: $($expected.Name).$field" }
        }
    }
    $activeAllows = @($snapshot.Rules | Where-Object { $_.Action -eq 'Allow' -and $_.Enabled -eq 'True' })
    if ($activeAllows.Count -ne $Plan.Rules.Count) { throw 'UNEXPECTED_ENABLED_ALLOW_COUNT' }
    foreach ($expected in $Plan.Rules) {
        $matchesByName = @($activeAllows | Where-Object Name -eq $expected.Name)
        if ($matchesByName.Count -ne 1) { throw "MISSING_MANAGED_RULE: $($expected.Name)" }
        foreach ($field in $expected.Keys) {
            if ((Normalize-GuardFilter $matchesByName[0][$field]) -ne (Normalize-GuardFilter $expected[$field])) {
                throw "RULE_READBACK_FAILED: $($expected.Name).$field"
            }
        }
    }
}

function New-GpoBackup([string]$Directory) {
    $Directory = Get-SafeLocalPath $Directory -AllowMissing
    $null = [IO.Directory]::CreateDirectory($Directory)
    $Directory = Get-SafeLocalPath $Directory
    $stem = 'guest-gpo-{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [Guid]::NewGuid().ToString('N')
    $wfw = Join-Path $Directory ($stem + '.wfw')
    $manifest = Join-Path $Directory ($stem + '.json')
    $snapshot = Get-GpoSnapshot
    Invoke-GpoWfw export $wfw
    $wfw = Get-SafeLocalPath $wfw
    if ((Get-Item -LiteralPath $wfw).Length -le 0) { throw 'EMPTY_WFW_BACKUP' }
    $record = [ordered]@{
        Version = 1; PolicyStore = $store; GuestHostname = [Environment]::MachineName
        CreatedUtc = [DateTime]::UtcNow.ToString('o'); WfwSha256 = (Get-FileHash -LiteralPath $wfw -Algorithm SHA256).Hash
        Snapshot = $snapshot
    }
    $data = [Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 12))
    $stream = [IO.File]::Open($manifest, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try { $stream.Write($data, 0, $data.Length) } finally { $stream.Dispose() }
    return $manifest
}

function Restore-GpoBackup([string]$Path) {
    $manifest = Get-SafeLocalPath $Path
    if ([IO.Path]::GetExtension($manifest) -ne '.json') { throw 'JSON_BACKUP_PATH_REQUIRED' }
    $record = [IO.File]::ReadAllText($manifest) | ConvertFrom-Json
    if ($record.Version -ne 1 -or $record.PolicyStore -ne $store -or
        $record.GuestHostname -ne [Environment]::MachineName -or $record.WfwSha256 -notmatch '\A[0-9A-Fa-f]{64}\z' -or
        @($record.Snapshot.Profiles).Count -ne 3 -or @($profileNames | Where-Object { $_ -notin $record.Snapshot.Profiles.Name }).Count -or
        $record.Snapshot.Rules -isnot [array]) { throw 'INVALID_OR_WRONG_GUEST_BACKUP' }
    $wfw = Get-SafeLocalPath ([IO.Path]::ChangeExtension($manifest, '.wfw'))
    $wfwLock = [IO.File]::Open($wfw, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ((Get-FileHash -InputStream $wfwLock -Algorithm SHA256).Hash -ne $record.WfwSha256) { throw 'WFW_HASH_MISMATCH' }
        Invoke-GpoWfw import $wfw
    } finally { $wfwLock.Dispose() }
    $expected = $record.Snapshot | ConvertTo-Json -Depth 12 -Compress
    $actual = Get-GpoSnapshot | ConvertTo-Json -Depth 12 -Compress
    if ($actual -cne $expected) { throw 'ROLLBACK_READBACK_MISMATCH' }
}

try {
    if ($Mode -eq 'Apply' -and !$ConfirmTierC) { throw 'APPLY_REQUIRES_CONFIRM_TIER_C' }
    if ($Mode -eq 'Rollback' -and !$BackupPath) { throw 'ROLLBACK_REQUIRES_BACKUP_PATH' }
    if ($Mode -ne 'DryRun') { Assert-Administrator }
    if ($AsJson -and $Mode -ne 'DryRun') { throw 'AS_JSON_IS_DRYRUN_ONLY' }
    if (($Mode -ne 'Apply' -and ($ConfirmTierC -or $BackupDir)) -or
        ($Mode -ne 'Rollback' -and $BackupPath) -or ($Mode -eq 'Rollback' -and $ConfigPath)) {
        throw 'MODE_ARGUMENT_MISMATCH'
    }
    if ($Mode -ne 'Rollback') {
        if (!$ConfigPath) { throw 'CONFIG_PATH_REQUIRED' }
        $configFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
        $configFile = Get-SafeLocalPath $configFile
        $cfg = Read-SetupConfig $configFile
        if ($Mode -eq 'Apply' -and $cfg.guest_hostname -ne [Environment]::MachineName) { throw 'WRONG_GUEST' }
        $plan = New-SetupPlan $cfg
    }
    if ($Mode -eq 'DryRun') {
        if ($AsJson) { $plan | ConvertTo-Json -Depth 12 }
        else {
            Write-Output "DryRun for $($plan.GuestHostname) (localhost GPO)"
            Write-Output 'Profiles:'
            $plan.Profiles | ConvertTo-Json -Depth 12
            Write-Output 'Rules:'
            $plan.Rules | ConvertTo-Json -Depth 12
            Write-Output $plan.Cleanup, $plan.Rollback
        }
        exit 0
    }

    $mutex = [Threading.Mutex]::new($false, 'Global\ClaudeFortress.GuestGpoSetup')
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (!$locked) { throw 'GPO_SETUP_ALREADY_RUNNING' }
        Import-Module NetSecurity
        if ($Mode -eq 'Rollback') {
            Restore-GpoBackup $BackupPath
            Write-Output 'localhost GPO firewall backup restored and checked.'
        } else {
            if (!$BackupDir) {
                $BackupDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeFortress\GpoBackups'
            }
            $backup = New-GpoBackup $BackupDir
            $rollback = "& '$($PSCommandPath.Replace("'", "''"))' -Mode Rollback -BackupPath '$($backup.Replace("'", "''"))'"
            Write-Output "Backup: $backup"
            Write-Output "Rollback: $rollback"
            try {
                $managed = @($plan.Rules | ForEach-Object { $_.Name })
                $existing = @(Get-NetFirewallRule -PolicyStore $store)
                foreach ($rule in $existing) {
                    if ($rule.Name -in $managed) { Remove-NetFirewallRule -PolicyStore $store -Name $rule.Name }
                }
                foreach ($rule in $plan.Rules) { Add-ManagedRule $rule }
                foreach ($rule in $existing) {
                    if ($rule.Name -notin $managed -and $rule.Action -eq 'Allow' -and $rule.Enabled -eq 'True') {
                        Disable-NetFirewallRule -InputObject $rule
                    }
                }
                foreach ($profile in $plan.Profiles) {
                    $parameters = @{} + $profile
                    Set-NetFirewallProfile @parameters
                }
                Assert-InstalledPlan $plan
                Write-Output 'localhost GPO written and checked. Verify ActiveStore on the guest after policy refresh.'
            } catch { throw "APPLY_FAILED: $($_.Exception.Message)`nRollback: $rollback" }
        }
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
