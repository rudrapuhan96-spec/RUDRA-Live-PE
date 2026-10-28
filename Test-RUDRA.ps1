[CmdletBinding()]
param([string]$ProjectRoot = $PSScriptRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$failures = New-Object 'System.Collections.Generic.List[string]'
$passed = New-Object 'System.Collections.Generic.List[string]'

function Assert-File {
    param([string]$RelativePath)
    $path = Join-Path $ProjectRoot $RelativePath
    if (Test-Path -LiteralPath $path -PathType Leaf) { $passed.Add("File exists: $RelativePath") }
    else { $failures.Add("Required file is missing: $RelativePath") }
}

foreach ($path in @(
    'README.md',
    'TESTING.md',
    'Build-RUDRA.ps1',
    'Validate-RUDRA.ps1',
    'Start-RUDRA.ps1',
    'RUDRA-Tools.psm1',
    'RUDRA-Live-PE-Build\media\sources\boot.wim',
    'RUDRA-Live-PE-Build\bootbins\etfsboot.com',
    'RUDRA-Live-PE-Build\bootbins\efisys.bin',
    'RUDRA-Live-PE-Build\bootbins\bootmgfw.efi'
)) { Assert-File -RelativePath $path }

$scriptFiles = @(Get-ChildItem -LiteralPath $ProjectRoot -File | Where-Object { $_.Extension -in @('.ps1','.psm1') })
foreach ($file in $scriptFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count -eq 0) { $passed.Add("PowerShell syntax: $($file.Name)") }
    else {
        foreach ($parseError in $parseErrors) {
            $failures.Add(("PowerShell syntax error in {0} at line {1}: {2}" -f $file.Name,$parseError.Extent.StartLineNumber,$parseError.Message))
        }
    }
}

