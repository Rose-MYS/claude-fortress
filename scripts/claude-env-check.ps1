[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{32}$')][string]$RequestId,
    [switch]$AuthorizedNeutralProbe,
    [switch]$IncludePrivateDiagnostics
)

$ErrorActionPreference = 'Stop'
if (!$AuthorizedNeutralProbe) { throw 'EXPLICIT_NEUTRAL_PROBE_APPROVAL_REQUIRED' }
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
$info = Read-FortressConfig $ConfigPath
$cfg = $info.Config
$root = Get-FortressRoot
$reports = Join-Path $root 'reports'
Assert-FortressPath $reports
$reportPath = Join-Path $reports "$RequestId.json"
if (Test-Path -LiteralPath $reportPath) { throw 'REQUEST_ID_ALREADY_USED' }
$guardPath = Join-Path $root 'guest-egress-guard.ps1'
Assert-FortressPath $guardPath
$guard = & $guardPath -ConfigPath $ConfigPath -Status -PolicyOnly -AsObject
$policyOk = Test-FortressTrue $guard.policy_ok
$tun = @(Get-NetAdapter -Name $cfg.tun_adapter -ErrorAction SilentlyContinue)
$tunUp = $tun.Count -eq 1 -and $tun[0].Status -eq 'Up'
if (!$policyOk -or !$tunUp) { throw 'OFFLINE_BASELINE_NOT_VERIFIED' }

function Invoke-NeutralProbe([string]$Endpoint, [bool]$Proxy, [bool]$IPv6) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path ([Environment]::SystemDirectory) 'curl.exe'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($name in @($info.EnvironmentVariables.Keys)) {
        if ($name -match 'proxy|^curl_|^ssl_|^https?_') { $info.EnvironmentVariables.Remove($name) }
    }
    $family = if ($IPv6) { '-6' } else { '-4' }
    $routing = if ($Proxy) { "--noproxy no-proxy.invalid --proxy http://127.0.0.1:$($cfg.proxy_port)" } else { '--noproxy *' }
    $info.Arguments = "-q $family -fsS --proto =https --connect-timeout 4 --max-time 6 --max-filesize 4096 $routing $Endpoint"
    $proc = [Diagnostics.Process]::Start($info)
    try {
        $output = $proc.StandardOutput.ReadToEndAsync()
        $errors = $proc.StandardError.ReadToEndAsync()
        if (!$proc.WaitForExit(8000)) { $proc.Kill(); return $null }
        if (!$output.Wait(1000) -or !$errors.Wait(1000) -or $proc.ExitCode -ne 0) { return $null }
        return $output.Result.Trim()
    } finally { $proc.Dispose() }
}

$started = [DateTime]::UtcNow.ToString('o')
$sites = @('https://api.ipify.org','https://ifconfig.me/ip')
$tunResults = @($sites | ForEach-Object { Invoke-NeutralProbe $_ $false $false })
$proxyResults = @($sites | ForEach-Object { Invoke-NeutralProbe $_ $true $false })
$ipv6Response = Invoke-NeutralProbe 'https://api64.ipify.org' $false $true
$tunOk = $tunResults.Count -eq $sites.Count -and @($tunResults | Where-Object { $_ -ne $cfg.expected_egress_ipv4 }).Count -eq 0
$proxyOk = $proxyResults.Count -eq $sites.Count -and @($proxyResults | Where-Object { $_ -ne $cfg.expected_egress_ipv4 }).Count -eq 0
$ipv6Probe = if ($ipv6Response) {'reachable'} else {'no_response_in_this_probe'}
$report = [ordered]@{
    schema_version=2; request_id=$RequestId; target_alias=$cfg.target_alias; generation=$cfg.generation; config_sha256=$info.Sha256
    started_utc=$started; timestamp_utc=[DateTime]::UtcNow.ToString('o'); tun_up=$tunUp; policy_ok=$policyOk
    ipv4_tun_ok=$tunOk; ipv4_proxy_ok=$proxyOk; ipv6_probe=$ipv6Probe
    dns_evidence='not_run'; ipv6_block_evidence='not_run'; fail_closed_evidence='not_run'
    functional_pass=($tunOk -and $proxyOk -and $ipv6Probe -eq 'no_response_in_this_probe')
}
if ($IncludePrivateDiagnostics) { $report['observed_ipv4'] = @($tunResults + $proxyResults) }
$temporary = Join-Path $reports ('.' + [Guid]::NewGuid().ToString('N') + '.tmp')
$stream = [IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($report | ConvertTo-Json -Depth 5))
    $stream.Write($bytes,0,$bytes.Length)
    $stream.Flush($true)
} finally { $stream.Dispose() }
[IO.File]::Move($temporary,$reportPath)
$report | ConvertTo-Json -Depth 5 -Compress
if (!$report.functional_pass) { exit 2 }
exit 0
