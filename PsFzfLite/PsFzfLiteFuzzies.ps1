<#
.SYNOPSIS
Pipe Get-Process into fzf, then into Stop-Process.
#>
function Invoke-FuzzyKillProcess {
  Get-Process |
    ForEach-Object {$_.Name + ' ' + $_.Id} |
    fzf --multi |
    ForEach-Object {$_.Split(' ')[-1]} |
    ForEach-Object {Stop-Process $_ -Confirm}
}

<#
.SYNOPSIS
Pipe Get-ZLocation into fzf, then into Set-Location.
.DESCRIPTION
ZLocation is great, the combination with fzf is even better:
never manually cd more than once anymore.
#>
function Invoke-FuzzyZLocation {
  (Get-ZLocation).GetEnumerator() |
    Sort-Object {$_.Value} -Desc |
    ForEach-Object {$_.Name.ToLower()} | # Get-ZLocation can have duplicate locations with mixed case.
    Select-Object -Unique |
    fzf |
    Select-Object -First 1 |
    Set-Location
}

<#
.SYNOPSIS
Pipe Get-Command for non-PS types into fzf and insert result at cursor.
.DESCRIPTION
Use for fuzzy browsing any .exe in the PATH.
If cursor is at the end of a word, that word is used as initial fzf query and replaced afterwards.
.PARAMETER FzfArgs
Additional arguments for fzf.
.EXAMPLE
Invoke-FuzzyGetCommand -FzfArgs @('--preview', '(Get-Command {}).Source')
#>
function Invoke-FuzzyGetCommand {
  param(
    [Parameter()] [Object[]] $FzfArgs = @()
  )
  $FzfArgs, $fzfQuery = Get-InitialFzfQuery $FzfArgs
  Get-Command -CommandType Application |
    ForEach-Object {$_.Name} |
    fzf @FzfArgs |
    Write-FzfResult -FzfQuery $fzfQuery
}

<#
.SYNOPSIS
Pipe Get-Command for PS types into fzf and insert result at cursor.
.DESCRIPTION
Use for fuzzy browsing PS commands.
If cursor is at the end of a word, that word is used as initial fzf query and replaced afterwards.
.PARAMETER FzfArgs
Additional arguments for fzf.
.EXAMPLE
Invoke-FuzzyGetCmdlet -FzfArgs @('--preview', 'Get-Command {} -ShowCommandInfo')
#>
function Invoke-FuzzyGetCmdlet {
  param(
    [Parameter()] [Object[]] $FzfArgs = @()
  )
  $FzfArgs, $fzfQuery = Get-InitialFzfQuery $FzfArgs
  @(
    (Get-Command -CommandType Function -ListImported),
    (Get-Command -CommandType CmdLet -ListImported),
    (Get-Command -CommandType Alias -ListImported)
  ) |
    ForEach-Object {$_.Name} |
    fzf @FzfArgs |
    Write-FzfResult -FzfQuery $fzfQuery
}

<#
.SYNOPSIS
Pipe PSReadLine history into fzf and insert result at cursor.
.DESCRIPTION
The typical Ctrl-R command.
If cursor is at the end of a word, that word is used as initial fzf query and replaced afterwards.
.PARAMETER FzfArgs
Additional arguments for fzf.
.EXAMPLE
# Add a key binding for deleting selected entries from history.
Invoke-FuzzyGetCmdlet -FzfArgs @(
  '--multi', # Not too useful when selecting history, but extremely useful for deleting multiple entries.
  '--bind',
  'ctrl-d:execute($i=@(Get-Content {+f}); $h=(Get-PSReadLineOption).HistorySavePath; (Get-Content $h) | ?{$_ -notin $i} | Out-File $h -Encoding utf8NoBom)'
)
#>
function Invoke-FuzzyHistory {
  param(
    [Parameter()] [Object[]] $FzfArgs = @()
  )
  $FzfArgs += '--no-sort' # Get-UniqueReversedLines already has proper order.
  $FzfArgs, $fzfQuery = Get-InitialFzfQuery $FzfArgs
  Get-UniqueReversedLines (Get-PSReadLineOption).HistorySavePath |
    fzf @fzfArgs |
    Write-FzfResult -FzfQuery $fzfQuery
}

