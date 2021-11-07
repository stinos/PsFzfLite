Import-Module Pester
Import-Module $PSScriptRoot.Replace('.Tests', '') -Force

Describe 'Add-SingleQuotes' {
  It 'Returns empty string if input null or empty' {
    Add-SingleQuotes | Should -Be ''
    Add-SingleQuotes '' | Should -Be ''
  }

  It 'Surrounds its arguments with single quotes' {
    Add-SingleQuotes 1 | Should -Be "'1'"
    Add-SingleQuotes 'foo' | Should -Be "'foo'"
    Add-SingleQuotes @('foo', 'bar') | Should -Be @("'foo'", "'bar'")
    @(1, 2) | Add-SingleQuotes | Should -Be @("'1'", "'2'")
  }

  It 'Escapes single quotes' {
    Add-SingleQuotes "a'b" | Should -Be "'a''b'"
  }
}

Describe 'Remove-Quotes' {
  It 'Ignores $null' {
    Remove-Quotes $null | Should -Be $null
  }

  It 'Trims all quotes from its argument' {
    Remove-Quotes '' | Should -Be ''
    Remove-Quotes "'''`"`"" | Should -Be ''
    Remove-Quotes "'a'`"b`"" | Should -Be "a'`"b"
    Remove-Quotes @('"a"', '"b"') | Should -Be @('a', 'b')
  }

  It 'Trims all quotes from each argument' {
    Remove-Quotes @('"a"', '"b"') | Should -Be @('a', 'b')
  }
}

Describe 'Test-CommandIsCd' {
  It 'Is true for cd-like arguments' {
    Test-CommandIsCd 'cd' | Should -BeTrue
    Test-CommandIsCd 'chdir' | Should -BeTrue
    Test-CommandIsCd 'pushd' | Should -BeTrue
    Test-CommandIsCd 'Set-Location' | Should -BeTrue
  }

  It 'Is false for everything else' {
    Test-CommandIsCd | Should -BeFalse
    Test-CommandIsCd 'notcd' | Should -BeFalse
  }
}

Describe 'ConvertTo-ReplInput' {
  It 'Does nothing if no input' {
    ConvertTo-ReplInput | Should -Be $null
    @() | ConvertTo-ReplInput | Should -Be $null
  }

  It 'Returns single argument as-is if possible' {
    'foo' | ConvertTo-ReplInput | Should -Be 'foo'
    @('1') | ConvertTo-ReplInput | Should -Be '1'
  }

  It 'Makes quoted argument if needed' {
    'f oo' | ConvertTo-ReplInput | Should -Be "'f oo'"
    "f`too" | ConvertTo-ReplInput | Should -Be "'f`too'"
    'f`oo' | ConvertTo-ReplInput | Should -Be "'f``oo'"
    'f|oo' | ConvertTo-ReplInput | Should -Be "'f|oo'"
    @('f oo') | ConvertTo-ReplInput | Should -Be "'f oo'"
    ConvertTo-ReplInput 1 | Should -Be '1'
  }

  It 'Makes REPL array representation of arguments' {
    'f oo', 'bar' | ConvertTo-ReplInput | Should -Be "@('f oo','bar')"
    ConvertTo-ReplInput '1', '2' | Should -Be "@('1','2')"
  }
}

Describe 'ConvertTo-ShellCommand' {
  It 'Creates string with quoted arguments' {
    ConvertTo-ShellCommand @('a', '"b"') | Should -Be '"a" ""b""'
  }
}

Describe 'Get-UniqueReversedLines' {
  It 'Returns file content in MRU order' {
    Get-UniqueReversedLines (Join-Path $PSScriptRoot 'history.txt') |
      Should -Be @('last', 'foo', 'bar')
  }
}

Describe 'Get-PathBeforeCursor' {
  It 'Returns null if no input' {
    $tok = @(
      @{
        Extent = @{EndOffset = 0}
        Text = ''
      }
    )
    Get-PathBeforeCursor $tok 0 | Should -Be $null
  }

  It 'Detects single cd when cursor is after it' {
    $tok = @(
      @{
        Extent = @{EndOffset = 3}
        Text = 'foo'
      },
      @{
        Extent = @{EndOffset = 6}
        Text = 'cd'
      }
    )
    Get-PathBeforeCursor $tok 0 | Should -Be $null
    Get-PathBeforeCursor $tok 4 | Should -Be $null
    Get-PathBeforeCursor $tok 6 | Should -Be $null, $True
  }

  It 'Detects real path' {
    $pathToTest = $PSScriptRoot
    $tok = @(
      @{
        Extent = @{EndOffset = $pathToTest.Length}
        Text = $pathToTest
      }
    )
    Get-PathBeforeCursor $tok $pathToTest.Length | Should -Be $tok[0], $False
  }

  It 'Detects cd to real path' {
    $pathToTest = $PSScriptRoot
    $tok = @(
      @{
        Extent = @{EndOffset = 2}
        Text = 'cd'
      },
      @{
        Extent = @{EndOffset = 3 + $pathToTest.Length}
        Text = $pathToTest
      }
    )
    Get-PathBeforeCursor $tok (3 + $pathToTest.Length) | Should -Be $tok[1], $True
  }
}

