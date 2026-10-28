Set-StrictMode -Version 2

function ConvertTo-RudraText {
    param([Parameter(Mandatory=$true)][System.Collections.IEnumerable]$Lines)
    return [string]::Join([Environment]::NewLine, [string[]]@($Lines))
}

function Get-RudraSystemReport {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('RUDRA-Live-PE | System information')
    $lines.Add(('Collected: {0:u}' -f (Get-Date)))
    $lines.Add('')
    try {
        $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
        $lines.Add(('Manufacturer: {0}' -f $cs.Manufacturer))
        $lines.Add(('Model: {0}' -f $cs.Model))
        $lines.Add(('Memory: {0:N1} GiB' -f ($cs.TotalPhysicalMemory / 1GB)))
    } catch { $lines.Add(('Computer information unavailable: {0}' -f $_.Exception.Message)) }

    try {
        $cpu = @(Get-WmiObject -Class Win32_Processor -ErrorAction Stop | Select-Object -ExpandProperty Name)
        $lines.Add(('Processor: {0}' -f ($cpu -join '; ')))
    } catch { $lines.Add(('Processor information unavailable: {0}' -f $_.Exception.Message)) }

    try {
        $bios = Get-WmiObject -Class Win32_BIOS -ErrorAction Stop
        $lines.Add(('BIOS vendor/version: {0} / {1}' -f $bios.Manufacturer, ($bios.SMBIOSBIOSVersion -join '; ')))
    } catch { $lines.Add(('BIOS information unavailable: {0}' -f $_.Exception.Message)) }

    $lines.Add('')
    $lines.Add('This report identifies the WinPE session hardware. It does not diagnose hardware failure.')
    return ConvertTo-RudraText $lines
}

function Test-RudraPingTarget {
    param([Parameter(Mandatory=$true)][string]$Target)

    $value = $Target.Trim()
    if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 253) {
        throw 'Enter a valid IPv4/IPv6 address or DNS host name.'
    }

    $address = $null
    if ([System.Net.IPAddress]::TryParse($value, [ref]$address)) {
        return $address.ToString()
    }

    $hostName = $value.TrimEnd('.')
    $label = '[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    if ($hostName.Length -gt 253 -or $hostName -notmatch ('^' + $label + '(?:\.' + $label + ')*$')) {
        throw 'The ping target must be an IP address or a DNS host name using letters, digits, dots, and interior hyphens.'
    }
    return $hostName
}

function Get-RudraNetworkReport {
    param([string]$PingTarget = '')

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('RUDRA-Live-PE | Network diagnostics')
    $lines.Add(('Collected: {0:u}' -f (Get-Date)))
    $lines.Add('')

    try {
        $configs = @(Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop)
        if ($configs.Count -eq 0) {
            $lines.Add('No active IP-enabled network adapter was reported.')
        }

        foreach ($adapter in $configs) {
            $lines.Add(('Adapter: {0}' -f $adapter.Description))
            $lines.Add(('  DHCP: {0}' -f $adapter.DHCPEnabled))
            $lines.Add(('  Address: {0}' -f (@($adapter.IPAddress) -join ', ')))
            $lines.Add(('  Gateway: {0}' -f (@($adapter.DefaultIPGateway) -join ', ')))
            $lines.Add(('  DNS: {0}' -f (@($adapter.DNSServerSearchOrder) -join ', ')))
        }
    } catch {
        $lines.Add(('Adapter information unavailable: {0}' -f $_.Exception.Message))
    }

    $lines.Add('')
    foreach ($tool in @('ipconfig.exe','route.exe')) {
        $path = Join-Path $env:SystemRoot ('System32\' + $tool)

        if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue) {
            $lines.Add(('--- {0} ---' -f $tool))
            try {
                if ($tool -eq 'ipconfig.exe') {
                    $lines.AddRange([string[]]@(& $path /all 2>&1 | ForEach-Object { [string]$_ }))
                } else {
                    $lines.AddRange([string[]]@(& $path print -4 2>&1 | ForEach-Object { [string]$_ }))
                }
            } catch {
                $lines.Add(('Command failed: {0}' -f $_.Exception.Message))
            }
        } else {
            $lines.Add(('{0} is not available in this WinPE image.' -f $tool))
        }
        $lines.Add('')
    }

    if (-not [string]::IsNullOrWhiteSpace($PingTarget)) {
        try {
            $validated = Test-RudraPingTarget -Target $PingTarget
            $ping = Join-Path $env:SystemRoot 'System32\ping.exe'
            if (-not (Test-Path -LiteralPath $ping -PathType Leaf)) {
                throw 'ping.exe is unavailable in this WinPE image.'
            }

            $lines.Add(('--- Ping {0} ---' -f $validated))
            $lines.AddRange([string[]]@(& $ping -n 2 -w 1500 $validated 2>&1 | ForEach-Object { [string]$_ }))
        } catch {
            $lines.Add(('Ping was not run: {0}' -f $_.Exception.Message))
        }
    } else {
        $lines.Add('Optional ping was not requested. Enter a host or IP address in the launcher to run it.')
    }

    return ConvertTo-RudraText $lines
}

