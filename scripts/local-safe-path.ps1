function Get-LocalSafePath([string]$Path) {
    $absolute = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
    if ($absolute -notmatch '^[A-Za-z]:\\' -or $absolute.Substring(2).Contains(':') -or $absolute.Length -gt 240) { throw 'UNSUPPORTED_LOCAL_PATH' }
    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($absolute))
    if ($drive.DriveType -ne [IO.DriveType]::Fixed) { throw 'NONLOCAL_VOLUME' }
    $cursor = $absolute
    while ($cursor) {
        try { $attributes = [IO.File]::GetAttributes($cursor) } catch [IO.FileNotFoundException] { $attributes = $null } catch [IO.DirectoryNotFoundException] { $attributes = $null }
        if ($null -ne $attributes -and ($attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'REPARSE_POINT' }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $absolute
}

function Write-NewLocalText([string]$Path,[string]$Content) {
    $full = Get-LocalSafePath $Path
    $bytes = [Text.Encoding]::UTF8.GetBytes($Content)
    $stream = [IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
}
