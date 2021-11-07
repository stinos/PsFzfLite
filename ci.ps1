Write-Host ($PSVersionTable | Out-String)
Import-Module Pester
$config = [PesterConfiguration]::Default
$config.Run.PassThru = $True
$config.TestResult.Enabled = $True
$res = Invoke-Pester -Configuration $config
if ($env:APPVEYOR_JOB_ID) {
  [System.Net.WebClient]::new().UploadFile("https://ci.appveyor.com/api/testresults/nunit/$($env:APPVEYOR_JOB_ID)",
    (Resolve-Path $config.TestResult.OutputPath.Value))
}
if ($res.FailedCount -gt 0) {
  throw "$($res.FailedCount) tests failed"
}
