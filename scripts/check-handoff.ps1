[CmdletBinding()]
param([string]$ShareRoot = '.', [switch]$Strict)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-safe-path.ps1')
$sections = '一句话','当前状态','先读什么','怎么运行 / 复现','待办与未决','注意事项','变更记录'

function Test-HandoffStructure([string]$Text) {
    $found = @{}
    $key = $null
    $fence = $null
    $htmlComment = $false
    foreach ($line in ($Text -split '\r?\n')) {
        $isFence = $line -match '^ {0,3}((?:\x60{3,})|(?:~{3,}))(.*)$'
        if ($fence) {
            if ($isFence -and $Matches[1][0] -eq $fence[0] -and $Matches[1].Length -ge $fence.Length -and !$Matches[2].Trim()) { $fence = $null }
            continue
        }
        if ($htmlComment) { if ($line.Contains('-->')) { $htmlComment = $false }; continue }
        if ($line.Contains('<!--')) {
            if (!$line.Substring($line.IndexOf('<!--') + 4).Contains('-->')) { $htmlComment = $true }
            continue
        }
        if ($isFence) { $fence = $Matches[1]; continue }
        if ($line -match '^ {0,3}##[ \t]+([^#].*?)[ \t]*#*[ \t]*$') {
            $key = $Matches[1].Trim()
            if ($found.ContainsKey($key)) { return $false }
            $found[$key] = $false
        } elseif ($line -match '^ {0,3}#{1,6}[ \t]+') {
            if ($line -match '^ {0,3}#[ \t]+') { $key = $null }
        } elseif ($key -and $line -match '[\p{L}\p{N}]' -and $line -notmatch '^\s*<!--') {
            if ($line -match '（待填写）') { return $false }
            $found[$key] = $true
        }
    }
    return (!$fence -and !$htmlComment -and @($sections | Where-Object { !$found[$_] }).Count -eq 0)
}

try {
    $projects = Get-LocalSafePath (Join-Path $ShareRoot 'projects')
    $jobs = @(Get-ChildItem -LiteralPath $projects -Directory -Force | Where-Object { $_.Name -notmatch '^[._]' })
    if (!$jobs.Count) { throw 'NO_JOBS' }
} catch { 'STATUS:PROJECT_ENUMERATION_FAILED_OR_EMPTY'; exit 2 }
$ok = 0
$failed = 0
foreach ($job in $jobs) {
    try {
        $root = Get-LocalSafePath $job.FullName
        $candidates = @('交接文档.md','工作记录\交接文档.md' | ForEach-Object { Get-LocalSafePath (Join-Path $root $_) })
        $existing = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
        if ($existing.Count -ne 1) { throw 'MISSING_OR_AMBIGUOUS_HANDOFF' }
        if ((Get-Item -LiteralPath $existing[0]).Length -gt 1MB) { throw 'DOCUMENT_TOO_LARGE' }
        $utf8 = New-Object Text.UTF8Encoding($false,$true)
        if (!(Test-HandoffStructure ([IO.File]::ReadAllText($existing[0],$utf8)))) { throw 'INVALID_OR_TEMPLATE' }
        if ($Strict) {
            $meta = Get-LocalSafePath (Join-Path $root '.git')
            if (!(Test-Path -LiteralPath (Get-LocalSafePath (Join-Path $meta 'HEAD')) -PathType Leaf)) { throw 'INDEPENDENT_REPOSITORY_LAYOUT_MISSING' }
            foreach ($entry in 'objects','refs') {
                if (!(Test-Path -LiteralPath (Get-LocalSafePath (Join-Path $meta $entry)) -PathType Container)) { throw 'INDEPENDENT_REPOSITORY_LAYOUT_MISSING' }
            }
        }
        $ok++
    } catch { $failed++; Write-Output ('JOB_' + ($ok + $failed) + ': INVALID_OR_UNREADABLE') }
}
"STATUS:STRUCTURE_ONLY_OK=$ok; FAILED=$failed; GIT_HISTORY=NOT_RUN"
if ($failed) { exit 1 }
exit 0
