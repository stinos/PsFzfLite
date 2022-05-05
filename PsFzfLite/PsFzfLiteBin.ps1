<#
.SYNOPSIS
Build source code into a dll in the temp directory.
.DESCRIPTION
Just Add-Type, but reading the input from a file so the code can be stored normally
(and also tested in VS ect) instead of in one long string. Passes 'WIN' as preprocessor
constant when building on Windows, and 'NET40' for a PS version less than 6.
Does nothing if target file exists and source file is not newer.
Otherwise deletes the file (so no other session should be using it) and compiles it again.
If this errors with 'The file ... already exists' it means the assembly is in use,
and as such could not be compiled again.
.PARAMETER CodeFile
File with source code.
.PARAMETER AssemblyFileName
Output dll name.
.PARAMETER Force
Force build even if source not newer.
.PARAMETER OutputPath
Output directory, defaults to temp directory.
.OUTPUTS
Full path to the assmbly file.
#>
function New-AssemblyFromSourceFile {
  param(
    [Parameter(Mandatory)] [String] $CodeFile,
    [Parameter(Mandatory)] [String] $AssemblyFileName,
    [Parameter()] [Switch] $Force,
    [Parameter()] [String] $OutputPath = [System.IO.Path]::GetTempPath()
  )
  if ($OutputPath) {
    $assemblyFile = Join-Path $OutputPath $AssemblyFileName
  }
  else {
    $assemblyFile = $AssemblyFileName
  }
  if ($Force -or (-not (Test-Path $assemblyFile)) -or
      ((Get-ChildItem $CodeFile).LastWriteTime -gt (Get-ChildItem $assemblyFile).LastWriteTime)) {
    Write-Verbose "Building $assemblyFile"
    Remove-Item -Force $assemblyFile -ErrorAction SilentlyContinue | Out-Null
    $compilerOptions = @('-optimize', '-debug-', '-checked')
    $isPs5 = $PSVersionTable.PSVersion.Major -lt 6
    if ($isPs5 -or $IsWindows) {
      $compilerOptions += '/define:WIN'
    }
    $addTypeArgs = @{
      TypeDefinition = (Get-Content -Raw $CodeFile)
      Language = 'CSharp'
    }
    if ($isPs5) {
      $compilerOptions += '/define:NET40'
      # PS5 has no CompilerOptions so must use parameters.
      $compilerParameters = [System.CodeDom.Compiler.CodeDomProvider]::GetCompilerInfo('CSharp').CreateDefaultCompilerParameters()
      $compilerParameters.CompilerOptions = $compilerOptions
      $compilerParameters.OutputAssembly = $assemblyFile
      # When specifying parameters we have to references manually; just 'System.Management.Automation.dll'
      # doesn't get found though so get the correct location by querying what this session is using.
      $compilerParameters.ReferencedAssemblies.Add([PSObject].Assembly.Location) | Out-Null
      $compilerParameters.ReferencedAssemblies.Add('System.dll') | Out-Null
      $compilerParameters.ReferencedAssemblies.Add('System.Core.dll') | Out-Null
      $addTypeArgs['CompilerParameters'] = $compilerParameters
    }
    else {
      $addTypeArgs['CompilerOptions'] = $compilerOptions
      $addTypeArgs['OutputAssembly'] = $assemblyFile
    }
    Add-Type @addTypeArgs
  }
  $assemblyFile
}

function New-AssemblyFromFileInThisDir {
  param($SourceFileName)
  $sourcePath = (Join-Path $PSScriptRoot "$SourceFileName.cs")
  # Give them different names so switching between versions is easier to test.
  if ($PSVersionTable.PSVersion.Major -lt 6) {
    $outputFile = "PsFzfLite$($SourceFileName)ps5.dll"
  }
  else {
    $outputFile = "PsFzfLite$SourceFileName.dll"
  }
  New-AssemblyFromSourceFile -CodeFile $sourcePath -AssemblyFileName $outputFile -Verbose
}

<#
.SYNOPSIS
Build the FileSystemWalker dll if needed, and import it.
#>
function Install-FileSystemWalker {
  Import-Module (New-AssemblyFromFileInThisDir 'FileSystemWalker' -Verbose)
}

<#
.SYNOPSIS
Build the PipeLineHelper dll if needed, and load it.
#>
function Install-PipelineHelper {
  [System.Reflection.Assembly]::LoadFile((New-AssemblyFromFileInThisDir 'PipelineHelper' -Verbose)) | Out-Null
}

<#
.SYNOPSIS
Sentinel used by Read-PipeOrTerminate.
#>
Set-Variable 'pipeTerminatingString' -Option Constant -Value '-PipeTerminatingString-'

<#
.SYNOPSIS
Pass-through pipeline element which terminates pipeline when encountering $pipeTerminatingString.
.DESCRIPTION
At the time of writing there is no builtin way to stop a pipeline, nor do pipes detect when
the downstream command stopped and instead just keep on running upstream commands. Yet that
is exactly what we want to do when piping into fzf and accepting a result. There are other
more complicated ways to do this (see PsFzf for instance), but this is shorter and easier to
read and follow.
Principle:

UpstreamCommnd | cmd /c (New-PipeOrTerminateArgs 'fzf') | Read-PipeOrTerminate

Once the command passed to cmd (fzf in this case) returns it will echo $pipeTerminatingString,
which gets detected here and results in the pipeline being terminated.

