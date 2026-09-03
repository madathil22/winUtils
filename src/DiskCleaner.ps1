<#
    WinUtils Disk Cleaner
    ---------------------
    Finds what is eating your drive and helps you get the space back.

    Run it with DiskCleaner.bat, or directly:
        powershell -NoProfile -ExecutionPolicy Bypass -STA -File src\DiskCleaner.ps1
#>

[CmdletBinding()]
param(
    [string]$Drive = $env:SystemDrive
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ---------------------------------------------------------------- bootstrapping

# WPF and the clipboard both require a single threaded apartment.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Warning 'Relaunching in STA mode (required for the UI).'
    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path $psExe)) { $psExe = 'powershell.exe' }
    Start-Process $psExe -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
        '-File', $MyInvocation.MyCommand.Definition
    )
    return
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

function Initialize-ScanEngine {
    <#
        Compiles Scanner.cs once and caches the assembly, keyed by source hash, so
        later launches start instantly instead of paying for a fresh compile.
    #>
    param([string]$SourcePath)

    if ('WinUtils.Scanner' -as [type]) { return }

    $cacheDir = Join-Path $env:LOCALAPPDATA 'WinUtils\bin'
    $hash = (Get-FileHash -Path $SourcePath -Algorithm SHA256).Hash.Substring(0, 16)
    $dll = Join-Path $cacheDir ("WinUtils.Engine.$hash.dll")

    if (Test-Path $dll) {
        try { Add-Type -Path $dll; return } catch { }
    }

    $source = Get-Content $SourcePath -Raw
    try {
        if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }

        # Drop assemblies built from older revisions of the source.
        Get-ChildItem -Path $cacheDir -Filter 'WinUtils.Engine.*.dll' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $dll } |
            ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

        Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $dll -OutputType Library
        Add-Type -Path $dll
    }
    catch {
        # The cache is only an optimisation; an in-memory build always works.
        if (-not ('WinUtils.Scanner' -as [type])) {
            Add-Type -TypeDefinition $source -Language CSharp
        }
    }
}

Initialize-ScanEngine -SourcePath (Join-Path $ScriptRoot 'Scanner.cs')
. (Join-Path $ScriptRoot 'Cleanup.ps1')

$xamlPath = Join-Path $ScriptRoot 'MainWindow.xaml'
$reader = New-Object System.Xml.XmlNodeReader ([xml](Get-Content $xamlPath -Raw))
$win = [Windows.Markup.XamlReader]::Load($reader)

# Hoist every named control into a script-scope variable of the same name.
foreach ($controlName in @(
    'cboDrive','btnScan','btnStop','pbScan','txtScanStatus','chkRecycle',
    'bannerAdmin','btnElevate','tabs','treeFolders',
    'txtSelName','txtSelPath','txtSelSize','txtSelDetail','txtSelPct',
    'btnOpenFolder','btnCopyPath','btnDeleteFolder',
    'txtFileFilter','btnOpenFileLoc','btnDeleteFiles','txtFilesInfo','lstFiles',
    'btnMeasureJunk','btnSelectSafe','btnSelectNone','btnCleanJunk','txtJunkInfo','lstJunk',
    'txtProgFilter','btnRefreshProgs','btnMeasureProgs','btnUninstall','txtProgInfo','lstPrograms',
    'txtStatus','txtDriveInfo'
)) {
    Set-Variable -Name $controlName -Value $win.FindName($controlName) -Scope Script
}

# ---------------------------------------------------------------- shared state
#
# Everything mutable lives here. Event handlers and timer ticks each run in their
# own scope, so one script-scope bag is the reliable way to share context.

$script:S = @{
    Scanner        = $null
    ScanTimer      = $null
    RootNode       = $null
    AllFiles       = @()
    Junk           = $null
    Programs       = $null
    Busy           = $false

    Deleter        = $null
    DelTimer       = $null
    DelLabel       = ''
    DelOnDone      = $null
    Ctx            = @{}

    Measurer       = $null
    MeasTimer      = $null
    MeasOnDone     = $null
    MeasOnProgress = $null

    SortMaps       = @{}
    SortState      = @{}
}

