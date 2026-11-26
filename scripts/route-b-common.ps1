function Test-FortressIPv4([object]$Value) {
    if ($Value -isnot [string] -or $Value -cnotmatch '^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$') { return $false }
    foreach ($segment in $Value.Split('.')) { if ([int]$segment -gt 255) { return $false } }
    return $true
}

function Get-FortressRoot {
    return (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeFortress')
}

function Assert-FortressPath([string]$Path, [string]$Root = (Get-FortressRoot)) {
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(2).Contains(':')) { throw 'ABSOLUTE_LOCAL_PATH_REQUIRED' }
    $full = [IO.Path]::GetFullPath($Path)
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($full -ne $base -and !$full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'PATH_OUTSIDE_TRUST_ROOT' }
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':')) { throw 'NONLOCAL_PATH' }
    $admins = @('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $cursor = $full
    do {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'REPARSE_POINT' }
        if ($cursor -eq $base -or $cursor.StartsWith($base + '\',[StringComparison]::OrdinalIgnoreCase)) {
            $acl = Get-Acl -LiteralPath $cursor
            if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $admins) { throw 'UNTRUSTED_OWNER' }
            foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
                if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $admins -and
                    ($rule.FileSystemRights -band 0xD0156)) { throw 'UNTRUSTED_WRITER' }
            }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    } while ($cursor)
}

function Read-FortressConfig([string]$Path) {
    Assert-FortressPath $Path
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt 16384) { throw 'CONFIG_TOO_LARGE' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','') } finally { $sha.Dispose() }
    $cfg = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json
    if ($cfg.schema_version -isnot [int] -or $cfg.schema_version -ne 2) { throw 'INVALID_CONFIG_SCHEMA' }
    foreach ($name in 'target_alias','generation','guest_hostname') {
        if ($cfg.$name -isnot [string] -or $cfg.$name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $cfg.$name -eq 'REPLACE-ME') { throw "INVALID_CONFIG_$name" }
    }
    if ($cfg.guest_hostname -ne [Environment]::MachineName) { throw 'WRONG_GUEST' }
    foreach ($name in 'entry_ipv4','expected_egress_ipv4','dhcp_ipv4','management_ipv4') {
        if (!(Test-FortressIPv4 $cfg.$name) -or $cfg.$name -match '^(192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|0\.|127\.|255\.)') { throw "INVALID_CONFIG_$name" }
    }
    foreach ($name in 'entry_port','proxy_port') {
        if ($cfg.$name -isnot [int] -or $cfg.$name -lt 1 -or $cfg.$name -gt 65535) { throw "INVALID_CONFIG_$name" }
    }
    foreach ($name in 'lan_adapter','tun_adapter') {
        if ($cfg.$name -isnot [string] -or $cfg.$name -notmatch '^[\p{L}\p{N} ._-]{1,64}$') { throw "INVALID_CONFIG_$name" }
    }
    if ($cfg.lan_adapter -eq $cfg.tun_adapter -or $cfg.tun_ipv4_cidr -ne '198.18.0.0/16') { throw 'INVALID_TUN_CONFIG' }
    foreach ($name in 'core_path','sshd_path') {
        if ($cfg.$name -isnot [string] -or $cfg.$name -notmatch '^[A-Za-z]:\\[^\r\n"*?]+\.exe$') { throw "INVALID_CONFIG_$name" }
    }
    if ($cfg.desktop_sid -isnot [string] -or $cfg.desktop_sid -notmatch '^S-1-5-21-(\d+-){3}\d+$' -or
        $cfg.app_id -isnot [string] -or $cfg.app_id -notmatch '^[A-Za-z0-9._-]+![A-Za-z0-9._-]+$' -or
        $cfg.app_publisher -isnot [string] -or $cfg.app_publisher -notmatch '^CN=.{1,512}$') { throw 'INVALID_DESKTOP_IDENTITY' }
    return [pscustomobject]@{ Config = $cfg; Sha256 = $hash }
}

function Test-FortressFresh([object]$Timestamp, [int]$MaxSeconds) {
    if ($Timestamp -isnot [string] -or $Timestamp -notmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d{1,7})?Z$') { return $false }
    $parsed = [DateTimeOffset]::MinValue
    if (![DateTimeOffset]::TryParse($Timestamp,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$parsed)) { return $false }
    $age = ([DateTimeOffset]::UtcNow - $parsed).TotalSeconds
    return ($age -ge 0 -and $age -le $MaxSeconds)
}

function Test-FortressTrue([object]$Value) { return ($Value -is [bool] -and $Value) }

function Read-FortressRecord([string]$Path) {
    Assert-FortressPath $Path
    if ((Get-Item -LiteralPath $Path).Length -gt 32768) { throw 'RECORD_TOO_LARGE' }
    return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}
