# WinUtils Disk Cleaner - cleanup catalog and installed-program enumeration.
# Dot-sourced by DiskCleaner.ps1.

function Resolve-CleanPaths {
    <#
        Expands environment variables and wildcards into concrete existing paths.
        Existence is tested with .NET so that folders we can see but not read
        (for example C:\Windows\Temp without elevation) are still listed.
    #>
    param([string[]]$Patterns)

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables($pattern)

        if ($expanded -match '[\*\?]') {
            try {
                foreach ($m in Get-Item -Path $expanded -Force -ErrorAction SilentlyContinue) {
                    $out.Add($m.FullName)
                }
            } catch { }
        }
        elseif ([System.IO.Directory]::Exists($expanded) -or [System.IO.File]::Exists($expanded)) {
            $out.Add($expanded)
        }
    }
    , ($out.ToArray())
}

function New-CleanupItem {
    param(
        [string]$Id,
        [string]$Name,
        [string]$Description,
        [string[]]$Patterns,
        [string]$Risk = 'Safe',
        [bool]$Deletable = $true,
        [bool]$DeleteFolderItself = $false,
        [string]$SpecialAction = '',
        [string]$Hint = '',
        [bool]$DefaultSelected = $false
    )

    $paths = Resolve-CleanPaths -Patterns $Patterns
    if ($paths.Count -eq 0 -and $SpecialAction -eq '') { return $null }

    $item = New-Object WinUtils.CleanupItem
    $item.Id = $Id
    $item.Name = $Name
    $item.Description = $Description
    $item.Risk = $Risk
    $item.Paths = $paths
    $item.Deletable = $Deletable
    $item.DeleteFolderItself = $DeleteFolderItself
    $item.SpecialAction = $SpecialAction
    $item.Hint = $Hint
    $item.Selected = ($DefaultSelected -and $Deletable)
    return $item
}