$script:IsAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------------------------------------------------------------- small helpers

function Set-Status([string]$Text) { $txtStatus.Text = $Text }

function Format-Size([long]$Bytes) { return [WinUtils.Fmt]::Bytes($Bytes) }

function Show-Info([string]$Message, [string]$Title = 'WinUtils Disk Cleaner') {
    [void][System.Windows.MessageBox]::Show($win, $Message, $Title,
        [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
}

function Confirm-Action([string]$Message, [string]$Title = 'Confirm') {
    $r = [System.Windows.MessageBox]::Show($win, $Message, $Title,
        [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    return ($r -eq [System.Windows.MessageBoxResult]::Yes)
}

function Get-SumBytes($Items) {
    $sum = ($Items | Measure-Object -Property Size -Sum).Sum
    if ($null -eq $sum) { return [int64]0 }
    return [int64]$sum
}

function Open-InExplorer {
    param([string]$Path, [switch]$SelectItem)
    try {
        if ($SelectItem) { Start-Process 'explorer.exe' -ArgumentList "/select,`"$Path`"" }
        else { Start-Process 'explorer.exe' -ArgumentList "`"$Path`"" }
    } catch { Set-Status "Could not open Explorer: $($_.Exception.Message)" }
}

function Set-UiBusy([bool]$Busy) {
    $script:S.Busy = $Busy
    $btnScan.IsEnabled         = -not $Busy
    $btnCleanJunk.IsEnabled    = -not $Busy
    $btnMeasureJunk.IsEnabled  = -not $Busy
    $btnMeasureProgs.IsEnabled = -not $Busy
    $btnDeleteFiles.IsEnabled  = (-not $Busy) -and ($lstFiles.SelectedItems.Count -gt 0)
    $btnDeleteFolder.IsEnabled = (-not $Busy) -and ($null -ne $treeFolders.SelectedItem)
    if ($Busy) { $win.Cursor = [System.Windows.Input.Cursors]::AppStarting }
    else { $win.Cursor = $null }
}

# ---------------------------------------------------------------- drives

function Initialize-Drives {
    $cboDrive.Items.Clear()
    $wanted = $Drive
    if ($wanted -and $wanted.Length -eq 2) { $wanted += '\' }

    $selectIndex = 0
    $i = 0
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -ne [System.IO.DriveType]::Fixed -or -not $d.IsReady) { continue }

        $used = $d.TotalSize - $d.TotalFreeSpace
        $pct = 0
        if ($d.TotalSize -gt 0) { $pct = [math]::Round($used * 100.0 / $d.TotalSize) }
        $label = '{0}   {1} used of {2}  ({3}% full)' -f `
            $d.Name.TrimEnd('\'), (Format-Size $used), (Format-Size $d.TotalSize), $pct

        $cbi = New-Object System.Windows.Controls.ComboBoxItem
        $cbi.Content = $label
        $cbi.Tag = $d.Name
        [void]$cboDrive.Items.Add($cbi)

        if ($d.Name -eq $wanted) { $selectIndex = $i }
        $i++
    }

    if ($cboDrive.Items.Count -gt 0) { $cboDrive.SelectedIndex = $selectIndex }
    Update-DriveInfo
}

function Update-DriveInfo {
    if ($null -eq $cboDrive.SelectedItem) { return }
    try {
        $d = New-Object System.IO.DriveInfo ([string]$cboDrive.SelectedItem.Tag)
        $txtDriveInfo.Text = '{0} free of {1}' -f (Format-Size $d.TotalFreeSpace), (Format-Size $d.TotalSize)
    } catch { $txtDriveInfo.Text = '' }
}

function Get-SelectedDriveRoot {
    if ($null -eq $cboDrive.SelectedItem) { return ($env:SystemDrive + '\') }
    return [string]$cboDrive.SelectedItem.Tag
}

# ---------------------------------------------------------------- scanning

function Start-Scan {
    if ($script:S.Busy) { return }
    $root = Get-SelectedDriveRoot

    $scanner = New-Object WinUtils.Scanner
    $scanner.LargeFileThreshold = 50MB
    $scanner.MaxLargeFiles = 5000
    $script:S.Scanner = $scanner

    $treeFolders.ItemsSource = $null
    $lstFiles.ItemsSource = $null
    $script:S.RootNode = $null
    $script:S.AllFiles = @()

    Set-UiBusy $true
    $btnStop.IsEnabled = $true
    $pbScan.Visibility = 'Visible'
    Set-Status "Scanning $root ..."

    $scanner.Start($root)

    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(200)
    $t.Add_Tick({ Update-ScanProgress })
    $script:S.ScanTimer = $t
    $t.Start()
}

function Update-ScanProgress {
    $sc = $script:S.Scanner
    if ($null -eq $sc) { return }

    if ($sc.IsRunning) {
        $txtScanStatus.Text = '{0} folders / {1} files / {2}' -f `
            $sc.DirsScanned.ToString('N0'), $sc.FilesScanned.ToString('N0'), (Format-Size $sc.BytesScanned)
        $path = $sc.CurrentPath
        if ($path.Length -gt 95) { $path = '...' + $path.Substring($path.Length - 92) }
        Set-Status $path
        return
    }

    $script:S.ScanTimer.Stop()
    $pbScan.Visibility = 'Hidden'
    $btnStop.IsEnabled = $false
    Set-UiBusy $false
    Complete-Scan
}

function Complete-Scan {
    $sc = $script:S.Scanner
    $root = $sc.Result

    if ($null -eq $root) {
        $msg = 'the scan produced no result'
        if ($sc.Error) { $msg = $sc.Error.Message }
        Set-Status "Scan failed: $msg"
        $txtScanStatus.Text = ''
        return
    }

    $script:S.RootNode = $root
    $treeFolders.ItemsSource = @($root)

    # Expand the root row once its container has been generated.
    $treeFolders.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Loaded,
        [action]{
            $c = $treeFolders.ItemContainerGenerator.ContainerFromIndex(0)
            if ($c) { $c.IsExpanded = $true }
        }) | Out-Null

    $script:S.AllFiles = @($sc.LargeFiles | Sort-Object -Property Size -Descending)
    Update-FileView

    $note = ''
    if ($sc.IsCancelled) { $note += ' (stopped early)' }
    if ($sc.DeniedCount -gt 0) {
        $note += '  {0:N0} folders were not readable' -f $sc.DeniedCount
        if (-not $script:IsAdmin) { $note += ', restart as Administrator to include them' }
        $note += '.'
    }

    $txtScanStatus.Text = '{0:N0} folders / {1:N0} files' -f $root.FolderCount, $root.FileCount
    Set-Status ('{0} holds {1} in {2:N0} files.{3}' -f `
        $root.FullPath, (Format-Size $root.Size), $root.FileCount, $note)
    Update-DriveInfo
}

function Stop-Scan {
    if ($script:S.Scanner) {
        $script:S.Scanner.Cancel()
        Set-Status 'Stopping scan...'
    }
}

# ---------------------------------------------------------------- delete plumbing

function Start-DeleteJob {
    <#
        Runs a delete on a background thread and polls it from the dispatcher so the
        window stays responsive. OnDone receives the finished WinUtils.Deleter.
    #>
    param(
        [string[]]$Paths,
        [bool]$Recycle,
        [bool]$ContentsOnly,
        [string]$Label,
        [scriptblock]$OnDone
    )

    $clean = @($Paths | Where-Object { $_ } | Select-Object -Unique)
    if ($clean.Count -eq 0) {
        if ($OnDone) { & $OnDone $null }
        return
    }

    $del = New-Object WinUtils.Deleter
    $script:S.Deleter = $del
    $script:S.DelLabel = $Label
    $script:S.DelOnDone = $OnDone

    Set-UiBusy $true
    Set-Status "$Label ..."
    $del.Start($clean, $Recycle, $ContentsOnly)

    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(200)
    $t.Add_Tick({ Update-DeleteProgress })
    $script:S.DelTimer = $t
    $t.Start()
}

function Update-DeleteProgress {
    $d = $script:S.Deleter
    if ($null -eq $d) { return }

    if ($d.IsRunning) {
        Set-Status ('{0} - {1} of {2}, freed {3} so far' -f `
            $script:S.DelLabel, $d.Completed, $d.Total, (Format-Size $d.FreedBytes))
        return
    }

    $script:S.DelTimer.Stop()
    Set-UiBusy $false
    $onDone = $script:S.DelOnDone
    $script:S.DelOnDone = $null
    if ($onDone) { & $onDone $d }
}

function Start-MeasureJob {
    param(
        [System.Collections.Generic.List[WinUtils.CleanupItem]]$Items,
        [scriptblock]$OnProgress,
        [scriptblock]$OnDone
    )

    $m = New-Object WinUtils.BatchMeasurer
    $script:S.Measurer = $m
    $script:S.MeasOnDone = $OnDone
    $script:S.MeasOnProgress = $OnProgress
    $m.Start($Items)

    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(250)
    $t.Add_Tick({ Update-MeasureProgress })
    $script:S.MeasTimer = $t
    $t.Start()
}

function Update-MeasureProgress {
    $m = $script:S.Measurer
    if ($null -eq $m) { return }

    if ($m.IsRunning) {
        if ($script:S.MeasOnProgress) { & $script:S.MeasOnProgress $m }
        return
    }

    $script:S.MeasTimer.Stop()
    $onDone = $script:S.MeasOnDone
    $script:S.MeasOnDone = $null
    if ($onDone) { & $onDone $m }
}

# ---------------------------------------------------------------- folders tab

function Update-SelectedNode {
    $n = $treeFolders.SelectedItem

    if ($null -eq $n) {
        $txtSelName.Text = 'Nothing selected'
        $txtSelPath.Text = ''
        $txtSelSize.Text = '-'
        $txtSelDetail.Text = ''
        $txtSelPct.Text = ''
        $btnOpenFolder.IsEnabled = $false
        $btnCopyPath.IsEnabled = $false
        $btnDeleteFolder.IsEnabled = $false
        return
    }

    $txtSelName.Text = $n.Name
    $txtSelPath.Text = $n.FullPath
    $txtSelSize.Text = $n.SizeText
    $txtSelDetail.Text = $n.Detail
    $txtSelPct.Text = '{0} of the folder above it' -f $n.PercentText

    $btnOpenFolder.IsEnabled = $true
    $btnCopyPath.IsEnabled = $true

    # Never offer to delete a drive root or the synthetic "loose files" row.
    $isRoot = ($null -eq $n.Parent)
    $btnDeleteFolder.IsEnabled = (-not $script:S.Busy) -and (-not $n.IsFilesBucket) -and (-not $isRoot)
}

function Remove-SelectedFolder {
    $n = $treeFolders.SelectedItem
    if ($null -eq $n -or $n.IsFilesBucket -or $null -eq $n.Parent) { return }

    $recycle = [bool]$chkRecycle.IsChecked
    $how = 'PERMANENTLY deleted'
    if ($recycle) { $how = 'moved to the Recycle Bin' }

    $prompt = "This folder and everything inside it will be $how.`n`n" +
              "$($n.FullPath)`n`n" +
              "$($n.SizeText) in $('{0:N0}' -f $n.FileCount) files.`n`nContinue?"
    if (-not (Confirm-Action $prompt 'Delete folder')) { return }

    $script:S.Ctx = @{
        Node        = $n
        SizeBefore  = $n.Size
        FilesBefore = $n.FileCount
    }

    Start-DeleteJob -Paths @($n.FullPath) -Recycle $recycle -ContentsOnly $false `
        -Label 'Deleting folder' -OnDone {
            param($d)
            $ctx = $script:S.Ctx
            $node = $ctx.Node
            $parent = $node.Parent

            $freed = 0; $removed = 0; $errs = @()
            if ($d) { $freed = $d.FreedBytes; $removed = $d.RemovedFiles; $errs = @($d.Errors) }

            if ($freed -ge $ctx.SizeBefore) {
                [void]$parent.Children.Remove($node)
                $parent.ApplyDelta(-$ctx.SizeBefore, -$ctx.FilesBefore)
            }
            else {
                # Partial delete (files in use or protected): keep the row, correct its size.
                $node.ApplyDelta(-$freed, -$removed)
            }

            $tail = 'Done.'
            if ($errs.Count -gt 0) { $tail = "$($errs.Count) item(s) could not be removed." }
            Set-Status ('Freed {0}. {1}' -f (Format-Size $freed), $tail)

            if ($errs.Count -gt 0) {
                Show-Info ("Some items could not be removed. They are usually open in a running program, or protected by Windows:`n`n" +
                    (($errs | Select-Object -First 12) -join "`n")) 'Partly completed'
            }
            Update-SelectedNode
            Update-DriveInfo
        }
}