<#
.SYNOPSIS
List files or directories and pipe into fzf, inserting the result at the cursor.
.DESCRIPTION
The typical Ctrl-P (or Ctrl-T depending on what you're used to) command.
Will try to figure out what is meant: looks for the start path currently before the cursor
and when there's a 'cd' will only browse directories. Unlike standard implementations
this also means it's possible to browse for directories outside of the current one by
first typing the path and then invoking this function.
.PARAMETER FzfDirArgs
Additional arguments for fzf when browsing directories.
.PARAMETER FzfFileArgs
Additional arguments for fzf when browsing files.
.PARAMETER Directory
Force listing directories, not files.
.PARAMETER UseInterruptibleCommand
Windows only: use New-InterruptibleCommand instead of Read-PipeOrTerminate.
.OUTPUTS
The fzf return value(s), quoted and ar array when needed.
#>
function Invoke-FuzzyBrowse {
  param(
    [Parameter()] [String[]] $FzfDirArgs = @(),
    [Parameter()] [String[]] $FzfFileArgs = @(),
    [Parameter()] [switch] $Directory,
    [Parameter()] [switch] $UseInterruptibleCommand
  )
  $tokens, $cursor = Get-ReadlineState -Tokens
  $initPath, $isCd = Get-PathBeforeCursor $tokens $cursor
  if ($Directory) {
    $isCd = $True
  }
  if (-not $initPath) {
    $root = '.'
    $pathReplacement = ''
  }
  else {
    $root = Remove-Quotes $initPath.Text
    $pathReplacement = $root
  }
  if ($isCd) {
    if ($UseInterruptibleCommand -or -not $IsWindows) {
      $result = Get-ChildPathNames -Path $root -PathReplacement $pathReplacement -SearchType (
        [PsFzfLite.FileSystemWalker+SearchType]::Directories) |
        New-InterruptibleCommand (@('fzf') + $FzfDirArgs)
    }
    else {
      # Note: even though Get-ChildPathNames is plenty fast, we unfortunately still have to pipe
      # the output around so don't achieve the typical raw fzf speed here but around 3x slower.
      # Still much better than using cmd /c dir or Get-ChildItem though.
      # Note: see https://stackoverflow.com/a/64666821/128384 on why this is useless for pre-v6 PS versions:
      # they buffer the complete pipe before passing anything to an external program.
      # The /d is to skip autoruns, shouldn't be needed here.
      $result = Get-ChildPathNames -Path $root -PathReplacement $pathReplacement -SearchType (
        [PsFzfLite.FileSystemWalker+SearchType]::Directories) |
        cmd /d /c (New-PipeOrTerminateArgs (ConvertTo-ShellCommand (@('fzf') + $FzfDirArgs))) |
        Read-PipeOrTerminate
    }
  }
  elseif (-not $initPath) {
    # The fast path: browse files from current dir.
    $result = fzf @FzfFileArgs
  }
  else {
    if ($UseInterruptibleCommand -or -not $IsWindows) {
      $result = Get-ChildPathNames -Path $root -PathReplacement $pathReplacement -SearchType (
        [PsFzfLite.FileSystemWalker+SearchType]::Files) |
        New-InterruptibleCommand (@('fzf') + $FzfFileArgs)
    }
    else {
      $result = Get-ChildPathNames -Path $root -PathReplacement $pathReplacement -SearchType (
        [PsFzfLite.FileSystemWalker+SearchType]::Files) |
        cmd /d /c (New-PipeOrTerminateArgs (ConvertTo-ShellCommand (@('fzf') + $FzfFileArgs))) |
        Read-PipeOrTerminate
    }
  }
  # We'll paste a path containg the current path already so delete the current one first.
  if ($initPath -and $result) {
    $len = $initPath.Extent.EndOffset - $initPath.Extent.StartOffset
    [Microsoft.PowerShell.PSConsoleReadLine]::Replace($initPath.Extent.StartOffset, $len, '')
  }
  $result | ConvertTo-ReplInput | Add-TextAtCursor
}