function Get-JunkCatalog {
    <# Returns List[WinUtils.CleanupItem] for every junk location present on this machine. #>

    $defs = @(
        # ---------- Safe, selected by default ----------
        @{ Id='user-temp'; Name='Your temp files'; Risk='Safe'; Sel=$true
           P=@('%TEMP%','%LOCALAPPDATA%\Temp')
           D='Scratch files left behind by apps and installers. Windows and apps recreate these on demand.' }

        @{ Id='windows-temp'; Name='Windows temp files'; Risk='Safe'; Sel=$true
           P=@('%SystemRoot%\Temp')
           D='System-wide scratch folder. Requires Administrator to clear fully.' }

        @{ Id='recycle-bin'; Name='Recycle Bin'; Risk='Safe'; Sel=$true; Special='RecycleBin'
           P=@('%SystemDrive%\$Recycle.Bin')
           D='Files you already deleted. Space is not actually reclaimed until this is emptied.' }

        @{ Id='windows-update'; Name='Windows Update cache'; Risk='Safe'; Sel=$true
           P=@('%SystemRoot%\SoftwareDistribution\Download')
           D='Installer payloads for updates that are already applied. Often several GB. Requires Administrator.' }

        @{ Id='delivery-opt'; Name='Delivery Optimization cache'; Risk='Safe'; Sel=$true
           P=@('%SystemRoot%\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization')
           D='Update chunks Windows keeps to share with other PCs on your network. Safe to clear.' }

        @{ Id='wer'; Name='Error reporting archives'; Risk='Safe'; Sel=$true
           P=@('%LOCALAPPDATA%\Microsoft\Windows\WER','%ProgramData%\Microsoft\Windows\WER')
           D='Queued crash reports for Microsoft. Nothing depends on them.' }

        @{ Id='crash-dumps'; Name='Crash dumps'; Risk='Safe'; Sel=$true
           P=@('%LOCALAPPDATA%\CrashDumps','%SystemRoot%\Minidump','%SystemRoot%\MEMORY.DMP','%SystemRoot%\LiveKernelReports')
           D='Memory snapshots written after a crash or bluescreen. A full MEMORY.DMP can be many GB.' }

        @{ Id='inet-cache'; Name='Windows internet cache'; Risk='Safe'; Sel=$true
           P=@('%LOCALAPPDATA%\Microsoft\Windows\INetCache','%LOCALAPPDATA%\Microsoft\Windows\INetCookies')
           D='Cached web content used by system components and older Internet Explorer plumbing.' }

        @{ Id='thumb-cache'; Name='Thumbnail and icon cache'; Risk='Safe'; Sel=$true
           P=@('%LOCALAPPDATA%\Microsoft\Windows\Explorer\thumbcache_*.db','%LOCALAPPDATA%\Microsoft\Windows\Explorer\iconcache_*.db')
           D='Explorer preview images. Rebuilt automatically. Some files stay locked while Explorer is running.' }

        @{ Id='win-logs'; Name='Windows servicing logs'; Risk='Safe'; Sel=$true
           P=@('%SystemRoot%\Logs\CBS','%SystemRoot%\Logs\DISM','%SystemRoot%\Logs\WindowsUpdate','%SystemRoot%\Logs\MoSetup')
           D='Text logs from update and component servicing. Only useful when debugging a failed update.' }

        # ---------- Browser caches ----------
        @{ Id='edge-cache'; Name='Microsoft Edge cache'; Risk='Safe'; Sel=$true
           P=@('%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Cache','%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Code Cache','%LOCALAPPDATA%\Microsoft\Edge\User Data\*\GPUCache','%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Service Worker\CacheStorage')
           D='Cached pages and scripts. Your history, passwords and bookmarks are not touched. Close Edge first.' }

        @{ Id='chrome-cache'; Name='Google Chrome cache'; Risk='Safe'; Sel=$true
           P=@('%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache','%LOCALAPPDATA%\Google\Chrome\User Data\*\Code Cache','%LOCALAPPDATA%\Google\Chrome\User Data\*\GPUCache','%LOCALAPPDATA%\Google\Chrome\User Data\*\Service Worker\CacheStorage')
           D='Cached pages and scripts. Your history, passwords and bookmarks are not touched. Close Chrome first.' }

        @{ Id='brave-cache'; Name='Brave cache'; Risk='Safe'; Sel=$true
           P=@('%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\Cache','%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\Code Cache','%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\GPUCache')
           D='Cached pages and scripts. Close Brave first.' }

        @{ Id='firefox-cache'; Name='Firefox cache'; Risk='Safe'; Sel=$true
           P=@('%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2','%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\startupCache')
           D='Cached pages and scripts. Close Firefox first.' }

        # ---------- App caches ----------
        @{ Id='vscode-cache'; Name='VS Code caches'; Risk='Safe'; Sel=$true
           P=@('%APPDATA%\Code\Cache','%APPDATA%\Code\CachedData','%APPDATA%\Code\CachedExtensionVSIXs','%APPDATA%\Code\Code Cache','%APPDATA%\Code\GPUCache','%APPDATA%\Code\logs')
           D='Editor caches and old version payloads. Rebuilt on next launch.' }

        @{ Id='teams-cache'; Name='Teams cache'; Risk='Safe'; Sel=$true
           P=@('%APPDATA%\Microsoft\Teams\Cache','%APPDATA%\Microsoft\Teams\Code Cache','%APPDATA%\Microsoft\Teams\GPUCache','%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\PerfLogs')
           D='Teams message and media cache. Rebuilt after sign-in.' }

        @{ Id='discord-cache'; Name='Discord cache'; Risk='Safe'; Sel=$true
           P=@('%APPDATA%\discord\Cache','%APPDATA%\discord\Code Cache','%APPDATA%\discord\GPUCache')
           D='Cached images and attachments. Rebuilt automatically.' }

        @{ Id='spotify-cache'; Name='Spotify cache'; Risk='Safe'; Sel=$false
           P=@('%LOCALAPPDATA%\Spotify\Data','%LOCALAPPDATA%\Spotify\Storage')
           D='Cached audio for streamed tracks. Clearing means re-streaming, but offline downloads live elsewhere.' }

        @{ Id='nvidia-cache'; Name='GPU shader caches'; Risk='Safe'; Sel=$true
           P=@('%LOCALAPPDATA%\NVIDIA\DXCache','%LOCALAPPDATA%\NVIDIA\GLCache','%LOCALAPPDATA%\NVIDIA Corporation\NV_Cache','%LOCALAPPDATA%\AMD\DxCache','%LOCALAPPDATA%\D3DSCache')
           D='Compiled graphics shaders. Games rebuild them, with a brief stutter the first time.' }

        @{ Id='installer-temp'; Name='Leftover installer payloads'; Risk='Safe'; Sel=$true
           P=@('%LOCALAPPDATA%\Downloaded Installations','%LOCALAPPDATA%\Package Cache\*\*.msi','%ProgramData%\Package Cache\.unverified')
           D='Extracted setup files kept after installs completed.' }

        # ---------- Developer caches ----------
        @{ Id='npm-cache'; Name='npm cache'; Risk='Safe'; Sel=$false
           P=@('%APPDATA%\npm-cache\_cacache','%LOCALAPPDATA%\npm-cache\_cacache')
           D='Downloaded npm packages. Safe to delete; npm re-downloads on the next install.' }

        @{ Id='nuget-cache'; Name='NuGet package cache'; Risk='Review'; Sel=$false
           P=@('%USERPROFILE%\.nuget\packages','%LOCALAPPDATA%\NuGet\v3-cache')
           D='Restored .NET packages. Deleting forces a re-download on the next build, which needs internet.' }

        @{ Id='pip-cache'; Name='pip cache'; Risk='Safe'; Sel=$false
           P=@('%LOCALAPPDATA%\pip\Cache')
           D='Downloaded Python wheels. Re-downloaded on demand.' }

        @{ Id='yarn-pnpm-cache'; Name='Yarn / pnpm cache'; Risk='Safe'; Sel=$false
           P=@('%LOCALAPPDATA%\Yarn\Cache','%LOCALAPPDATA%\pnpm\store','%LOCALAPPDATA%\pnpm-store')
           D='Downloaded JavaScript packages. Re-downloaded on demand.' }

        @{ Id='gradle-maven-cache'; Name='Gradle / Maven cache'; Risk='Review'; Sel=$false
           P=@('%USERPROFILE%\.gradle\caches','%USERPROFILE%\.m2\repository')
           D='Downloaded Java dependencies. Often very large. Rebuilt on next build, which needs internet.' }

        @{ Id='vs-cache'; Name='Visual Studio caches'; Risk='Safe'; Sel=$false
           P=@('%LOCALAPPDATA%\Microsoft\VisualStudio\*\ComponentModelCache','%LOCALAPPDATA%\Microsoft\VisualStudio\Packages\_Instances','%LOCALAPPDATA%\Microsoft\VSApplicationInsights')
           D='MEF and telemetry caches. Rebuilt when Visual Studio next starts.' }

        @{ Id='docker-cache'; Name='Docker / WSL log files'; Risk='Safe'; Sel=$false
           P=@('%LOCALAPPDATA%\Docker\log','%LOCALAPPDATA%\Docker\wsl\log')
           D='Docker Desktop diagnostic logs. Note that images and volumes are not touched here.' }

        # ---------- Needs a decision ----------
        @{ Id='prefetch'; Name='Prefetch data'; Risk='Review'; Sel=$false
           P=@('%SystemRoot%\Prefetch')
           D='Launch-optimisation data. Clearing frees little and makes the next launch of each app slightly slower.' }

        @{ Id='windows-old'; Name='Previous Windows installation'; Risk='Review'; Sel=$false; Folder=$true
           P=@('%SystemDrive%\Windows.old','%SystemDrive%\$WINDOWS.~BT','%SystemDrive%\$WINDOWS.~WS')
           D='Your old Windows install kept for rollback. Usually 10-30 GB. Deleting means you cannot roll back the upgrade.' }

        @{ Id='store-cache'; Name='Store app local caches'; Risk='Review'; Sel=$false
           P=@('%LOCALAPPDATA%\Packages\*\LocalCache')
           D='Per-app cache folders for Store apps. Mostly safe, but a few apps keep recoverable data here.' }

        # ---------- Information only ----------
        @{ Id='downloads'; Name='Downloads folder'; Risk='Info'; Del=$false
           P=@('%USERPROFILE%\Downloads')
           D='Very often the single biggest pile of reclaimable space. Sort by size and delete old installers yourself.'
           Hint='open and review' }

        @{ Id='hiberfil'; Name='Hibernation file'; Risk='Info'; Del=$false
           P=@('%SystemDrive%\hiberfil.sys')
           D='Reserved for hibernate and fast startup. Reclaim it from an admin prompt with:  powercfg /h off'
           Hint='powercfg /h off' }

        @{ Id='pagefile'; Name='Page and swap files'; Risk='Info'; Del=$false
           P=@('%SystemDrive%\pagefile.sys','%SystemDrive%\swapfile.sys')
           D='Virtual memory managed by Windows. Resize under System Properties, Advanced, Performance.'
           Hint='managed by Windows' }

        @{ Id='winsxs'; Name='Component store (WinSxS)'; Risk='Info'; Del=$false
           P=@('%SystemRoot%\WinSxS')
           D='Windows component store. Never delete directly. Shrink it from an admin prompt with:  DISM /Online /Cleanup-Image /StartComponentCleanup'
           Hint='use DISM cleanup' }

        @{ Id='restore-points'; Name='System restore and shadow copies'; Risk='Info'; Del=$false
           P=@('%SystemDrive%\System Volume Information')
           D='Restore points and volume snapshots. Adjust the space cap under System Protection.'
           Hint='use System Protection' }
    )

    $list = New-Object 'System.Collections.Generic.List[WinUtils.CleanupItem]'
    foreach ($d in $defs) {
        $item = New-CleanupItem `
            -Id $d.Id -Name $d.Name -Description $d.D -Patterns $d.P -Risk $d.Risk `
            -Deletable $(if ($d.ContainsKey('Del')) { [bool]$d.Del } else { $true }) `
            -DeleteFolderItself $(if ($d.ContainsKey('Folder')) { [bool]$d.Folder } else { $false }) `
            -SpecialAction $(if ($d.ContainsKey('Special')) { [string]$d.Special } else { '' }) `
            -Hint $(if ($d.ContainsKey('Hint')) { [string]$d.Hint } else { '' }) `
            -DefaultSelected $(if ($d.ContainsKey('Sel')) { [bool]$d.Sel } else { $false })

        if ($null -ne $item) { $list.Add($item) }
    }
    return , $list
}