# ---------------------------------------------------------------- biggest files tab

function Update-FileView {
    $filter = $txtFileFilter.Text.Trim()
    $items = @($script:S.AllFiles)
    if ($filter) { $items = @($items | Where-Object { $_.FullPath -like "*$filter*" }) }

    $lstFiles.ItemsSource = $items
    $txtFilesInfo.Text = '{0:N0} files of 50 MB or more, {1} total' -f $items.Count, (Format-Size (Get-SumBytes $items))
}

function Remove-SelectedFiles {
    $sel = @($lstFiles.SelectedItems)
    if ($sel.Count -eq 0) { return }

    $recycle = [bool]$chkRecycle.IsChecked
    $how = 'PERMANENTLY deleted'
    if ($recycle) { $how = 'moved to the Recycle Bin' }

    $preview = ($sel | Select-Object -First 8 | ForEach-Object { '  ' + $_.FullPath }) -join "`n"
    if ($sel.Count -gt 8) { $preview += "`n  ... and $($sel.Count - 8) more" }

    $prompt = "$($sel.Count) file(s) totalling $(Format-Size (Get-SumBytes $sel)) will be $how.`n`n$preview`n`nContinue?"
    if (-not (Confirm-Action $prompt 'Delete files')) { return }

    $script:S.Ctx = @{ Paths = @($sel | ForEach-Object { $_.FullPath }) }

    Start-DeleteJob -Paths $script:S.Ctx.Paths -Recycle $recycle -ContentsOnly $false `
        -Label 'Deleting files' -OnDone {
            param($d)
            $freed = 0
            if ($d) { $freed = $d.FreedBytes }

            $gone = @{}
            foreach ($p in $script:S.Ctx.Paths) {
                if (-not [System.IO.File]::Exists($p)) { $gone[$p] = $true }
            }
            $script:S.AllFiles = @($script:S.AllFiles | Where-Object { -not $gone.ContainsKey($_.FullPath) })
            Update-FileView
            Set-Status ('Freed {0} by removing {1} file(s).' -f (Format-Size $freed), $gone.Count)
            Update-DriveInfo
        }
}

# ---------------------------------------------------------------- junk tab

function Update-JunkTotals {
    if ($null -eq $script:S.Junk) { return }
    $sel = @($script:S.Junk | Where-Object { $_.Selected -and $_.Deletable })
    $all = @($script:S.Junk | Where-Object { $_.Deletable })
    $txtJunkInfo.Text = 'Ticked {0} across {1} location(s).   {2} reclaimable in total.' -f `
        (Format-Size (Get-SumBytes $sel)), $sel.Count, (Format-Size (Get-SumBytes $all))
}