Import-Module (Join-Path $ProjectRoot 'RUDRA-Tools.psm1') -Force
try {
    $validIp = Test-RudraPingTarget -Target '192.0.2.1'
    $validHost = Test-RudraPingTarget -Target 'example.com'
    if ($validIp -eq '192.0.2.1' -and $validHost -eq 'example.com') { $passed.Add('Ping target validation accepts a test IP and DNS host.') }
    else { $failures.Add('Ping target validation did not preserve valid test inputs.') }
} catch { $failures.Add(('Ping target validation rejected a valid test input: {0}' -f $_.Exception.Message)) }
$rejectedUnsafeTarget = $false
try { [void](Test-RudraPingTarget -Target 'example.com; Start-Process') } catch { $rejectedUnsafeTarget = $true }
if ($rejectedUnsafeTarget) { $passed.Add('Ping target validation rejects command-like input without executing it.') }
else { $failures.Add('Ping target validation accepted command-like input.') }
$diagnosticHeaders = @(
    @{ Name='system'; Header='RUDRA-Live-PE | System information' },
    @{ Name='network'; Header='RUDRA-Live-PE | Network diagnostics' },
    @{ Name='disk'; Header='RUDRA-Live-PE | Read-only disk inspection' },
    @{ Name='recovery'; Header='RUDRA-Live-PE | Windows recovery diagnostics' },
    @{ Name='password'; Header='RUDRA-Live-PE | Password & account recovery' },
    @{ Name='lazesoft'; Header='RUDRA-Live-PE | Lazesoft recovery media' },
    @{ Name='data'; Header='RUDRA-Live-PE | Disk & data recovery triage' },
    @{ Name='technician'; Header='RUDRA-Live-PE | Technician toolkit' }
)
foreach ($diagnostic in $diagnosticHeaders) {
    try {
        switch ($diagnostic.Name) {
            'system' { $report = Get-RudraSystemReport }
            'network' { $report = Get-RudraNetworkReport }
            'disk' { $report = Get-RudraDiskReport }
            'recovery' { $report = Get-RudraRecoveryReport }
            'password' { $report = Get-RudraPasswordRecoveryGuide }
            'lazesoft' { $report = Get-RudraLazesoftGuide }
            'data' { $report = Get-RudraDataRecoveryGuide }
            'technician' { $report = Get-RudraTechnicianGuide }
        }
        $heading = ([string]$report -split '\r?\n',2)[0]
        if ($heading -eq $diagnostic.Header) { $passed.Add("Read-only smoke check returns a report: $($diagnostic.Name)") }
        else { $failures.Add("Read-only smoke check returned an unexpected heading: $($diagnostic.Name)") }
    } catch { $failures.Add(("Read-only smoke check failed for {0}: {1}" -f $diagnostic.Name,$_.Exception.Message)) }
}
$launcherText = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Start-RUDRA.ps1') -Raw
if ($launcherText -match "Key='lazesoft'" -and $launcherText -match "Key='password'" -and $launcherText -match "Key='data'" -and $launcherText -match "Key='technician'") { $passed.Add('Launcher includes Lazesoft, password, data-recovery, and technician workflows.') } else { $failures.Add('Launcher is missing one or more planned recovery workflows.') }
if ($launcherText -match 'System\.Windows\.Forms\.Form' -and $launcherText -match 'System\.Drawing\.Size' -and $launcherText -notmatch '(?<!System\.)Windows\.Forms\.') { $passed.Add('Launcher uses fully qualified WinForms and Drawing types.') }
else { $failures.Add('Launcher has unresolved or shortened WinForms/Drawing type names.') }
$buildText = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Build-RUDRA.ps1') -Raw
$validatorText = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Validate-RUDRA.ps1') -Raw
if ($validatorText -match 'Require \(\(\$null -ne \$dism\) -and \(Test-Path -LiteralPath \$dism -PathType Leaf\)\)' -and $validatorText -notmatch 'Require \(\$dism\)') {
    $dismCandidate = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $presentCondition = ($null -ne $dismCandidate) -and (Test-Path -LiteralPath $dismCandidate -PathType Leaf)
    $missingCondition = ($null -ne $null) -and (Test-Path -LiteralPath $null -PathType Leaf)
    if (($presentCondition -is [bool]) -and $presentCondition -and ($missingCondition -is [bool]) -and (-not $missingCondition)) {
        $passed.Add('ADK DISM Require condition is Boolean for present and missing paths (string-to-Boolean regression).')
    } else { $failures.Add('ADK DISM availability expression did not return strict Boolean values.') }
} else { $failures.Add('Validator still passes the ADK DISM path string directly to Require.') }
if ($buildText -match '\[switch\]\$ValidateOnly' -and $buildText -match '\[string\]\$IsoPath' -and $buildText -match '\$validationExit = \$LASTEXITCODE' -and $buildText -match 'Require \(\$validationExit -eq 0\)') {
    $validationBlockStart = $buildText.IndexOf("if (`$ValidateOnly) {`r`n        `$resolvedIso",[StringComparison]::Ordinal)
    if ($validationBlockStart -lt 0) { $validationBlockStart = $buildText.IndexOf("if (`$ValidateOnly) {`n        `$resolvedIso",[StringComparison]::Ordinal) }
    $validationBlockEnd = if ($validationBlockStart -ge 0) { $buildText.IndexOf("        return",$validationBlockStart,[StringComparison]::Ordinal) } else { -1 }
    if ($validationBlockStart -ge 0 -and $validationBlockEnd -gt $validationBlockStart) {
        $validationOnlyBlock = $buildText.Substring($validationBlockStart,$validationBlockEnd - $validationBlockStart)
        if ($validationOnlyBlock -notmatch '(?i)/Mount-Image|/Add-Package|robocopy\.exe|Remove-Item' -and
            $validationOnlyBlock -match 'Test-Path -LiteralPath \$finalIso' -and
            $validationOnlyBlock -match 'Test-Path -LiteralPath \$manifestPath' -and
            $validationOnlyBlock -match 'Move-Item -LiteralPath \$resolvedIso -Destination \$finalIso\r?\n') {
            $passed.Add('Validation-only path reuses the existing ISO, skips WIM servicing, captures exit status, and guards output conflicts.')
        } else { $failures.Add('Validation-only path is missing safe no-servicing or no-overwrite guards.') }
    } else { $failures.Add('Could not isolate the validation-only branch for regression checks.') }
} else { $failures.Add('Build script is missing validation-only parameters or explicit child validation exit-code handling.') }
if ($buildText -match '\[guid\]::NewGuid\(\)\.ToString\(''N''\).*\.log' -and
    $validatorText -match '\[guid\]::NewGuid\(\)\.ToString\(''N''\).*\.log' -and
    $buildText -match 'Start-Transcript -LiteralPath \$logPath \| Out-Null' -and
    $validatorText -match 'Start-Transcript -LiteralPath \$transcript \| Out-Null' -and
    $buildText -notmatch 'Start-Transcript -LiteralPath \$logPath -Force' -and
    $validatorText -notmatch 'Start-Transcript -LiteralPath \$transcript -Force') {
    $passed.Add('Build and validation transcripts use unique paths without force-overwriting existing logs.')
} else { $failures.Add('Build or validation transcript creation could overwrite an existing log.') }
$formSmoke = $null
$fontSmoke = $null
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $formSmoke = New-Object System.Windows.Forms.Form
    $formSmoke.Size = New-Object System.Drawing.Size(1040,700)
    $formSmoke.MinimumSize = New-Object System.Drawing.Size(850,680)
    $fontSmoke = New-Object System.Drawing.Font('Segoe UI',9)
    $formSmoke.Font = $fontSmoke
    [void](New-Object System.Windows.Forms.ListBox)
    $passed.Add('WinForms form, sizing, font, and control constructors work without opening a window.')
} catch { $failures.Add(("WinForms construction smoke check failed: {0}" -f $_.Exception.Message)) }
finally {
    if ($formSmoke) { $formSmoke.Dispose() }
    if ($fontSmoke) { $fontSmoke.Dispose() }
}

if ($buildText -match 'ExecutionPolicy RemoteSigned' -and $buildText -notmatch 'ExecutionPolicy Bypass') { $passed.Add('WinPE startup uses a process-scoped RemoteSigned policy and does not request Bypass.') }
else { $failures.Add('WinPE startup execution-policy setting is missing or requests Bypass.') }
if ($buildText -match 'protectedOriginal' -and $buildText -match 'Test-PathWithin') { $passed.Add('Build script protects the original staging path and confines its workspace to the project.') }
else { $failures.Add('Build script is missing the project/original path safety guard.') }

foreach ($message in $passed) { Write-Host ("PASS  " + $message) -ForegroundColor Green }
foreach ($message in $failures) { Write-Host ("FAIL  " + $message) -ForegroundColor Red }
Write-Host ("Result: {0} passed; {1} failed." -f $passed.Count,$failures.Count)
if ($failures.Count -gt 0) { exit 1 }
