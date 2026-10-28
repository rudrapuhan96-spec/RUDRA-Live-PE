[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$WorkingRoot,
    [Parameter(Mandatory=$true)][string]$IsoPath,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedBaseSha256
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$projectRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$protectedOriginal = [IO.Path]::GetFullPath('C:\RUDRA-Live-PE-Build').TrimEnd('\')
$transcriptStarted = $false
$diskMounted = $false
$imageMounted = $false
$validationMount = $null
$dism = $null

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

function Find-AdkDism {
    $roots = New-Object 'System.Collections.Generic.List[string]'
    try {
        $installedRoots = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction Stop
        if ($installedRoots.KitsRoot10) { $roots.Add([string]$installedRoots.KitsRoot10) }
    } catch { }
    $roots.Add('C:\Program Files (x86)\Windows Kits\10\')
    $roots.Add('C:\Program Files\Windows Kits\10\')
    foreach ($kitsRoot in $roots) {
        $candidate = Join-Path $kitsRoot 'Assessment and Deployment Kit\Deployment Tools\amd64\DISM\dism.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Test-ElToritoCatalog {
    param([string]$Path)
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $sector = New-Object byte[] 2048
        $catalogLba = $null
        for ($lba = 16; $lba -lt 64; $lba++) {
            [void]$stream.Seek(([long]$lba * 2048),[IO.SeekOrigin]::Begin)
            if ($stream.Read($sector,0,2048) -ne 2048) { break }
            $descriptorId = [Text.Encoding]::ASCII.GetString($sector,1,5)
            $systemId = [Text.Encoding]::ASCII.GetString($sector,7,23)
            if ($sector[0] -eq 0 -and $descriptorId -eq 'CD001' -and $systemId -eq 'EL TORITO SPECIFICATION') {
                $catalogLba = [BitConverter]::ToUInt32($sector,71)
                break
            }
        }
        if ($null -eq $catalogLba) { throw 'El Torito boot record was not found in the ISO.' }
        [void]$stream.Seek(([long]$catalogLba * 2048),[IO.SeekOrigin]::Begin)
        $catalog = New-Object byte[] 2048
        if ($stream.Read($catalog,0,2048) -ne 2048) { throw 'El Torito boot catalog is truncated.' }
        if ($catalog[0] -ne 1 -or $catalog[30] -ne 0x55 -or $catalog[31] -ne 0xAA) { throw 'El Torito validation entry is invalid.' }
        $sum = 0
        for ($i = 0; $i -lt 32; $i += 2) { $sum += [int]$catalog[$i] + (256 * [int]$catalog[$i + 1]) }
        if (($sum -band 0xFFFF) -ne 0) { throw 'El Torito validation checksum is invalid.' }
        if ($catalog[32] -ne 0x88) { throw 'The default El Torito boot entry is not marked bootable.' }
        return ('El Torito boot catalog verified at sector {0}.' -f $catalogLba)
    } finally {
        $stream.Dispose()
    }
}

try {
    $Workspace = Resolve-ProjectPath -Path $Workspace -Base $projectRoot
    $WorkingRoot = Resolve-ProjectPath -Path $WorkingRoot -Base $projectRoot
    $IsoPath = Resolve-ProjectPath -Path $IsoPath -Base $projectRoot
    Require (Test-PathWithin -Child $Workspace -Parent $projectRoot) 'Workspace must be inside the project folder.'
    Require ($Workspace -ne $protectedOriginal -and -not (Test-PathWithin -Child $Workspace -Parent $protectedOriginal)) "Refusing the protected original workspace: $protectedOriginal"
    Require (Test-PathWithin -Child $WorkingRoot -Parent $Workspace) 'Working tree must be inside the selected project-local workspace.'
    Require (Test-PathWithin -Child $IsoPath -Parent $Workspace) 'The temporary ISO must be inside the selected project-local workspace.'
    Require (Test-Path -LiteralPath $Workspace -PathType Container) "Workspace not found: $Workspace"
    Require (Test-Path -LiteralPath $WorkingRoot -PathType Container) "Working tree not found: $WorkingRoot"
    Require (Test-Path -LiteralPath $IsoPath -PathType Leaf) "ISO not found: $IsoPath"

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    Require ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Administrator privileges are required for read-only ISO/WIM mounting. Run validation from an elevated Deployment and Imaging Tools Environment.'

    $logs = Join-Path $Workspace 'logs'
    New-Item -ItemType Directory -Force -Path $logs | Out-Null
    $transcript = Join-Path $logs ('validate-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.log')
    Start-Transcript -LiteralPath $transcript | Out-Null
    $transcriptStarted = $true

    $dism = Find-AdkDism
    Require (($null -ne $dism) -and (Test-Path -LiteralPath $dism -PathType Leaf)) 'ADK DISM was not found. Install Windows ADK Deployment Tools.'
    $baseWim = Join-Path $Workspace 'media\sources\boot.wim'
    $workingWim = Join-Path $WorkingRoot 'media\sources\boot.wim'
    Require (Test-Path -LiteralPath $baseWim -PathType Leaf) "Project-local base WIM not found: $baseWim"
    Require (Test-Path -LiteralPath $workingWim -PathType Leaf) "Working WIM not found: $workingWim"
    $baseHash = (Get-FileHash -LiteralPath $baseWim -Algorithm SHA256).Hash
    Require ($baseHash -eq $ExpectedBaseSha256) 'The project-local base WIM does not match the hash recorded before the build.'
    Write-Host ('Project-local base WIM SHA-256 unchanged: {0}' -f $baseHash)
    Write-Host (Test-ElToritoCatalog -Path $IsoPath)

    $image = Mount-DiskImage -ImagePath $IsoPath -StorageType ISO -Access ReadOnly -PassThru -ErrorAction Stop
    $diskMounted = $true
    $volumes = @($image | Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter })
    Require ($volumes.Count -gt 0) 'Mounted ISO has no accessible drive letter.'
    $mediaRoot = '{0}:\' -f $volumes[0].DriveLetter
    foreach ($required in @('bootmgr','Boot\BCD','Boot\boot.sdi','sources\boot.wim','EFI\Boot\bootx64.efi','EFI\Microsoft\Boot\BCD')) {
        Require (Test-Path -LiteralPath (Join-Path $mediaRoot $required) -PathType Leaf) "ISO is missing required boot media: $required"
    }
    $isoWim = Join-Path $mediaRoot 'sources\boot.wim'
    $isoWimHash = (Get-FileHash -LiteralPath $isoWim -Algorithm SHA256).Hash
    $workWimHash = (Get-FileHash -LiteralPath $workingWim -Algorithm SHA256).Hash
    Require ($isoWimHash -eq $workWimHash) 'The ISO boot.wim does not match the serviced project-local working WIM.'

    $wimInfo = & $dism /English /Get-WimInfo "/WimFile:$isoWim" 2>&1
    $wimExit = $LASTEXITCODE
    Require ($wimExit -eq 0) "ADK DISM could not inspect the ISO WIM (exit $wimExit): $($wimInfo -join [Environment]::NewLine)"
    Require (($wimInfo -join [Environment]::NewLine) -match '(?m)^\s*Index\s*:\s*1\s*$') 'ISO WIM does not expose image index 1.'

    $validationMount = Join-Path $Workspace ('work\validate-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $validationMount -ErrorAction Stop | Out-Null
    & $dism /English /Mount-Image "/ImageFile:$isoWim" /Index:1 "/MountDir:$validationMount" /ReadOnly /CheckIntegrity
    $mountExit = $LASTEXITCODE
    Require ($mountExit -eq 0) "DISM could not mount the ISO WIM read-only (exit $mountExit)."
    $imageMounted = $true

    foreach ($required in @('RUDRA\Start-RUDRA.ps1','RUDRA\RUDRA-Tools.psm1','Windows\System32\startnet.cmd')) {
        Require (Test-Path -LiteralPath (Join-Path $validationMount $required) -PathType Leaf) "WIM is missing a launcher file: $required"
    }
    $startnet = Get-Content -LiteralPath (Join-Path $validationMount 'Windows\System32\startnet.cmd') -Raw
    Require ($startnet -match '(?im)^\s*wpeinit\s*$') 'Startup command does not initialize WinPE networking and devices with wpeinit.'
    Require ($startnet -match '(?im)^\s*powershell\.exe .*X:\\RUDRA\\Start-RUDRA\.ps1\s*$') 'Startup command does not launch RUDRA-Live-PE.'

    & $dism /English /Unmount-Image "/MountDir:$validationMount" /Discard
    $unmountExit = $LASTEXITCODE
        if ($unmountExit -eq 0) {
            $imageMounted = $false
            [IO.Directory]::Delete($validationMount,$false)
            $validationMount = $null
        }
    Require ($unmountExit -eq 0) "DISM could not release the read-only validation mount (exit $unmountExit)."

    Write-Host 'ISO filesystem, BIOS boot catalog, UEFI boot files, WIM contents, and startup launcher checks passed.'
    Write-Host 'This validates ISO structure and contents. It does not replace a VM or hardware boot test.'
} catch {
    Write-Error $_
    exit 1
} finally {
    if ($imageMounted -and $validationMount) {
        & $dism /English /Unmount-Image "/MountDir:$validationMount" /Discard 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            try { [IO.Directory]::Delete($validationMount,$false) } catch { }
        } else {
            Write-Warning "Read-only WIM validation mount may remain at $validationMount. Inspect DISM Get-MountedImageInfo before cleanup."
        }
    }
    if ($diskMounted) {
        Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
    }
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
}