function Start-JunkMeasure {
    Set-Status 'Looking for junk and cache locations...'
    $script:S.Junk = Get-JunkCatalog
    $lstJunk.ItemsSource = $script:S.Junk
    $btnMeasureJunk.IsEnabled = $false

    Start-MeasureJob -Items $script:S.Junk `
        -OnProgress {
            param($m)
            $txtJunkInfo.Text = 'Measuring {0} of {1} locations...' -f $m.Completed, $m.Total
        } `
        -OnDone {
            param($m)
            $btnMeasureJunk.IsEnabled = $true
            $lstJunk.Items.Refresh()
            Update-JunkTotals
            Set-Status 'Tick the rows you want gone, then press Clean selected. Safe rows are pre-ticked.'
        }
}

function Invoke-JunkClean {
    if ($null -eq $script:S.Junk) { return }

    $sel = @($script:S.Junk | Where-Object { $_.Selected -and $_.Deletable })
    if ($sel.Count -eq 0) {
        Show-Info 'Nothing is ticked. Choose the rows you want cleaned first.'
        return
    }

    $names = ($sel | Select-Object -First 14 | ForEach-Object { '  ' + $_.Name }) -join "`n"
    if ($sel.Count -gt 14) { $names += "`n  ... and $($sel.Count - 14) more" }

    $prompt = "About $(Format-Size (Get-SumBytes $sel)) will be permanently deleted from:`n`n$names`n`n" +
              "These are caches and temporary files, so apps rebuild them when needed. " +
              "Close your browsers first for the best result.`n`nContinue?"
    if (-not (Confirm-Action $prompt 'Clean junk')) { return }

    if (@($sel | Where-Object { $_.SpecialAction -eq 'RecycleBin' }).Count -gt 0) {
        Set-Status 'Emptying the Recycle Bin...'
        [void](Clear-AllRecycleBins)
    }

    $script:S.Ctx = @{
        EmptyPaths  = @($sel | Where-Object { -not $_.DeleteFolderItself -and $_.SpecialAction -ne 'RecycleBin' } |
                              ForEach-Object { $_.Paths })
        RemovePaths = @($sel | Where-Object { $_.DeleteFolderItself } | ForEach-Object { $_.Paths })
        Freed       = [int64]0
        Errors      = @()
    }

    Start-DeleteJob -Paths $script:S.Ctx.EmptyPaths -Recycle $false -ContentsOnly $true `
        -Label 'Clearing caches' -OnDone {
            param($d)
            if ($d) {
                $script:S.Ctx.Freed += $d.FreedBytes
                $script:S.Ctx.Errors += @($d.Errors)
            }

            if ($script:S.Ctx.RemovePaths.Count -gt 0) {
                # Second pass for entries where the folder itself must go (Windows.old).
                Start-DeleteJob -Paths $script:S.Ctx.RemovePaths -Recycle $false -ContentsOnly $false `
                    -Label 'Removing folders' -OnDone {
                        param($d2)
                        if ($d2) {
                            $script:S.Ctx.Freed += $d2.FreedBytes
                            $script:S.Ctx.Errors += @($d2.Errors)
                        }
                        Complete-JunkClean
                    }
            }
            else {
                Complete-JunkClean
            }
        }
}