function Get-RudraDiskReport {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('RUDRA-Live-PE | Read-only disk inspection')
    $lines.Add(('Collected: {0:u}' -f (Get-Date)))
    $lines.Add('')

    $getDisk = Get-Command Get-Disk -ErrorAction SilentlyContinue
    if ($getDisk) {
        try {
            $disks = @(Get-Disk -ErrorAction Stop)
            if ($disks.Count -eq 0) {
                $lines.Add('No disks were reported by the storage provider.')
            }

            foreach ($disk in $disks) {
                $lines.Add(('Disk {0}: {1} | {2:N1} GiB | {3} | {4} | Offline={5} | ReadOnly={6}' -f $disk.Number, $disk.FriendlyName, ($disk.Size / 1GB), $disk.PartitionStyle, ($disk.OperationalStatus -join ', '), $disk.IsOffline, $disk.IsReadOnly))
            }
        } catch {
            $lines.Add(('Get-Disk failed: {0}' -f $_.Exception.Message))
        }
    } else {
        $lines.Add('Get-Disk is unavailable; using the legacy WMI inventory.')
        try {
            foreach ($disk in @(Get-WmiObject -Class Win32_DiskDrive -ErrorAction Stop)) {
                $lines.Add(('Disk {0}: {1} | {2:N1} GiB | Provider status: {3}' -f $disk.Index, $disk.Model, ($disk.Size / 1GB), $disk.Status))
            }
        } catch {
            $lines.Add(('Disk inventory failed: {0}' -f $_.Exception.Message))
        }
    }

    $lines.Add('')
    if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        try {
            $physical = @(Get-PhysicalDisk -ErrorAction Stop)
            if ($physical.Count -gt 0) {
                $lines.Add('Provider-reported physical disk status (availability depends on WinPE drivers):')
                foreach ($disk in $physical) {
                    $lines.Add(('  {0} | {1} | {2} | {3:N1} GiB' -f $disk.FriendlyName, $disk.BusType, $disk.HealthStatus, ($disk.Size / 1GB)))
                }
            } else {
                $lines.Add('The storage provider returned no physical disk health records.')
            }
        } catch {
            $lines.Add(('Physical disk health data unavailable: {0}' -f $_.Exception.Message))
        }
    } else {
        $lines.Add('Get-PhysicalDisk is unavailable; no health status is inferred.')
    }

    $lines.Add('')
    $lines.Add('All checks are read-only. Provider-reported health is not a SMART self-test or a guarantee of drive condition.')
    return ConvertTo-RudraText $lines
}

function Get-RudraRecoveryReport {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('RUDRA-Live-PE | Windows recovery diagnostics')
    $lines.Add(('Collected: {0:u}' -f (Get-Date)))
    $lines.Add('')

    $roots = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[A-Za-z]$' } |
        ForEach-Object { '{0}:\' -f $_.Name })

    $installations = New-Object 'System.Collections.Generic.List[string]'
    foreach ($root in $roots) {
        $systemHive = Join-Path $root 'Windows\System32\Config\SYSTEM'
        $softwareHive = Join-Path $root 'Windows\System32\Config\SOFTWARE'

        try {
            $hasSystemHive = Test-Path -LiteralPath $systemHive -PathType Leaf -ErrorAction Stop
            $hasSoftwareHive = Test-Path -LiteralPath $softwareHive -PathType Leaf -ErrorAction Stop
        } catch {
            $lines.Add(('Volume {0} could not be inspected by the current account.' -f $root))
            continue
        }

        if ($hasSystemHive -and $hasSoftwareHive) {
            $installations.Add($root)
            $lines.Add(('Candidate Windows installation: {0}Windows' -f $root))

            foreach ($relative in @(
                'Windows\System32\winload.exe',
                'Windows\System32\winload.efi',
                'Windows\System32\Config\SYSTEM',
                'Windows\System32\Config\SOFTWARE'
            )) {
                $present = Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf -ErrorAction SilentlyContinue
                $lines.Add(('  {0}: {1}' -f $relative, $present))
            }
        }
    }

    if ($installations.Count -eq 0) {
        $lines.Add('No mounted volume with both offline SYSTEM and SOFTWARE registry hives was found.')
    }

    $lines.Add('')
    $bcdFound = $false
    foreach ($root in $roots) {
        foreach ($relative in @('Boot\BCD','EFI\Microsoft\Boot\BCD')) {
            $path = Join-Path $root $relative
            if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue) {
                $bcdFound = $true
                $lines.Add(('Boot configuration store present: {0}{1}' -f $root, $relative))
            }
        }
    }

    if (-not $bcdFound) {
        $lines.Add('No standard BCD store was found on mounted drive-letter volumes.')
    }

    $lines.Add('')
    $lines.Add('This checks mounted volumes and file presence only. It does not validate BCD contents, unlock encrypted volumes, or repair Windows.')
    return ConvertTo-RudraText $lines
}

