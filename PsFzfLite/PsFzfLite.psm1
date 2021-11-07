# Arguments control what gets loaded and exported.
# Usage: Import-Module PsfzfLite -ArgumentList @{Binaries = $True; Fuzzies = $True}
# When omitting a value it gets assigned a default so it's not necessary to specify everything.
param([parameter(Position = 0, Mandatory = $false)] [Hashtable] $ModuleArguments = @{})

$defaultArguments = @{
  Binaries = $True; # Use PsFzfLiteBin, compile and use the .cs code.
  Fuzzies = $True; # Use PsFzfLiteFuzzies.
}
foreach ($item in $defaultArguments.GetEnumerator()) {
  if (-not $ModuleArguments.ContainsKey($item.Name)) {
    $ModuleArguments[$item.Name] = $item.Value
  }
}

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'PsFzfLiteCore.ps1')

Export-ModuleMember -Function @(
  'Add-SingleQuotes',
  'Remove-Quotes',
  'Test-CommandIsCd',
  'ConvertTo-ReplInput',
  'ConvertTo-ShellCommand',
  'Get-UniqueReversedLines',
  'Get-ReadlineState',
  'Get-PathBeforeCursor',
  'Add-TextAtCursor'
)

if ($ModuleArguments.Binaries) {
  . (Join-Path $PSScriptRoot 'PsFzfLiteBin.ps1')
  Install-FileSystemWalker
  Install-PipelineHelper
  Export-ModuleMember -Function @(
    'Read-PipeOrTerminate',
    'New-PipeOrTerminateArgs',
    'New-InterruptibleCommand'
  )
  Export-ModuleMember -Cmdlet @(
    'Get-ChildPathNames'
  )
}

if ($ModuleArguments.Fuzzies) {
  . (Join-Path $PSScriptRoot 'PsFzfLiteFuzzies.ps1')
  Export-ModuleMember -Function @(
    'Invoke-FuzzyKillProcess',
    'Invoke-FuzzyZLocation',
    'Invoke-FuzzyGetCommand',
    'Invoke-FuzzyGetCmdlet',
    'Invoke-FuzzyHistory'
  )
  if ($ModuleArguments.Binaries) {
    Export-ModuleMember -Function @(
      'Invoke-FuzzyBrowse'
    )
  }
}
