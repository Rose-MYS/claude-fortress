[CmdletBinding()]
param([string]$ShareRoot='.', [switch]$DryRun, [switch]$InitGit, [string]$GitExe)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-safe-path.ps1')
try {
    $projects = Get-LocalSafePath (Join-Path $ShareRoot 'projects')
    $jobs = @(Get-ChildItem -LiteralPath $projects -Directory -Force | Where-Object { $_.Name -notmatch '^[._]' })
    if (!$jobs.Count) { throw 'NO_JOBS' }
    if ($InitGit) {
        if ($GitExe -notmatch '^[A-Za-z]:\\.*\\git\.exe$') { throw 'ABSOLUTE_TRUSTED_GIT_EXE_REQUIRED' }
        $GitExe = Get-LocalSafePath $GitExe
        if (!(Test-Path -LiteralPath $GitExe -PathType Leaf)) { throw 'GIT_EXE_NOT_FOUND' }
    }
} catch { 'STATUS:INVALID_ROOT_OR_GIT_OR_NO_JOBS'; exit 2 }

function Initialize-StandaloneGit([string]$Directory) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $GitExe
    $info.Arguments = 'init -b main --template='
    $info.WorkingDirectory = $Directory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($name in @($info.EnvironmentVariables.Keys)) {
        if ($name -match '^GIT_') { $info.EnvironmentVariables.Remove($name) }
    }
    $info.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
    $info.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = 'NUL'
    $proc = [Diagnostics.Process]::Start($info)
    try {
        $out = $proc.StandardOutput.ReadToEndAsync()
        $err = $proc.StandardError.ReadToEndAsync()
        if (!$proc.WaitForExit(15000)) { $proc.Kill(); throw 'GIT_INIT_TIMEOUT' }
        if ($proc.ExitCode -ne 0 -or !$out.Wait(1000) -or !$err.Wait(1000)) { throw 'GIT_INIT_FAILED' }
    } finally { $proc.Dispose() }
}

$failed = 0
$index = 0
foreach ($job in $jobs) {
    $index++
    try {
        $root = Get-LocalSafePath $job.FullName
        $dirs = @('工作文件','最终成品','工作记录') | ForEach-Object { Get-LocalSafePath (Join-Path $root $_) }
        $names = @('工作记录\task.json','工作记录\plan.md','交接文档.md','工作记录\交接文档.md','.gitignore','.git','.git\HEAD','.git\config','.git\hooks')
        $paths = @{}
        foreach ($name in $names) { $paths[$name] = Get-LocalSafePath (Join-Path $root $name) }
        foreach ($dir in $dirs) {
            if ((Test-Path -LiteralPath $dir) -and !(Test-Path -LiteralPath $dir -PathType Container)) { throw 'DIRECTORY_TYPE_CONFLICT' }
        }
        foreach ($file in @('工作记录\task.json','工作记录\plan.md','交接文档.md','工作记录\交接文档.md','.gitignore')) {
            if ((Test-Path -LiteralPath $paths[$file]) -and !(Test-Path -LiteralPath $paths[$file] -PathType Leaf)) { throw 'FILE_TYPE_CONFLICT' }
        }
        foreach ($dir in $dirs) { if (!$DryRun -and !(Test-Path -LiteralPath $dir)) { $null = [IO.Directory]::CreateDirectory((Get-LocalSafePath $dir)) } }
        $task = [ordered]@{ id=$job.Name; title=$job.Name; owner='host-agent'; status='planning'; steps=@(); files=@{} }
        $templates = @{
            '工作记录\task.json'=($task | ConvertTo-Json -Depth 5)
            '工作记录\plan.md'="# 作业计划`n`n## 目标`n`n（待填写）"
            '交接文档.md'="# 交接文档`n`n" + (('一句话','当前状态','先读什么','怎么运行 / 复现','待办与未决','注意事项','变更记录' | ForEach-Object { "## $_ `n`n（待填写）`n" }) -join "`n")
            '.gitignore'=".env`n*.key`n*.pem`n*.log`n*.tmp`n*.iso`n*.vmdk`nartifacts/`n"
        }
        foreach ($name in $templates.Keys) {
            if ($name -eq '交接文档.md' -and (Test-Path -LiteralPath $paths['工作记录\交接文档.md'])) { continue }
            if (!$DryRun -and !(Test-Path -LiteralPath $paths[$name])) { Write-NewLocalText $paths[$name] $templates[$name] }
        }
        if ($InitGit -and !$DryRun -and !(Test-Path -LiteralPath $paths['.git'])) { Initialize-StandaloneGit $root }
        if ($InitGit -and !$DryRun -and !(Test-Path -LiteralPath $paths['.git\HEAD'] -PathType Leaf)) { throw 'REPOSITORY_LAYOUT_UNVERIFIED' }
        if ($DryRun) { "JOB_${index}: PREVIEW_ONLY" } else { "JOB_${index}: SCAFFOLD_OK" }
    } catch { $failed++; "JOB_${index}: INVALID_OR_PARTIAL" }
}
if ($failed) { exit 1 }
exit 0
