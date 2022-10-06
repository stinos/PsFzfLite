<#
.SYNOPSIS
Surround string with single quotes.
.PARAMETER Items
String(s) to quote.
.OUTPUTS
Quoted strings(s).
#>
function Add-SingleQuotes {
  param (
    [Parameter(ValueFromPipeline)] [String[]] $Items
  )
  process {
    if ($null -eq $Items) {
      ''
    }
    foreach ($item in $Items) {
      if (-not $item) {
        ''
      }
      else {
        $esc = [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($item)
        "'$esc'"
      }
    }
  }
}

<#
.SYNOPSIS
Trim all quotes.
.PARAMETER Value
String(s) to trim.
.OUTPUTS
Trimmed string.
#>
function Remove-Quotes {
  param (
    [Parameter()] [String[]] $Value
  )
  if ($null -ne $Value) {
    $Value.Trim('''"')
  }
}

<#
.SYNOPSIS
Check if a command is cd-like (Set-Location, Push-Location and aliases).
#>
function Test-CommandIsCd {
  param (
    [Parameter()] [String] $Name
  )
  if (-not $Name) {
    return $False
  }
  $command = Get-Command $Name -Type Alias -ErrorAction SilentlyContinue
  if (-not $command) {
    # Not an alias
    $command = $Name
  }
  elseif ($command | Get-Member 'ResolvedCommandName') {
    $command = $command.ResolvedCommandName
  }
  return $command -in @('Push-Location', 'Set-Location')
}

<#
.SYNOPSIS
Turns input into string usable as a PS value when inserted on the commandline.
.DESCRIPTION
For use on fzf output: add quotes if needed (if it has a space or other special characters)
and in case there are multiple items create an array @() representation. For instance when
the input is @('foo', 'bar') this will return the string "@('foo', 'bar')" so when that gets
pasted verbatim via PsReadLine functions it will turn up as @('foo', 'bar') again.
.OUTPUTS
A string, to be used with e.g. Add-TextAtCursor.
#>
function ConvertTo-ReplInput {
  param (
    [Parameter(ValueFromPipeline)] [String[]] $Items
  )
  begin {
    $allInput = @()
  }
  process {
    $allInput += $Items
  }
  end {
    if ($allInput.Length -gt 1) {
      "@($(($allInput | Add-SingleQuotes ) -Join ','))"
    }
    elseif ($allInput) {
      $allInput = $allInput[0]
      if ($allInput.IndexOfAny("``&@'#{}()$,;|<> `t") -ge 0) {
        Add-SingleQuotes $allInput
      }
      else {
        $allInput
      }
    }
  }
}

<#
.SYNOPSIS
Wrap each item passed in double quotes and return as one string joined by spaces.
.DESCRIPTION
For creating a command to use with cmd. Note this just quotes the arguments, so cmd
recognizes them as individual arguments, but does not do any escaping: idea is to pass
arguments as one would type them on the commandline. So when typing this in PS:
fzf --preview-window="right:60%" --preview 'echo \"quo\"'
this is equivalent to runnig this (so with the same arguments) with cmd:
cmd /c (ConvertTo-ShellCommand @('fzf', '--preview-window="right:60%"', '--preview', 'echo \"quo\"'))
.NOTES
Not tested extensively, might not do the correct thing for all cases.
.PARAMETER Command
The command and its arguments.
.OUTPUTS
Single command string.
#>
function ConvertTo-ShellCommand {
  Param(
    [Parameter(Mandatory)] [String[]] $Command
  )
  ($Command | ForEach-Object {"`"$_`""}) -join ' '
}

<#
.SYNOPSIS
Read all lines from file, return in reversed order and unique.
.DESCRIPTION
Use for sorting (Get-PSReadLineOption).HistorySavePath in an MRU way for feeding into fzf.
.PARAMETER Path
File to read.
.OUTPUTS
Sorted unique lines.
#>
function Get-UniqueReversedLines {
  param(
    [Parameter(Mandatory)] [String] $Path
  )
  $seen = New-Object Collections.Generic.List[String]
  foreach ($line in [Linq.Enumerable]::Reverse([IO.File]::ReadAllLines($Path))) {
    if ($line -and (-not $seen.Contains($line))) {
      $seen.Add($line)
      $line
    }
  }
}

<#
.SYNOPSIS
Convenience wrapper for [PSConsoleReadLine]::GetBufferState().
.DESCRIPTION
Calls one of the overloads depending on the information needed and returns the
values instead of using ref arguments.
.PARAMETER Tokens
Whether to return tokens, or just line and cursor position.
.PARAMETER Tokens
Whether to return ast/tokens/errors/cusrsor.
.OUTPUTS
See flag description.
#>
function Get-ReadlineState {
  param(
    [Parameter()] [Switch] $Tokens,
    [Parameter()] [Switch] $Full
  )
  if ($Tokens -or $Full) {
    $ast = $null
    $tok = $null
    $errors = $null
    $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$ast, [ref]$tok, [ref]$errors, [ref]$cursor)
    if ($Tokens) {
      $tok, $cursor
    }
    else {
      $ast, $tok, $errors, $cursor
    }
  }
  else {
    $line = $null
    $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    $line, $cursor
  }
}

<#
.SYNOPSIS
Check if the content before the cursor looks like a path and return that if so.
.DESCRIPTION
Use for determining root directory for fuzzy browsing: if the cursor is after a path
we want to use that as root directory, moreover if it has 'cd' before it we want to know
that as well since then we should be browsing directories.

Using tokens and cursor from  Get-ReadlineState -Tokens, inspect the token(s)
right before the cursor and return that token if it is an existing directory,
and a flag indicating whether there's a cd/Set-Location.
Examples (showing commandline before cursor):
 <eof> -> $null
 cd -> $null, $True
 someDir -> someDir, $False
 cd someDir -> someDir, $True
#>
function Get-PathBeforeCursor {
  param(
    [Parameter(Mandatory)] [Object[]] $tokens,
    [Parameter(Mandatory)] [int] $cursor
  )
  for ($i = $tokens.Length - 1; $i -ge 0; $i--) {
    # Last one which ends before token.
    if ($tokens[$i].Extent.EndOffset -le $cursor) {
      $text = $tokens[$i].Text
      $bareText = Remove-Quotes $text  # Need to remove quotes for Test-Path.
      if ($bareText -and (Test-Path -Type Container $bareText)) {
        return $tokens[$i], ($i -gt 0 -and (Test-CommandIsCd $tokens[$i - 1].Text))
      }
      elseif (Test-CommandIsCd $text) {
        return $null, $True
      }
    }
  }
}

<#
.SYNOPSIS
Add text at current cursor location, for use after fzf.
.DESCRIPTION
This just calls [Microsoft.PowerShell.PSConsoleReadLine]::Insert with the
argument (if any) but first calls InvokePrompt because without this the
prompt does not get redrawn i.e. just a black screen is shown.
#>
function Add-TextAtCursor {
  [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
  if ($Args) {
    [Microsoft.PowerShell.PSConsoleReadLine]::Insert($Args[0])
  }
  elseif ($Input) {
    [Microsoft.PowerShell.PSConsoleReadLine]::Insert($Input)
  }
}

<#
.SYNOPSIS
Get word before cursor, and if any add it to the fzf args as initial query.
.DESCRIPTION
For use in conjunction with Write-FzfResult: for many key handlers using fzf it's
equally convenient/matter of preference invoking fzf then starting to type the query,
vs typing the query or a part of it then invoking fzf.
This function gets the current line content and builds the --query argument with it
into the given fzf arguments list; the query is considered the word before the cursor
position; the cursor must be directly after the word, a space then a cursor does not
treat the word before the space as query.
.EXAMPLE
$fzfArgs, $fzQuery = Get-InitalFzfQuery $fzfArgs
fzf @fzfArgs | Write-FzfResult -FzfQuery $fzQuery
.PARAMETER FzfArgs
Additional arguments for fzf, can be empty.
.OUTPUTS
Updated FzfArgs and input object for Write-FzfResult.
#>
function Get-InitialFzfQuery {
  param(
    [Parameter()] [Object[]] $FzfArgs = @()
  )
  $line, $cursor = Get-ReadlineState
  # Anything after cursor is irrelevant, treat full word before cursor as query,
  # so index + 1 because word starts after the space found,
  # and in case of no match i.e. -1 conveniently makes 0 as query start.
  $queryIndex = $line.LastIndexOf(' ', $cursor) + 1
  if ($queryIndex -gt $cursor) {
    $queryIndex = $cursor
  }
  $queryLength = $cursor - $queryIndex
  $query = $line.SubString($queryIndex, $queryLength).Trim()
  # Could be cursor is at or after whitespace, so not an actual query.
  if ($query) {
    $FzfArgs += '--query'
    $FzfArgs += $query
  }
  $FzfArgs, @($queryIndex, $queryLength)
}

<#
.SYNOPSIS
Replace query found by Get-InitalFzfQuery with fzf result, or just insert fzf result in case of empty query.
.PARAMETER FzfResult
The fzf return value. No replacement/insertion happens if this is empty.
.PARAMETER $FzfQuery
Second output of Get-InitalFzfQuery.
#>
function Write-FzfResult {
  param(
    [Parameter(ValueFromPipeline)] [Object] $FzfResult,
    [Parameter(Mandatory)] [int[]] $FzfQuery
  )
  [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
  if ($FzfResult) {
    [Microsoft.PowerShell.PSConsoleReadLine]::Replace($FzfQuery[0], $FzfQuery[1], $FzfResult)
  }
}