function Get-RudraWindowsInstallations {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('RUDRA-Live-PE | Windows installation finder')
    $lines.Add(('Scanned: {0:u}' -f (Get-Date)))
    $lines.Add('')

    $roots = @(
        Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[A-Za-z]$' } |
        ForEach-Object { '{0}:\' -f $_.Name }
    )

    $found = 0
    foreach ($root in $roots) {
        $windowsDir = Join-Path $root 'Windows'
        $systemHive = Join-Path $windowsDir 'System32\Config\SYSTEM'
        $softwareHive = Join-Path $windowsDir 'System32\Config\SOFTWARE'

        try {
            $hasSystem = Test-Path -LiteralPath $systemHive -PathType Leaf -ErrorAction Stop
            $hasSoftware = Test-Path -LiteralPath $softwareHive -PathType Leaf -ErrorAction Stop
        } catch {
            $lines.Add(('Could not inspect {0}: {1}' -f $root, $_.Exception.Message))
            continue
        }

        if ($hasSystem -and $hasSoftware) {
            $found++
            $lines.Add(('Possible Windows installation: {0}Windows' -f $root))
            $lines.Add(('  SYSTEM hive: {0}' -f $hasSystem))
            $lines.Add(('  SOFTWARE hive: {0}' -f $hasSoftware))
            $lines.Add(('  winload.exe: {0}' -f (Test-Path -LiteralPath (Join-Path $windowsDir 'System32\winload.exe') -PathType Leaf -ErrorAction SilentlyContinue)))
            $lines.Add(('  winload.efi: {0}' -f (Test-Path -LiteralPath (Join-Path $windowsDir 'System32\winload.efi') -PathType Leaf -ErrorAction SilentlyContinue)))
            $lines.Add('')
        }
    }

    if ($found -eq 0) {
        $lines.Add('No Windows installation was detected on mounted drive-letter volumes.')
        $lines.Add('A locked BitLocker volume or an unmounted partition may not be visible.')
    }

    $lines.Add('')
    $lines.Add('Read-only scan: no files, settings, or accounts were changed.')
    return ConvertTo-RudraText $lines
}

function Export-RudraLogs {
    param(
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$Destination,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$SessionLogPath
    )

    $destinationPath = [IO.Path]::GetFullPath($Destination)
    if (-not (Test-Path -LiteralPath $destinationPath -PathType Container)) {
        throw 'Choose an existing destination folder for the log package.'
    }

    $sources = @(
        @{ Path = $SessionLogPath; Name = 'RUDRA-session.log' },
        @{ Path = (Join-Path $env:SystemRoot 'Logs\DISM\dism.log'); Name = 'DISM.log' },
        @{ Path = (Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'); Name = 'CBS.log' },
        @{ Path = (Join-Path $env:SystemRoot 'INF\setupapi.dev.log'); Name = 'setupapi.dev.log' },
        @{ Path = (Join-Path $env:SystemRoot 'Panther\setupact.log'); Name = 'setupact.log' },
        @{ Path = (Join-Path $env:SystemRoot 'Panther\setuperr.log'); Name = 'setuperr.log' }
    )

    $available = @($sources | Where-Object { Test-Path -LiteralPath $_.Path -PathType Leaf })
    if ($available.Count -eq 0) {
        throw 'No supported RUDRA or Windows diagnostic logs were found.'
    }

    $package = Join-Path $destinationPath ('RUDRA-Logs-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if (Test-Path -LiteralPath $package) {
        $package += '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    }

    New-Item -ItemType Directory -Path $package -ErrorAction Stop | Out-Null
    $copied = New-Object 'System.Collections.Generic.List[string]'

    foreach ($item in $available) {
        Copy-Item -LiteralPath $item.Path -Destination (Join-Path $package $item.Name) -ErrorAction Stop
        $copied.Add($item.Name)
    }

    return ('Log package created: {0}{1}Files copied: {2}' -f $package, [Environment]::NewLine, ($copied -join ', '))
}


function Get-RudraPasswordRecoveryGuide {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('RUDRA-Live-PE | Password & account recovery')
    $lines.Add('')
    $lines.Add('For a PC/account you own or are explicitly authorized to service:')
    $lines.Add('1. Microsoft account: use Microsoft account password reset from another trusted device; network access may be required.')
    $lines.Add('2. Local account: use another authorized administrator, the Windows password-reset disk if previously created, or the organization''s approved recovery process.')
    $lines.Add('3. Work/school device: contact the IT administrator; do not bypass organization controls.')
    $lines.Add('4. Lazesoft is handled as separate bootable media. Its reset wizard did not detect a Windows installation in the current VMware test, so that workflow is not yet verified.')
    $lines.Add('')
    $lines.Add('RUDRA does not claim to reset a password from this screen. No account or disk changes were made.')
    return ConvertTo-RudraText $lines
}

function Get-RudraLazesoftGuide {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('RUDRA-Live-PE | Lazesoft recovery media')
    $lines.Add('')
    $lines.Add('Standalone ISO boot has been observed in VMware. Password Recovery opened, but the wizard did not find a Windows installation; disk detection through Load Driver alone did not prove installation detection.')
    $lines.Add('')
    $lines.Add('Current integration mode: documented external-boot workflow. This WinPE launcher cannot directly execute a separate bootable ISO as a normal application.')
    $lines.Add('1. Keep Lazesoft-Recovery.iso on separate bootable media or attach it as the VM CD/DVD image.')
    $lines.Add('2. Reboot the test VM/PC and select that ISO from its boot menu.')
    $lines.Add('3. Test only against a disposable VM or a system you are authorized to recover.')
    $lines.Add('4. Before redistributing a combined image, verify the vendor terms for the exact use and distribution method.')
    return ConvertTo-RudraText $lines
}

function Get-RudraDataRecoveryGuide {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('RUDRA-Live-PE | Disk & data recovery triage')
    $lines.Add('')
    $lines.Add('1. Run Disk health inspection and record disk/volume inventory.')
    $lines.Add('2. If data is important and the disk is failing, stop writes and consider a sector-level image made to a separate healthy destination.')
    $lines.Add('3. Do not format, initialize, repartition, run CHKDSK /f, or save recovered files back to the source disk.')
    $lines.Add('4. Copy accessible files to a separate destination only after verifying source and destination drive letters.')
    $lines.Add('5. BitLocker-protected volumes require the legitimate recovery key; RUDRA does not bypass encryption.')
    $lines.Add('')
    $lines.Add('This screen is guidance, not a file undelete engine. No disk writes were performed.')
    return ConvertTo-RudraText $lines
}

function Get-RudraTechnicianGuide {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('RUDRA-Live-PE | Technician toolkit')
    $lines.Add('')
    $lines.Add('Use Open tool… to launch built-in PowerShell or File Explorer.')
    $lines.Add('Available read-only reports: system information, network diagnostics, disk inventory, Windows recovery checks, Windows installation finder.')
    $lines.Add('Useful built-in commands: ipconfig /all; route print; ping <gateway-or-host>; diskpart (use list disk/list volume only unless a write operation is explicitly intended); Get-Disk when supported.')
    $lines.Add('Be careful: diskpart clean, format, convert, and partition commands can destroy data. They are not run by RUDRA reports.')
    return ConvertTo-RudraText $lines
}

Export-ModuleMember -Function Get-RudraSystemReport,Get-RudraNetworkReport,Get-RudraDiskReport,Get-RudraRecoveryReport,Get-RudraWindowsInstallations,Get-RudraPasswordRecoveryGuide,Get-RudraLazesoftGuide,Get-RudraDataRecoveryGuide,Get-RudraTechnicianGuide,Export-RudraLogs,Test-RudraPingTarget