Without this, so using just GenerateInputForFzf | fzf, after making a selection in fzf or quitting
it the pipe won't return until GenerateInputForFzf completes which is simply unusable
for commands generating a lot of items like recursively listing files.

See https://github.com/PowerShell/PowerShell/issues/15329 and linked issues for bug reports regarding
pipes not detecting external command exit.
See PipelineHelper.cs for the implementation for stopping the pipe.
See New-InterruptibleCommand below for an alternative implementation achieving the same.
.NOTES
Requires Install-PipelineHelper.
.PARAMETER Value
Value to pass through.
.OUTPUTS
Value, or empty if pipe terminated.
.EXAMPLE
# Result will be empty if cancelled.
$result = Get-ChildItem c:\ -Recurse | cmd /c (New-PipeOrTerminateArgs fzf) | Read-PipeOrTerminate
#>
function Read-PipeOrTerminate {
  [CmdletBinding()]  # Needed to get a $PSCmdlet.
  Param(
    [Parameter(ValueFromPipeline)] $Value
  )
  process {
    if ($Value -eq $pipeTerminatingString) {
      [PsFzfLite.PipelineHelper]::StopUpstreamCommands($PsCmdlet)
    }
    else {
      $Value
    }
  }
}

<#
.SYNOPSIS
Helper generating the arguments for the downstream Read-PipeOrTerminate command.
.DESCRIPTION
See Read-PipeOrTerminate.
.PARAMETER Command
The command to execute.
.OUTPUTS
Wrapped command as a string, for invocation by cmd /c or similar.
#>
function New-PipeOrTerminateArgs {
  Param(
    [Parameter(Mandatory)] [String] $Command
  )
  # Returns command output line(s) if any, then pipeTerminatingString on a line,
  # or just pipeTerminatingString when command exits with an error.
  "($Command&& echo $pipeTerminatingString) || echo $pipeTerminatingString"
}

<#
.SYNOPSIS
Start an external command and terminate upstream pipe when the command exits.
.DESCRIPTION
See Read-PipeOrTerminate for why this is needed; this approach is a cross-platform PS-native approach,
but somehwat slower. Works using a steppable pipeline, checking whether the command exited for each
element fed into the pipe. For this it relies on finding the process by name which could fail for
short-lived programs in which case the pipe exits immediately. But this is really meant to run fzf,
so should not be an issue.
Not supported for PS5.
Idea from https://stackoverflow.com/a/69951585/128384.
.NOTES
Requires Install-PipelineHelper.
.PARAMETER ExeAndArgs
The command to execute and optionally its arguments.
.PARAMETER InputObject
Pipeline input to send to the command process.
.OUTPUTS
Command output.
.EXAMPLE
$result = Get-ChildItem c:\ -Recurse | New-InterruptibleCommand fzf
#>
function New-InterruptibleCommand {
  [CmdletBinding(PositionalBinding = $False)]
  param(
    [Parameter(Mandatory, ValueFromRemainingArguments)] [string[]] $ExeAndArgs,
    [Parameter(ValueFromPipeline)] $InputObject
  )

  begin {
    $exe, $exeArgs = $ExeAndArgs
    $exeName = [IO.Path]::GetFileNameWithoutExtension($exe)
    try {
      $pipeline = ({& $exe $exeArgs}).GetSteppablePipeline($MyInvocation.CommandOrigin)
      $pipeline.Begin($PSCmdlet) # Culprit for PS5: doesn't do anything, only End() effectively launches.
    }
    catch {
      throw
    }
    # Get a reference to the newly launched process. Theoretically not 100% failsafe (could be multiple
    # child processes, could take . 100mSec before the command is alive) but hasn't failed so far.
    for ($i = 0; $i -lt 10; $i++) {
      Start-Sleep -Milliseconds 10
      $commandProcess = Get-Process -ErrorAction Ignore $exeName |
        Where-Object {($null -ne $_.Parent) -and ($_.Parent.Id -eq $PID)} |
        Select-Object -First 1
      if ($commandProcess) {
        break
      }
    }
    # Process block signalling object and logic.
    $exitedEvent = $null
    $processExitSignal = New-Object psobject -Property @{flag = $true}
    if (-not $commandProcess) {
      Write-Warning "Process '$exeName' unexpectedly did not appear or exited already."
    }
    else {
      # Use an event to detect when the process exits: polling HasExited or similar in the
      # process block is much simpler, but has a noticeable performance impact.
      $exitedEventId = 'PsFzfLite' + [System.Guid]::NewGuid()
      $exitedEvent = Register-ObjectEvent -InputObject $commandProcess -EventName 'Exited' `
        -SourceIdentifier $exitedEventId -MessageData $processExitSignal -ErrorAction SilentlyContinue `
        -Action {$Event.MessageData.flag = $true}
      # It's possible the process exited between the loop and the event registration attempt,
      # so continue processing only when we managed to get the process.
      if ($?) {
        $processExitSignal.flag = $false
      }
    }
    function CleanupEvent {
      if ($exitedEvent) {
        Unregister-Event $exitedEventId
        Stop-Job $exitedEvent
        Remove-Job $exitedEvent
      }
    }
  }

  process {
    if ($processExitSignal.flag) {
      # StopUpstreamCommands effectively terminates pipe so End block won't be entered: cleanup now.
      CleanupEvent
      $pipeline.End()
      [PsFzfLite.PipelineHelper]::StopUpstreamCommands($PsCmdlet)
    }
    $pipeline.Process($_)
  }

  end {
    CleanupEvent
    $pipeline.End()
  }
}
