![AppVeyor tests](https://img.shields.io/appveyor/tests/stinos/PsFzfLite?logo=appveyor)

# PsFzfLite

PsFzfLite is a PowerShell module providing helpers for working with [fzf](https://github.com/junegunn/fzf),
which is a commandline fuzzy finder. The most common day-to-day usage functions are provided as well:
fuzzy file and directory finding (ctrl-t and alt-c from fzf), fuzzy history (ctrl-r).

It was inspired by [PSFzf](https://github.com/kelleyma49/PSFzf) but written from scratch taking a different
approach with the aim of providing a couple of building blocks one can use to make their own custom
functions using fzf, instead of being a complete wrapper; see rationale below.

As such [PsFzfLiteCore.ps1](PsFzfLite/PsFzfLiteCore.ps1) just has a few functions which are typically used
to provide input for and handle output from fzf. These can then be used to build higher-level functions
using. By means of example and documentation, that's exactly what is done  for the most common functions,
see [PsFzfLiteFuzzies.ps1](PsFzfLite/PsFzfLiteFuzzies.ps1).

## Requirements

Powershell Core.

Notes:
- all code is compatible with PS 5.1 but that version buffers all output from an upstream command before
piping it into a downstream external program so without workarounds (which aren't implemented currently),
feeding a lot of output (like from listing the filesystem) into fzf makes it unusable due to the wait time
- all tests pass on Linux and all fuzzies have been tested as well, but not extensively. Not tested on macOS.

## Installation

```powershell
git clone https://github.com/stinos/PsFzfLite /path/to/PsFzfLite
Import-Module /path/to/PsFzfLite
```

The import statement normally goes into `$PROFILE`.

Note that on the first import, or when the .cs files change after pulling updates, this will build 2
assemblies into the temp directory. Done mainly so to avoid having to go through building and
deploying binary releases.

The module supports arguments to control what gets imported, see [PsFzfLite.psm1](PsFzfLite/PsFzfLite.psm1).

## Functions for everyday usage

- `Invoke-FuzzyGetCommand` launch fzf with list of all .exe files in $env:PATH and insert selection at cursor,
covenient for quickly finding commands
- `Invoke-FuzzyGetCmdlet` like above, but for Powershell commands
- `Invoke-FuzzyHistory` feed PsReadLine history into fzf (no duplicates, MRU order) and insert selection
- `Invoke-FuzzyKillProcess` launch fzf with Get-Process list and kill selected processes
- `Invoke-FuzzyBrowse` select from list of paths  and insert selection; uses current token before cursor
as start path and automatically selects directory finding if there's a `cd` or similar on the commandline
- `Invoke-FuzzyZLocation` launch fzf with [ZLocation](https://github.com/vors/ZLocation) entries and
cd to the selected directory, use for fast navigation between directories used often

The easiest way to use these is binding them to keyboard shortcuts so they can be invoked quickly, plus
first 3 will automatically pre-fill fzf input with the current commandline content. See samples below.

Most of the functions have an argument for passing arguments to fzf in turn; these arguments are
passed like one would type them on the commandline. Some examples:

```powershell
# All the usual fzf arguments can be passed.
$fzfArgs = @(
  '--multi',
  '--preview', 'type {}',
  '--preview-window="right:60%"',
  '--bind', 'backward-eof:abort,ctrl-s:clear-selection'
)
Invoke-FuzzyBrowse -FzfFileArgs $fzfArgs

# Preview with command info, requires recent fzf version which adheres to $env:SHELL='pwsh'
# or similar, so it can run preview/execute via PS.
Invoke-FuzzyGetCmdlet -FzfArgs @('--preview', 'Get-Command {} -ShowCommandInfo')

# Fuzzy history with option to delete selected entries.
Invoke-FuzzyGetCmdlet -FzfArgs @(
  '--multi', # Not useful when selecting history, but very useful for deleting multiple entries.
  '--bind',
  'ctrl-d:execute($i=@(Get-Content {+f}); $h=(Get-PSReadLineOption).HistorySavePath; (Get-Content $h) | ?{$_ -notin $i} | Out-File $h -Encoding utf8NoBom)'
)
```

## Sample key bindings and aliases

Key bindings like the ones fzf installs by default in other shells like bash, put in `$PROFILE`:

```powershell
Set-PSReadLineKeyHandler -Key 'ctrl-r' -BriefDescription 'Fuzzy history' -ScriptBlock {Invoke-FuzzyHistory}
Set-PSReadLineKeyHandler -Key 'ctrl-t' -BriefDescription 'Fuzzy browse' -ScriptBlock {Invoke-FuzzyBrowse}
Set-PSReadLineKeyHandler -Key 'alt-c' -BriefDescription 'Fuzzy browse dirs' -ScriptBlock {Invoke-FuzzyBrowse -Directory}
```

Aliases like this can also be useful:
```powershell
Set-Alias fz Invoke-FuzzZLocation
Set-Alias fkill Invoke-FuzzyKillProcess
```

An alternative approach to aliasing is using `Invoke-FuzzyGetCmdlet` bound to a keyboard shortcut then use
that for fuzzy command finding instead of typing aliases: it is usually about the same number of keystrokes to
reach a command but doesn't require remembering the exact name and is generic. For example starting
`Invoke-FuzzyGetCmdlet` and typing `fz` or `fk` (or the other way around, i.e. typing `fz` or `fk` and then
using the keyboard shortcut) fuzzy matches the functions shown above.

## Rationale and helper functions

For a lot of things fzf works fine as-is in Powershell. For example one can use

```powershell
$selectedLines = Get-Content foo.txt | fzf --multi --no-sort
```

without needing any extra functions (so even no PsFzfLite :]), let alone wrapping. Especially when knowing
fzf already and/or using it in other shells it's convenient to be able to just use the same in Powershell
(as opposed to having to figure out the corresponding arguments for PSFzf for instance).

Moreover there are a lot of different usecases for fzf and it has a lot of options, so the wrapping/do-it-all
approach is on one hand never enough in that people can continue to ask new features to satisfy their own
customizations while on the other hand it's always overkill in that the majority of the code is not used by
other people because they do things in a different way. So an approach where one uses fzf directly to write
a couple of often-used functions has its merits in that it is fast and does exactly what's needed
but nothing more.

Using fzf like that in Powershell however does run into few issues, and solutions for these are
what PsFzfLite is about:
- when binding functions using fzf to a keyboard shortcut, the selected result usually needs to be
  inserted at the current cursor position. That's fairly easy using PsReadLine and PsFzfLite has
  the basics to do that in a pipe: `fzf | Add-TextAtCursor`.
- likewise the output of fzf might need to be quoted or wrapped in an array, for example if fzf returns 2
  lines 'foo' and 'bar' that should become `@('foo', 'bar')`: `fzf | ConvertTo-ReplInput | Add-TextAtCursor`.
- fuzzy file finding using `Get-ChildItem | fzf` or `cmd /c dir | fzf` is so slow it's hardly usable for
  more than a couple of directories deep. PsFzfLite implements its own filesystem walking in C# which performs
  similar to what fzf uses internally (see [FileSystemWalker.cs](PsFzfLite/FileSystemWalker.cs).
  There is still some overhead for using it in Powershell and piping into fzf and as such it's not as fast as
  using bare fzf, but still like 10 times faster than PSFzf and also more consistent with standard fzf: it uses
  no full paths but paths relative to the directory and filters out dot directories.
  Ballpark performance numbers as seen from within PS Measure-Command {...} for a directory
  with roughly 0.7 million files, no filtering, after some warmup, numbers in seconds:

  - Get-ChildPathNames (Windows version): 3.9
  - Get-ChildPathNames (portable version): 4.8
  - fd -H -I: 8.1
  - go executable using most basic sample from github.com/saracen/walker (which is what fzf uses internally): 8.6
  - cmd /c dir /b /s /a-d: 31.5
  - Get-ChildItem -Path -File -Recurse: 36.5

  Same principle but on PS Core in WSL on a directory with about 200000 files:
  - fd -H -I: 10
  - Get-ChildPathNames (portable version): 15
  - find -type f: 50
  - Get-ChildItem -Path -File -Recurse: 95
- at the time of writing there is no builtin way to stop a pipeline, nor do upstream elements detect when a
  downstream element stopped, so piping a lot of input into fzf is problematic since the pipe will continue even
  after making a selection in fzf rendering it useless. None of the workarounds are super pretty.
  PsFzfLite has 2 of them:
  - Windows-only: `TonsOfInput | cmd /c (New-PipeOrTerminateArgs 'fzf') | Read-PipeOrTerminate`
  - portable: `TonsOfInput | New-InterruptibleCommand fzf`

  Currently these are used only in `Invoke-FuzzyBrowse`, none of the other examples produce enough input that
  waiting for the input to enter fzf takes much longer than deciding + typing the fuzzy string.