function Complete-JunkClean {
    $freed = $script:S.Ctx.Freed
    $errs = @($script:S.Ctx.Errors)

    $tail = ''
    if ($errs.Count -gt 0) { $tail = " $($errs.Count) item(s) were in use and left alone." }
    Set-Status ('Reclaimed {0}.{1}' -f (Format-Size $freed), $tail)
    Update-DriveInfo

    if ($errs.Count -gt 0) {
        Show-Info ("Reclaimed $(Format-Size $freed).`n`n" +
            "These were locked by a running program and skipped. Close that app and clean again:`n`n" +
            (($errs | Select-Object -First 12) -join "`n")) 'Cleanup finished'
    }
    else {
        Show-Info "Reclaimed $(Format-Size $freed)." 'Cleanup finished'
    }

    Start-JunkMeasure
}

# ---------------------------------------------------------------- programs tab

function Update-ProgramView {
    if ($null -eq $script:S.Programs) { return }

    $filter = $txtProgFilter.Text.Trim()
    $items = @($script:S.Programs)
    if ($filter) {
        $items = @($items | Where-Object { $_.Name -like "*$filter*" -or $_.Publisher -like "*$filter*" })
    }
    $items = @($items | Sort-Object -Property Size -Descending)

    $lstPrograms.ItemsSource = $items
    $txtProgInfo.Text = '{0} programs, {1} on disk' -f $items.Count, (Format-Size (Get-SumBytes $items))
}

