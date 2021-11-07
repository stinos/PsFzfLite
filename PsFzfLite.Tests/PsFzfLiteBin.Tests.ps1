Import-Module Pester
Import-Module $PSScriptRoot.Replace('.Tests', '') -Force

if (($PSVersionTable.PSVersion.Major -ge 6) -and $IsWindows) {
  Describe 'Read-PipeOrTerminate' {
    It 'Returns command output immediately after command exits' {
      & {while ($True) {
          'foo'
        }} |
        cmd /d /c (New-PipeOrTerminateArgs 'echo abc') |
        Read-PipeOrTerminate |
        Should -Be 'abc'
    }

    It 'Stops pipeline immediately after external command exits without output' {
      & {while ($True) {
          'foo'
        }} |
        cmd /d /c (New-PipeOrTerminateArgs 'oops 2>NUL') |
        Read-PipeOrTerminate |
        Should -Be $null
    }
  }
}

if ($PSVersionTable.PSVersion.Major -ge 6) {
  Describe 'New-InterruptibleCommand' {
    It 'Fails for non-existing commands' {
      {New-InterruptibleCommand nosuchcommandexists} |
        Should -Throw
    }

    if ($IsWindows) {
      It 'Pipes input to the command and stops when pipe exits' {
        1..3 |
          New-InterruptibleCommand sort.exe |
          Should -Be @(1, 2, 3)
      }

      # This one should normally have exited already before we could get the handle,
      # which will print a warning.
      It 'Returns command output immediately after command exits' {
        & {while ($True) {
            'foo'
          }} |
          New-InterruptibleCommand cmd /c echo abc |
          Should -Be 'abc'
      }

      # Whereas this one takes long enough that the normal exit event principle gets used.
      It 'Detects process exit for long-running commands' {
        New-InterruptibleCommand pwsh -NoProfile -Command 'Start-Sleep -Milli 500' |
          Should -Be $null
      }
    }
    else {
      It 'Returns command output immediately after command exits' {
        & {while ($True) {
            'foo'
          }} |
          New-InterruptibleCommand cat nonexistingfile |
          Should -Be $null
      }

      It 'Pipes input to the command and stops pipe when command exits' {
        1..3 |
          New-InterruptibleCommand head -n 3 |
          Should -Be @(1, 2, 3)
      }
    }
  }
}

Describe 'Get-ChildPathNames' {
  It 'Lists paths as strings relative to a directory' {
    $root = $PSScriptRoot
    $files = Get-ChildItem $root -File | ForEach-Object {$_.Name}
    Get-ChildPathNames -Path $root | Should -Be $files
    Get-ChildPathNames -Path "$root/somedir/.." | Should -Be $files
    Get-ChildPathNames -Path $root -PathReplacement './' | Should -Be ($files | ForEach-Object {"./$_"})
  }
}
