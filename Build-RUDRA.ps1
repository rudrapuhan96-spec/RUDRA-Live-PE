[CmdletBinding()]
param(
    [string]$Workspace = (Join-Path $PSScriptRoot 'RUDRA-Live-PE-Build'),
    [switch]$ValidateOnly,
    [string]$IsoPath,
    [switch]$ResetWorkingImage,
    [switch]$ForceISO
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$projectRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$protectedOriginal = [IO.Path]::GetFullPath('C:\RUDRA-Live-PE-Build').TrimEnd('\')
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$transcriptStarted = $false

function Require {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
}

function Resolve-ProjectPath {
    param([string]$Path,[string]$Base)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path).TrimEnd('\') }
    return [IO.Path]::GetFullPath((Join-Path $Base $Path)).TrimEnd('\')
}

function Test-PathWithin {
    param([string]$Child,[string]$Parent)
    $childFull = [IO.Path]::GetFullPath($Child).TrimEnd('\')
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return $childFull.StartsWith(($parentFull + '\'), [StringComparison]::OrdinalIgnoreCase)
}

function Find-AdkLayout {
    $roots = New-Object 'System.Collections.Generic.List[string]'
    try {
        $installedRoots = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction Stop
        if ($installedRoots.KitsRoot10) { $roots.Add([string]$installedRoots.KitsRoot10) }
    } catch { }
    $roots.Add('C:\Program Files (x86)\Windows Kits\10\')
    $roots.Add('C:\Program Files\Windows Kits\10\')
    foreach ($kitsRoot in $roots) {
        $adkRoot = Join-Path $kitsRoot 'Assessment and Deployment Kit'
        $deploymentTools = Join-Path $adkRoot 'Deployment Tools'
        $winpeRoot = Join-Path $adkRoot 'Windows Preinstallation Environment'
        $dismRoot = Join-Path $deploymentTools 'amd64\DISM'
        $oscdimgRoot = Join-Path $deploymentTools 'amd64\Oscdimg'
        if (Test-Path -LiteralPath (Join-Path $dismRoot 'dism.exe') -PathType Leaf) {
            return [PSCustomObject]@{
                KitsRoot = $kitsRoot
                DeploymentTools = $deploymentTools
                DISMRoot = $dismRoot
                OSCDImgRoot = $oscdimgRoot
                WinPERoot = $winpeRoot
                DISM = Join-Path $dismRoot 'dism.exe'
                OSCDImg = Join-Path $oscdimgRoot 'oscdimg.exe'
                MakeWinPEMedia = Join-Path $winpeRoot 'MakeWinPEMedia.cmd'
                OptionalComponents = Join-Path $winpeRoot 'amd64\WinPE_OCs'
            }
        }
    }
    return $null
}

try {
    $Workspace = Resolve-ProjectPath -Path $Workspace -Base $projectRoot
    Require (Test-PathWithin -Child $Workspace -Parent $projectRoot) "Workspace must remain inside the project folder: $projectRoot"
    Require ($Workspace -ne $protectedOriginal -and -not (Test-PathWithin -Child $Workspace -Parent $protectedOriginal)) "Refusing to use the protected original workspace: $protectedOriginal"
    Require (Test-Path -LiteralPath $Workspace -PathType Container) "Project-local WinPE workspace not found: $Workspace"
    $workspaceItem = Get-Item -LiteralPath $Workspace -Force
    Require (($workspaceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Refusing to build through a workspace reparse point: $Workspace"
    if ($ValidateOnly) {
        Require (-not $ResetWorkingImage) '-ResetWorkingImage cannot be combined with -ValidateOnly.'
        Require (-not $ForceISO) '-ForceISO cannot be combined with -ValidateOnly. Validation-only never overwrites existing outputs.'
        Require (-not [string]::IsNullOrWhiteSpace($IsoPath)) 'Pass the existing temporary ISO path with -IsoPath when using -ValidateOnly.'
    } else {
        Require ([string]::IsNullOrWhiteSpace($IsoPath)) '-IsoPath is only valid with -ValidateOnly.'
    }

    $logDirectory = Join-Path $Workspace 'logs'
    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    $logPath = Join-Path $logDirectory ('build-' + $timestamp + '-' + [guid]::NewGuid().ToString('N') + '.log')
    Start-Transcript -LiteralPath $logPath | Out-Null
    $transcriptStarted = $true

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    Require ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Administrator privileges are required for read-only ISO/WIM validation or to service the project-local WIM and create an ISO. Reopen Deployment and Imaging Tools Environment with Run as administrator, then launch this script from the project folder.'
    Require ([Environment]::Is64BitProcess) 'Use 64-bit PowerShell from an amd64 ADK environment.'

    $adk = Find-AdkLayout
    Require ($null -ne $adk) 'Windows ADK Deployment Tools or the Windows PE add-on could not be located. Install matching components, then rerun this build.'
    Require (Test-Path -LiteralPath $adk.DISM -PathType Leaf) 'ADK DISM was not found.'
    if (-not $ValidateOnly) {
        foreach ($requiredTool in @($adk.OSCDImg,$adk.MakeWinPEMedia,(Join-Path $adk.WinPERoot 'copype.cmd'))) {
            Require (Test-Path -LiteralPath $requiredTool -PathType Leaf) "Required ADK build tool is missing: $requiredTool"
        }
    }
    $ocRoot = $adk.OptionalComponents
    if (-not $ValidateOnly) {
        foreach ($component in @('WinPE-WMI','WinPE-Scripting','WinPE-NetFx','WinPE-PowerShell','WinPE-StorageWMI')) {
            $neutral = Join-Path $ocRoot ($component + '.cab')
            $language = Join-Path $ocRoot ('en-us\' + $component + '_en-us.cab')
            Require (Test-Path -LiteralPath $neutral -PathType Leaf) "Required optional component is missing: $neutral"
            Require (Test-Path -LiteralPath $language -PathType Leaf) "Required language resource is missing: $language"
        }
    }

    $env:DISMRoot = $adk.DISMRoot
    $env:OSCDImgRoot = $adk.OSCDImgRoot
    $env:WinPERoot = $adk.WinPERoot
    $env:Path = ($adk.DISMRoot + ';' + $adk.OSCDImgRoot + ';' + $env:Path)

    foreach ($requiredProjectFile in @('Start-RUDRA.ps1','RUDRA-Tools.psm1','Validate-RUDRA.ps1')) {
        Require (Test-Path -LiteralPath (Join-Path $projectRoot $requiredProjectFile) -PathType Leaf) "Required project file is missing: $requiredProjectFile"
    }

    $baseMedia = Join-Path $Workspace 'media'
    $baseWim = Join-Path $baseMedia 'sources\boot.wim'
    $workRoot = Join-Path $Workspace 'work\RUDRA-Live-PE'
    $workingWim = Join-Path $workRoot 'media\sources\boot.wim'
    $finalIso = Join-Path $projectRoot 'outputs\RUDRA-Live-PE.iso'
    $manifestPath = Join-Path $projectRoot 'outputs\RUDRA-Live-PE-build.json'
    $outputs = Join-Path $projectRoot 'outputs'
    $baseBootBins = Join-Path $Workspace 'bootbins'
    Require (Test-PathWithin -Child $outputs -Parent $projectRoot) 'Final output path safety check failed.'
    if (Test-Path -LiteralPath $outputs) {
        $outputDirectoryItem = Get-Item -LiteralPath $outputs -Force
        Require (($outputDirectoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Refusing to publish through an output-directory reparse point: $outputs"
    }
    Require (Test-Path -LiteralPath $baseWim -PathType Leaf) "Project-local base image is missing: $baseWim"

    if ($ValidateOnly) {
        $resolvedIso = Resolve-ProjectPath -Path $IsoPath -Base $projectRoot
        Require (Test-PathWithin -Child $resolvedIso -Parent $Workspace) 'Validation ISO must be inside the selected project-local workspace.'
        Require (Test-Path -LiteralPath $resolvedIso -PathType Leaf) "Temporary ISO not found: $resolvedIso"
        $isoItem = Get-Item -LiteralPath $resolvedIso -Force
        Require (($isoItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Refusing to validate or move an ISO reparse point: $resolvedIso"
        Require (Test-PathWithin -Child $workRoot -Parent $Workspace) 'Internal working path safety check failed.'
        Require (Test-Path -LiteralPath $workRoot -PathType Container) "Project-local working tree not found: $workRoot"
        $workRootItem = Get-Item -LiteralPath $workRoot -Force
        Require (($workRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Refusing to validate through a working-tree reparse point: $workRoot"
        Require (Test-Path -LiteralPath $workingWim -PathType Leaf) "Working WIM not found: $workingWim"
        Require (-not (Test-Path -LiteralPath $finalIso)) "Final ISO already exists; validation-only will preserve the temporary ISO: $finalIso"
        Require (-not (Test-Path -LiteralPath $manifestPath)) "Build manifest already exists; validation-only will preserve the temporary ISO: $manifestPath"

        $baseHash = (Get-FileHash -LiteralPath $baseWim -Algorithm SHA256).Hash
        Write-Host ('Validating existing temporary ISO without servicing the WIM: {0}' -f $resolvedIso)
        Write-Host ('Project-local base WIM SHA-256: {0}' -f $baseHash)
        $validationHost = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
        Require (Test-Path -LiteralPath $validationHost -PathType Leaf) "PowerShell host not found for isolated validation: $validationHost"
        $validatorPath = Join-Path $projectRoot 'Validate-RUDRA.ps1'
        & $validationHost -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File $validatorPath -Workspace $Workspace -WorkingRoot $workRoot -IsoPath $resolvedIso -ExpectedBaseSha256 $baseHash
        $validationExit = $LASTEXITCODE
        Require ($validationExit -eq 0) "ISO validation failed (exit $validationExit). The temporary ISO was preserved and not published."
        Require ((Get-FileHash -LiteralPath $baseWim -Algorithm SHA256).Hash -eq $baseHash) 'The project-local base WIM changed during ISO validation.'
        Require (-not (Test-Path -LiteralPath $finalIso)) "Final ISO appeared during validation; temporary ISO was preserved: $finalIso"
        Require (-not (Test-Path -LiteralPath $manifestPath)) "Build manifest appeared during validation; temporary ISO was preserved: $manifestPath"

        New-Item -ItemType Directory -Force -Path $outputs | Out-Null
        $outputDirectoryItem = Get-Item -LiteralPath $outputs -Force
        Require (($outputDirectoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Refusing to publish through an output-directory reparse point: $outputs"
        $isoHash = (Get-FileHash -LiteralPath $resolvedIso -Algorithm SHA256).Hash
        $manifest = [ordered]@{
            schemaVersion = 1
            buildUtc = [DateTime]::UtcNow.ToString('o')
            architecture = 'amd64'
            baseImageSha256 = $baseHash
            workingImageSha256 = (Get-FileHash -LiteralPath $workingWim -Algorithm SHA256).Hash
            isoSha256 = $isoHash
            bootTested = $false
            features = @('system information','network diagnostics','read-only disk inspection','Windows recovery file checks','session log collection')
        }
        $manifestTemp = Join-Path $outputs ('RUDRA-Live-PE-build-' + [guid]::NewGuid().ToString('N') + '.tmp')
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestTemp -Encoding UTF8
        Move-Item -LiteralPath $resolvedIso -Destination $finalIso
        Move-Item -LiteralPath $manifestTemp -Destination $manifestPath
        Write-Host "Validated ISO published: $finalIso"
        Write-Host "Build manifest: $manifestPath"
        Write-Host 'Boot testing has not been performed.'
        return
    }

    foreach ($required in @('etfsboot.com','efisys.bin','bootmgfw.efi')) {
        Require (Test-Path -LiteralPath (Join-Path $baseBootBins $required) -PathType Leaf) "Project-local boot file is missing: $(Join-Path $baseBootBins $required)"
    }

    $baseHash = (Get-FileHash -LiteralPath $baseWim -Algorithm SHA256).Hash
    Write-Host "Inspecting project-local base WIM: $baseWim"
    $wimInfo = & $adk.DISM /English /Get-WimInfo "/WimFile:$baseWim" 2>&1
    $wimInfoExit = $LASTEXITCODE
    Require ($wimInfoExit -eq 0) "DISM could not inspect the base WIM (exit $wimInfoExit): $($wimInfo -join [Environment]::NewLine)"
    Require (($wimInfo -join [Environment]::NewLine) -match '(?m)^\s*Index\s*:\s*1\s*$') 'The project-local WIM does not expose the expected image at index 1.'

    Require (Test-PathWithin -Child $workRoot -Parent $Workspace) 'Internal working path safety check failed.'
    New-Item -ItemType Directory -Force -Path $outputs | Out-Null
    if ((Test-Path -LiteralPath $finalIso) -and -not $ForceISO) { throw "ISO already exists. Pass -ForceISO to replace it only after a successful new build: $finalIso" }
    if ((Test-Path -LiteralPath $manifestPath) -and -not $ForceISO) { throw "Build manifest already exists. Pass -ForceISO to replace it only after a successful new build: $manifestPath" }

    if (Test-Path -LiteralPath $workRoot) {
        if (-not $ResetWorkingImage) { throw "Working tree already exists and is protected from replacement: $workRoot. Inspect it, then pass -ResetWorkingImage only if you intend to discard that build tree." }
        $item = Get-Item -LiteralPath $workRoot -Force
        Require (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Refusing to reset a reparse point: $workRoot"
        Require (Test-PathWithin -Child $workRoot -Parent $Workspace) 'Refusing to remove a working tree outside the project-local workspace.'
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }

    $workMedia = Join-Path $workRoot 'media'
    $workBootBins = Join-Path $workRoot 'bootbins'
    New-Item -ItemType Directory -Force -Path $workMedia,$workBootBins | Out-Null
    & robocopy.exe $baseMedia $workMedia /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NP /NJH /NJS
    $copyMediaExit = $LASTEXITCODE
    Require ($copyMediaExit -lt 8) "Could not copy project media into the working tree (Robocopy exit $copyMediaExit)."
    & robocopy.exe $baseBootBins $workBootBins /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NP /NJH /NJS
    $copyBootExit = $LASTEXITCODE
    Require ($copyBootExit -lt 8) "Could not copy boot files into the working tree (Robocopy exit $copyBootExit)."

    $mountDirectory = Join-Path $workRoot 'mount'
    New-Item -ItemType Directory -Force -Path $mountDirectory | Out-Null
    Require ((Get-FileHash -LiteralPath $baseWim -Algorithm SHA256).Hash -eq $baseHash) 'The project-local base WIM changed while staging.'
    Require ((Get-FileHash -LiteralPath $workingWim -Algorithm SHA256).Hash -eq $baseHash) 'The staged WIM does not match the project-local base WIM.'

    $mounted = $false
    try {
        & $adk.DISM /English /Mount-Image "/ImageFile:$workingWim" /Index:1 "/MountDir:$mountDirectory" /CheckIntegrity
        $result = $LASTEXITCODE
        Require ($result -eq 0) "DISM could not mount the working copy (exit $result)."
        $mounted = $true

        foreach ($component in @('WinPE-WMI','WinPE-Scripting','WinPE-NetFx','WinPE-PowerShell','WinPE-StorageWMI')) {
            $neutral = Join-Path $ocRoot ($component + '.cab')
            $language = Join-Path $ocRoot ('en-us\' + $component + '_en-us.cab')
            & $adk.DISM /English "/Image:$mountDirectory" /Add-Package "/PackagePath:$neutral"
            $result = $LASTEXITCODE
            Require ($result -eq 0) "DISM failed to add $component (exit $result)."
            & $adk.DISM /English "/Image:$mountDirectory" /Add-Package "/PackagePath:$language"
            $result = $LASTEXITCODE
            Require ($result -eq 0) "DISM failed to add the en-us resources for $component (exit $result)."
        }

        $launcherDirectory = Join-Path $mountDirectory 'RUDRA'
        New-Item -ItemType Directory -Force -Path $launcherDirectory | Out-Null
        Copy-Item -LiteralPath (Join-Path $projectRoot 'Start-RUDRA.ps1') -Destination (Join-Path $launcherDirectory 'Start-RUDRA.ps1') -Force
        Copy-Item -LiteralPath (Join-Path $projectRoot 'RUDRA-Tools.psm1') -Destination (Join-Path $launcherDirectory 'RUDRA-Tools.psm1') -Force

        $startnet = Join-Path $mountDirectory 'Windows\System32\startnet.cmd'
        @(
            '@echo off',
            'wpeinit',
            'powershell.exe -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File X:\RUDRA\Start-RUDRA.ps1'
        ) | Set-Content -LiteralPath $startnet -Encoding ASCII

        & $adk.DISM /English "/Image:$mountDirectory" /Set-ScratchSpace:256
        $result = $LASTEXITCODE
        Require ($result -eq 0) "DISM could not configure WinPE scratch space (exit $result)."

        & $adk.DISM /English /Unmount-Image "/MountDir:$mountDirectory" /Commit /CheckIntegrity
        $result = $LASTEXITCODE
        if ($result -eq 0) { $mounted = $false }
        Require ($result -eq 0) "DISM could not commit the project-local working WIM (exit $result)."
    } finally {
        if ($mounted) { Write-Warning "The project-local WIM may still be mounted at $mountDirectory. Review the transcript and DISM Get-MountedImageInfo before cleanup." }
    }

    Require ((Get-FileHash -LiteralPath $baseWim -Algorithm SHA256).Hash -eq $baseHash) 'The project-local base WIM changed during servicing.'
    $temporaryIso = Join-Path $Workspace ('work\RUDRA-Live-PE-' + $timestamp + '.iso')
    $mediaCommand = 'call "' + $adk.MakeWinPEMedia + '" /ISO "' + $workRoot + '" "' + $temporaryIso + '"'
    & $env:ComSpec /d /s /c $mediaCommand
    $mediaExit = $LASTEXITCODE
    Require ($mediaExit -eq 0) "MakeWinPEMedia failed (exit $mediaExit)."
    Require (Test-Path -LiteralPath $temporaryIso -PathType Leaf) 'MakeWinPEMedia reported success but no ISO exists.'

    $validationHost = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
    Require (Test-Path -LiteralPath $validationHost -PathType Leaf) "PowerShell host not found for isolated validation: $validationHost"
    $validatorPath = Join-Path $projectRoot 'Validate-RUDRA.ps1'
    & $validationHost -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File $validatorPath -Workspace $Workspace -WorkingRoot $workRoot -IsoPath $temporaryIso -ExpectedBaseSha256 $baseHash
    $validationExit = $LASTEXITCODE
    Require ($validationExit -eq 0) "ISO validation failed (exit $validationExit). The temporary ISO was preserved and not published."
    Require ((Get-FileHash -LiteralPath $baseWim -Algorithm SHA256).Hash -eq $baseHash) 'The project-local base WIM changed during ISO validation.'
    Require (-not (Test-Path -LiteralPath $finalIso) -or $ForceISO) "Final ISO appeared during validation: $finalIso"
    Require (-not (Test-Path -LiteralPath $manifestPath) -or $ForceISO) "Build manifest appeared during validation: $manifestPath"

    Move-Item -LiteralPath $temporaryIso -Destination $finalIso -Force:$ForceISO
    $manifest = [ordered]@{
        schemaVersion = 1
        buildUtc = [DateTime]::UtcNow.ToString('o')
        architecture = 'amd64'
        baseImageSha256 = $baseHash
        workingImageSha256 = (Get-FileHash -LiteralPath $workingWim -Algorithm SHA256).Hash
        isoSha256 = (Get-FileHash -LiteralPath $finalIso -Algorithm SHA256).Hash
        bootTested = $false
        features = @('system information','network diagnostics','read-only disk inspection','Windows recovery file checks','session log collection')
    }
    $manifestTemp = $manifestPath + '.tmp'
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestTemp -Encoding UTF8
    Move-Item -LiteralPath $manifestTemp -Destination $manifestPath -Force:$ForceISO

    Write-Host "ISO created: $finalIso"
    Write-Host "Working WIM: $workingWim"
    Write-Host "Build manifest: $manifestPath"
    Write-Host 'The project-local base WIM SHA-256 is unchanged.'
} catch {
    Write-Error $_
    exit 1
} finally {
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
}