function Update-Programs {
    Set-Status 'Reading the list of installed programs...'
    $script:S.Programs = Get-InstalledPrograms
    Update-ProgramView
    Set-Status 'Biggest first. Anything you do not recognise and never use is a good uninstall candidate.'
}

function Start-ProgramMeasure {
    if ($null -eq $script:S.Programs) { return }

    $targets = @($script:S.Programs | Where-Object {
        $_.InstallLocation -and [System.IO.Directory]::Exists($_.InstallLocation)
    })
    if ($targets.Count -eq 0) {
        Show-Info 'None of the installed programs report a folder that can be measured.'
        return
    }

    # Reuse the batch measurer by wrapping each install folder in a CleanupItem.
    $probes = New-Object 'System.Collections.Generic.List[WinUtils.CleanupItem]'
    $map = @{}
    $i = 0
    foreach ($p in $targets) {
        $c = New-Object WinUtils.CleanupItem
        $c.Id = "p$i"
        $c.Name = $p.Name
        $c.Paths = @($p.InstallLocation)
        $probes.Add($c)
        $map["p$i"] = $p
        $i++
    }
    $script:S.Ctx = @{ Probes = $probes; Map = $map }

    $btnMeasureProgs.IsEnabled = $false
    Set-Status "Measuring $($targets.Count) install folders..."

    Start-MeasureJob -Items $probes `
        -OnProgress {
            param($m)
            $txtProgInfo.Text = 'Measuring {0} of {1}...' -f $m.Completed, $m.Total
        } `
        -OnDone {
            param($m)
            foreach ($c in $script:S.Ctx.Probes) {
                if ($c.Size -gt 0) { $script:S.Ctx.Map[$c.Id].Size = $c.Size }
            }
            $btnMeasureProgs.IsEnabled = $true
            Update-ProgramView
            Set-Status 'Sizes now measured from the install folders rather than what each installer claimed.'
        }
}