function Clear-AllRecycleBins {
    <# Empties the Recycle Bin on every ready fixed drive. #>
    $errors = New-Object System.Collections.Generic.List[string]
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
    } catch {
        # Nothing to empty raises a non-fatal error; anything else is worth surfacing.
        $msg = $_.Exception.Message
        if ($msg -notmatch 'empty|not.*found|0x8000FFFF') { $errors.Add("Recycle Bin -- $msg") }
    }
    , ($errors.ToArray())
}

function Get-InstalledPrograms {
    <# Reads the uninstall registry for all three scopes and returns List[WinUtils.ProgramItem]. #>

    $roots = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';            Scope = 'Machine' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'Machine 32' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';            Scope = 'User' }
    )

    $list = New-Object 'System.Collections.Generic.List[WinUtils.ProgramItem]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($root in $roots) {
        if (-not (Test-Path $root.Path)) { continue }

        foreach ($key in (Get-ChildItem $root.Path -ErrorAction SilentlyContinue)) {
            try { $p = Get-ItemProperty $key.PSPath -ErrorAction Stop } catch { continue }

            $name = if ($p.PSObject.Properties['DisplayName']) { [string]$p.DisplayName } else { '' }
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            # Skip hidden components, patches and per-update child entries.
            if ($p.PSObject.Properties['SystemComponent'] -and $p.SystemComponent -eq 1) { continue }
            if ($p.PSObject.Properties['ParentKeyName'] -and $p.ParentKeyName) { continue }
            if ($p.PSObject.Properties['ReleaseType'] -and $p.ReleaseType -match 'Update|Hotfix|Security') { continue }
            if ($name -match '^(KB\d{6,}|Update for |Security Update for |Hotfix for )') { continue }

            $version = if ($p.PSObject.Properties['DisplayVersion']) { [string]$p.DisplayVersion } else { '' }
            if (-not $seen.Add(($name + '|' + $version + '|' + $root.Scope))) { continue }

            $item = New-Object WinUtils.ProgramItem
            $item.Name = $name
            $item.Version = $version
            $item.Scope = $root.Scope
            $item.RegistryKey = $key.PSPath

            if ($p.PSObject.Properties['Publisher'])          { $item.Publisher = [string]$p.Publisher }
            if ($p.PSObject.Properties['InstallLocation'])    { $item.InstallLocation = [string]$p.InstallLocation }
            if ($p.PSObject.Properties['UninstallString'])    { $item.UninstallString = [string]$p.UninstallString }
            if ($p.PSObject.Properties['QuietUninstallString']) { $item.QuietUninstallString = [string]$p.QuietUninstallString }

            if ($p.PSObject.Properties['EstimatedSize'] -and $p.EstimatedSize) {
                $item.Size = [int64]$p.EstimatedSize * 1024L
            }

            if ($p.PSObject.Properties['InstallDate'] -and $p.InstallDate -match '^\d{8}$') {
                $d = [string]$p.InstallDate
                $item.InstallDate = '{0}-{1}-{2}' -f $d.Substring(0,4), $d.Substring(4,2), $d.Substring(6,2)
            }

            $list.Add($item)
        }
    }

    return , $list
}

function Start-ProgramUninstall {
    <# Launches a program's own uninstaller. Returns $true when a process was started. #>
    param([WinUtils.ProgramItem]$Program)

    $cmd = if ($Program.QuietUninstallString) { $Program.QuietUninstallString } else { $Program.UninstallString }
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }

    # MsiExec entries are reliable enough to rewrite into an interactive uninstall.
    if ($cmd -match '(?i)msiexec') {
        if ($cmd -match '\{[0-9A-Fa-f\-]{36}\}') {
            Start-Process 'msiexec.exe' -ArgumentList @('/x', $Matches[0]) | Out-Null
            return $true
        }
    }

    $exe = $null
    $argLine = ''
    if ($cmd -match '^\s*"([^"]+)"\s*(.*)$') {
        $exe = $Matches[1]; $argLine = $Matches[2]
    }
    elseif ($cmd -match '^\s*(\S+\.exe)\s*(.*)$') {
        $exe = $Matches[1]; $argLine = $Matches[2]
    }
    else {
        $exe = $cmd.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($argLine)) { Start-Process -FilePath $exe | Out-Null }
    else { Start-Process -FilePath $exe -ArgumentList $argLine | Out-Null }
    return $true
}
