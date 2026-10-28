$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    Import-Module (Join-Path $scriptDirectory 'RUDRA-Tools.psm1') -Force -ErrorAction Stop

    $logDirectory = Join-Path $env:SystemDrive 'RUDRA\Logs'
    New-Item -ItemType Directory -Force -Path $logDirectory -ErrorAction Stop | Out-Null
    $sessionLog = Join-Path $logDirectory 'RUDRA-session.log'

    function Write-SessionLog {
        param([string]$Action,[string]$Status)
        $line = '{0:u} | {1} | {2}{3}' -f (Get-Date), $Action, $Status, [Environment]::NewLine
        try { [IO.File]::AppendAllText($sessionLog, $line, [Text.Encoding]::UTF8) } catch { }
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'RUDRA-Live-PE | Recovery & Diagnostics'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(1040,700)
    $form.MinimumSize = New-Object System.Drawing.Size(850,680)
    $form.BackColor = [System.Drawing.Color]::FromArgb(242,245,248)
    $form.Font = New-Object System.Drawing.Font('Segoe UI',9)
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 82
    $header.BackColor = [System.Drawing.Color]::FromArgb(20,42,66)
    $form.Controls.Add($header)

    $brand = New-Object System.Windows.Forms.Label
    $brand.Text = 'RUDRA-Live-PE'
    $brand.ForeColor = [System.Drawing.Color]::White
    $brand.Font = New-Object System.Drawing.Font('Segoe UI Semibold',20,[System.Drawing.FontStyle]::Bold)
    $brand.AutoSize = $true
    $brand.Location = New-Object System.Drawing.Point(22,10)
    $header.Controls.Add($brand)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = 'Recovery and diagnostics  |  Created by Rudra Shankar Puhan'
    $subtitle.ForeColor = [System.Drawing.Color]::FromArgb(205,220,235)
    $subtitle.AutoSize = $true
    $subtitle.Location = New-Object System.Drawing.Point(25,52)
    $header.Controls.Add($subtitle)

    $toolsLabel = New-Object System.Windows.Forms.Label
    $toolsLabel.Text = 'DIAGNOSTIC TOOLS'
    $toolsLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold',9,[System.Drawing.FontStyle]::Bold)
    $toolsLabel.ForeColor = [System.Drawing.Color]::FromArgb(55,75,95)
    $toolsLabel.Location = New-Object System.Drawing.Point(20,101)
    $toolsLabel.Size = New-Object System.Drawing.Size(240,22)
    $form.Controls.Add($toolsLabel)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(20,126)
    $list.Size = New-Object System.Drawing.Size(270,410)
    $list.Anchor = 'Top,Bottom,Left'
    $list.IntegralHeight = $false
    $list.Font = New-Object System.Drawing.Font('Segoe UI',10)
    $form.Controls.Add($list)

    $toolItems = @(
        [PSCustomObject]@{ Title='System information'; Key='system'; Detail='Computer model, processor, memory, and BIOS overview.' },
        [PSCustomObject]@{ Title='Network diagnostics'; Key='network'; Detail='Adapter configuration, IP settings, routes, and optional ping.' },
        [PSCustomObject]@{ Title='Disk health inspection'; Key='disk'; Detail='Read-only disk and provider-reported health inventory.' },
        [PSCustomObject]@{ Title='Windows recovery checks'; Key='recovery'; Detail='Find mounted Windows installations and common boot files.' },
        [PSCustomObject]@{ Title='Find Windows installations'; Key='installations'; Detail='Scan mounted drive letters for Windows folders, registry hives, and boot loader files (read-only).' },
        [PSCustomObject]@{ Title='Password & account recovery'; Key='password'; Detail='Guided recovery options for an owned PC; Lazesoft remains a separate bootable environment.' },
        [PSCustomObject]@{ Title='Lazesoft recovery media'; Key='lazesoft'; Detail='Locate a separately prepared Lazesoft ISO or show the safe external-boot workflow.' },
        [PSCustomObject]@{ Title='Disk & data recovery guidance'; Key='data'; Detail='Read-only triage and safe file-copy guidance before attempting recovery.' },
        [PSCustomObject]@{ Title='Technician toolkit'; Key='technician'; Detail='Open PowerShell or File Explorer for hands-on diagnostics.' }
    )
    $list.DisplayMember = 'Title'
    foreach ($item in $toolItems) { [void]$list.Items.Add($item) }
    $list.SelectedIndex = 0

    $pingLabel = New-Object System.Windows.Forms.Label
    $pingLabel.Text = 'Optional ping host/IP (network tool only)'
    $pingLabel.Location = New-Object System.Drawing.Point(312,101)
    $pingLabel.Size = New-Object System.Drawing.Size(420,22)
    $form.Controls.Add($pingLabel)

    $pingBox = New-Object System.Windows.Forms.TextBox
    $pingBox.Location = New-Object System.Drawing.Point(312,126)
    $pingBox.Size = New-Object System.Drawing.Size(430,26)
    $pingBox.Anchor = 'Top,Left,Right'
    $form.Controls.Add($pingBox)

    $detail = New-Object System.Windows.Forms.Label
    $detail.Text = 'Select a diagnostic, then choose Run selected. Checks are read-only.'
    $detail.Location = New-Object System.Drawing.Point(312,160)
    $detail.Size = New-Object System.Drawing.Size(690,22)
    $detail.Anchor = 'Top,Left,Right'
    $detail.ForeColor = [System.Drawing.Color]::FromArgb(65,80,95)
    $form.Controls.Add($detail)

    $output = New-Object System.Windows.Forms.TextBox
    $output.Location = New-Object System.Drawing.Point(312,187)
    $output.Size = New-Object System.Drawing.Size(690,349)
    $output.Anchor = 'Top,Bottom,Left,Right'
    $output.Multiline = $true
    $output.ReadOnly = $true
    $output.WordWrap = $false
    $output.ScrollBars = 'Both'
    $output.Font = New-Object System.Drawing.Font('Consolas',9)
    $output.BackColor = [System.Drawing.Color]::FromArgb(24,31,40)
    $output.ForeColor = [System.Drawing.Color]::FromArgb(226,235,242)
    $output.Text = 'Select a tool to view diagnostic results.' + [Environment]::NewLine + [Environment]::NewLine + 'Diagnostics are read-only. Log collection copies files only after confirmation.'
    $form.Controls.Add($output)

    $status = New-Object System.Windows.Forms.Label
    $status.Text = 'Ready | Logs are stored in the WinPE RAM drive and are lost at shutdown unless exported.'
    $status.Location = New-Object System.Drawing.Point(20,548)
    $status.Size = New-Object System.Drawing.Size(980,24)
    $status.Anchor = 'Bottom,Left,Right'
    $status.ForeColor = [System.Drawing.Color]::FromArgb(65,80,95)
    $form.Controls.Add($status)

    $runButton = New-Object System.Windows.Forms.Button
    $runButton.Text = 'Run selected'
    $runButton.Location = New-Object System.Drawing.Point(20,590)
    $runButton.Size = New-Object System.Drawing.Size(150,38)
    $runButton.Anchor = 'Bottom,Left'
    $runButton.BackColor = [System.Drawing.Color]::FromArgb(23,105,170)
    $runButton.ForeColor = [System.Drawing.Color]::White
    $runButton.FlatStyle = 'Flat'
    $form.Controls.Add($runButton)

    $exportButton = New-Object System.Windows.Forms.Button
    $exportButton.Text = 'Collect logs…'
    $exportButton.Location = New-Object System.Drawing.Point(184,590)
    $exportButton.Size = New-Object System.Drawing.Size(150,38)
    $exportButton.Anchor = 'Bottom,Left'
    $form.Controls.Add($exportButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = 'Close'
    $closeButton.Location = New-Object System.Drawing.Point(852,590)
    $closeButton.Size = New-Object System.Drawing.Size(150,38)
    $closeButton.Anchor = 'Bottom,Right'
    $form.Controls.Add($closeButton)

    $list.Add_SelectedIndexChanged({
        if ($null -ne $list.SelectedItem) { $detail.Text = $list.SelectedItem.Detail }
    })

    $runButton.Add_Click({
        $selected = $list.SelectedItem
        if ($null -eq $selected) { return }
        $runButton.Enabled = $false
        $form.UseWaitCursor = $true
        $status.Text = 'Running read-only diagnostic…'
        try {
            switch ($selected.Key) {
                'system' { $result = Get-RudraSystemReport }
                'network' { $result = Get-RudraNetworkReport -PingTarget $pingBox.Text }
                'disk' { $result = Get-RudraDiskReport }
                'recovery' { $result = Get-RudraRecoveryReport }
                'installations' { $result = Get-RudraWindowsInstallations }
                'password' { $result = Get-RudraPasswordRecoveryGuide }
                'lazesoft' { $result = Get-RudraLazesoftGuide }
                'data' { $result = Get-RudraDataRecoveryGuide }
                'technician' { $result = Get-RudraTechnicianGuide }
                default { throw 'Unknown diagnostic selection.' }
            }
            $output.Text = [string]$result
            Write-SessionLog -Action $selected.Key -Status 'completed'
            $status.Text = ('Completed: {0} | No local configuration changed.' -f $selected.Title)
        } catch {
            $output.Text = ('Diagnostic could not complete: {0}' -f $_.Exception.Message)
            Write-SessionLog -Action $selected.Key -Status 'error'
            $status.Text = 'Diagnostic reported an error. Review the result pane.'
        } finally {
            $form.UseWaitCursor = $false
            $runButton.Enabled = $true
        }
    })

    $exportButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Choose an existing folder for a new RUDRA log package. Logs can contain device names, file paths, and timestamps.'
        $dialog.ShowNewFolderButton = $true
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            'Copy the RUDRA session log and available Windows DISM, CBS, SetupAPI, and Setup logs to a new folder? No credentials or browser data are collected.',
            'Confirm log collection',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        try {
            Write-SessionLog -Action 'log-collection' -Status 'started'
            $output.Text = Export-RudraLogs -Destination $dialog.SelectedPath -SessionLogPath $sessionLog
            Write-SessionLog -Action 'log-collection' -Status 'completed'
            $status.Text = 'Log package copied to the selected folder.'
        } catch {
            $output.Text = ('Log collection could not complete: {0}' -f $_.Exception.Message)
            Write-SessionLog -Action 'log-collection' -Status 'error'
            $status.Text = 'Log collection reported an error.'
        }
    })

    $closeButton.Add_Click({ $form.Close() })

    # Open only built-in technician tools, and only on explicit operator action.
    $launchButton = New-Object System.Windows.Forms.Button
    $launchButton.Text = 'Open tool…'
    $launchButton.Location = New-Object System.Drawing.Point(348,590)
    $launchButton.Size = New-Object System.Drawing.Size(150,38)
    $launchButton.Anchor = 'Bottom,Left'
    $form.Controls.Add($launchButton)
    $launchButton.Add_Click({
        try {
            switch ([string]$list.SelectedItem.Key) {
                'technician' {
                    $choice = [System.Windows.Forms.MessageBox]::Show('Yes = open PowerShell. No = open File Explorer. Cancel = do nothing.', 'RUDRA Technician Toolkit', [System.Windows.Forms.MessageBoxButtons]::YesNoCancel, [System.Windows.Forms.MessageBoxIcon]::Question)
                    if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') }
                    elseif ($choice -eq [System.Windows.Forms.DialogResult]::No) { Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') }
                }
                'lazesoft' {
                    [void][System.Windows.Forms.MessageBox]::Show('Lazesoft is a separate bootable environment and cannot be launched as a normal app from this WinPE session. Keep its ISO on a separate USB/device and boot that media from the firmware/VM boot menu. If the ISO is eventually bundled as a payload, this button will still show the external-boot instructions; it does not chain-boot the ISO.', 'Lazesoft recovery media', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                }
                default { [void][System.Windows.Forms.MessageBox]::Show('Select Technician toolkit to open PowerShell or File Explorer, or Lazesoft recovery media for boot instructions.', 'RUDRA', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) }
            }
        } catch { [void][System.Windows.Forms.MessageBox]::Show(('Could not open selected tool: {0}' -f $_.Exception.Message), 'RUDRA', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) }
    })
    Write-SessionLog -Action 'launcher' -Status 'started'
    [void]$form.ShowDialog()
    Write-SessionLog -Action 'launcher' -Status 'closed'
} catch {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [void][System.Windows.Forms.MessageBox]::Show(('RUDRA-Live-PE could not start: {0}' -f $_.Exception.Message),'RUDRA-Live-PE',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)
    } catch { }
    exit 1
}