function Invoke-Uninstall {
    $p = $lstPrograms.SelectedItem
    if ($null -eq $p) { return }

    if (-not $p.CanUninstall) {
        Show-Info "$($p.Name) does not register an uninstaller. Remove it from Settings, Apps instead."
        return
    }

    $prompt = "Launch the uninstaller for:`n`n$($p.Name)`n$($p.Publisher)`nSize on disk: $($p.SizeText)`n`n" +
              "The program's own uninstaller takes over from here.`n`nContinue?"
    if (-not (Confirm-Action $prompt 'Uninstall')) { return }

    try {
        if (Start-ProgramUninstall -Program $p) {
            Set-Status "Uninstaller launched for $($p.Name). Press Refresh once it has finished."
        } else {
            Show-Info 'No usable uninstall command was found for this entry.'
        }
    } catch {
        Show-Info "Could not start the uninstaller:`n`n$($_.Exception.Message)" 'Uninstall failed'
    }
}

# ---------------------------------------------------------------- column sorting

function Enable-ColumnSort {
    param([System.Windows.Controls.ListView]$List, [hashtable]$HeaderToProperty)

    $script:S.SortMaps[$List.Name] = $HeaderToProperty
    $List.AddHandler(
        [System.Windows.Controls.GridViewColumnHeader]::ClickEvent,
        [System.Windows.RoutedEventHandler]{
            param($listView, $e)

            $header = $e.OriginalSource -as [System.Windows.Controls.GridViewColumnHeader]
            if ($null -eq $header -or $null -eq $header.Content) { return }

            $map = $script:S.SortMaps[$listView.Name]
            if ($null -eq $map) { return }
            $prop = $map[[string]$header.Content]
            if (-not $prop) { return }

            $key = $listView.Name + '|' + $prop
            $descending = $true
            if ($script:S.SortState.ContainsKey($key)) { $descending = -not $script:S.SortState[$key] }
            $script:S.SortState.Clear()
            $script:S.SortState[$key] = $descending

            $listView.ItemsSource = @(@($listView.ItemsSource) | Sort-Object -Property $prop -Descending:$descending)
        })
}

# ---------------------------------------------------------------- event wiring

$btnScan.Add_Click({ Start-Scan })
$btnStop.Add_Click({ Stop-Scan })
$cboDrive.Add_SelectionChanged({ Update-DriveInfo })

$btnElevate.Add_Click({
    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path $psExe)) { $psExe = 'powershell.exe' }
    try {
        Start-Process $psExe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
            '-File', (Join-Path $ScriptRoot 'DiskCleaner.ps1')
        )
        $win.Close()
    } catch {
        Set-Status 'Elevation was cancelled.'
    }
})

$treeFolders.Add_SelectedItemChanged({ Update-SelectedNode })
$btnOpenFolder.Add_Click({
    $n = $treeFolders.SelectedItem
    if ($n) { Open-InExplorer -Path $n.FullPath }
})
$btnCopyPath.Add_Click({
    $n = $treeFolders.SelectedItem
    if ($n) {
        [System.Windows.Clipboard]::SetText($n.FullPath)
        Set-Status "Copied to clipboard: $($n.FullPath)"
    }
})
$btnDeleteFolder.Add_Click({ Remove-SelectedFolder })

$txtFileFilter.Add_TextChanged({ Update-FileView })
$lstFiles.Add_SelectionChanged({
    $c = $lstFiles.SelectedItems.Count
    $btnOpenFileLoc.IsEnabled = ($c -eq 1)
    $btnDeleteFiles.IsEnabled = ($c -gt 0) -and (-not $script:S.Busy)
})
$btnOpenFileLoc.Add_Click({
    $f = $lstFiles.SelectedItem
    if ($f) { Open-InExplorer -Path $f.FullPath -SelectItem }
})
$btnDeleteFiles.Add_Click({ Remove-SelectedFiles })

$btnMeasureJunk.Add_Click({ Start-JunkMeasure })
$btnSelectSafe.Add_Click({
    foreach ($i in $script:S.Junk) {
        if ($i.Deletable -and $i.Risk -eq 'Safe') { $i.Selected = $true }
    }
    Update-JunkTotals
})
$btnSelectNone.Add_Click({
    foreach ($i in $script:S.Junk) { $i.Selected = $false }
    Update-JunkTotals
})
$btnCleanJunk.Add_Click({ Invoke-JunkClean })
$lstJunk.Add_PreviewMouseLeftButtonUp({
    # The checkbox writes straight to the model, so refresh the running total just after.
    $lstJunk.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [action]{ Update-JunkTotals }) | Out-Null
})

$txtProgFilter.Add_TextChanged({ Update-ProgramView })
$btnRefreshProgs.Add_Click({ Update-Programs })
$btnMeasureProgs.Add_Click({ Start-ProgramMeasure })
$btnUninstall.Add_Click({ Invoke-Uninstall })
$lstPrograms.Add_SelectionChanged({
    $btnUninstall.IsEnabled = ($null -ne $lstPrograms.SelectedItem)
})

Enable-ColumnSort -List $lstFiles -HeaderToProperty @{
    'Size' = 'Size'; 'Modified' = 'Modified'; 'Name' = 'Name'; 'Folder' = 'Folder'
}
Enable-ColumnSort -List $lstPrograms -HeaderToProperty @{
    'Size' = 'Size'; 'Program' = 'Name'; 'Publisher' = 'Publisher'
    'Version' = 'Version'; 'Installed' = 'InstallDate'; 'Scope' = 'Scope'
}

$win.Add_Closing({
    if ($script:S.Scanner)  { $script:S.Scanner.Cancel() }
    if ($script:S.Deleter)  { $script:S.Deleter.Cancel() }
    if ($script:S.Measurer) { $script:S.Measurer.Cancel() }
})

$win.Add_ContentRendered({
    Initialize-Drives
    if (-not $script:IsAdmin) { $bannerAdmin.Visibility = 'Visible' }
    Update-Programs
    Start-JunkMeasure
})

[void]$win.ShowDialog()
