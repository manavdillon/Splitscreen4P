#requires -Version 5.1
<#
  BO3 Splitscreen 4P - setup script (install / check / uninstall).

  Players run it through INSTALL.cmd, CHECK.cmd and UNINSTALL.cmd. It can also
  be called directly:

      powershell -ExecutionPolicy Bypass -File splitscreen-setup.ps1 -Action install [-GamePath "D:\...\Call of Duty Black Ops III"] [-NoShortcut]

  What "install" does, in order, and stops at the first thing it cannot fix:
    1. finds the Black Ops III folder (Steam registry + every Steam library,
       or -GamePath, or asks)
    2. checks BlackOps3.exe is the game build the mod is made for
       (PE checksum 0x06531394, Steam build 24784313)
    3. makes sure ezz BOIII 3.0.0 (boiii.exe) is in the game folder - downloads
       it from the ezz GitHub release and verifies its SHA-256 if it is missing
       or older
    4. copies the mod (boiii\plugins\bo3_local_splitscreen.dll and three
       boiii\ui_scripts folders) from the zip this script came in, or from the
       newest GitHub release when run from a source checkout
    5. puts a shortcut on the desktop that starts the game with ezz (-launch)

  Nothing else is touched: no Steam settings, no game files, no registry.
  A log of every run is kept in %LOCALAPPDATA%\BO3-Splitscreen-4P\setup.log.
#>
param(
    [ValidateSet('install', 'check', 'uninstall')]
    [string]$Action = 'install',
    [string]$GamePath = '',
    [switch]$NoShortcut
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Script:ModName          = 'BO3 Splitscreen 4P'
$Script:Repo             = 'manavdillon/BO3-Splitscreen-4P'
$Script:ExpectedChecksum = 0x06531394        # BlackOps3.exe build the mod and ezz 3.0.0 target
$Script:ExpectedBuild    = '24784313'        # Steam build id of that exe
$Script:EzzVersion       = [version]'3.0.0'
$Script:EzzUrl           = 'https://github.com/Ezz-lol/boiii-free/releases/download/v3.0.0/boiii.exe'
$Script:EzzSha256        = 'e6c49cc3ecb145a05f92bd1051ebcafd9b201cf8c522b26308cce18156491a62'
$Script:PluginName       = 'bo3_local_splitscreen.dll'
$Script:UiScripts        = @('zz_mplan', 'zz_splitscreen', 'zz_table_insert')
$Script:ShortcutName     = 'Black Ops III - 4 Player Splitscreen.lnk'
$Script:LogDir           = Join-Path $env:LOCALAPPDATA 'BO3-Splitscreen-4P'
$Script:Failures         = 0
$Script:Warnings         = 0

# --- output ---------------------------------------------------------------------
function Step($text) { Write-Host ''; Write-Host "== $text" -ForegroundColor Cyan }
function Ok($text)   { Write-Host "  [OK]   $text" -ForegroundColor Green }
function Info($text) { Write-Host "         $text" }
function Warn($text) { $Script:Warnings++; Write-Host "  [WARN] $text" -ForegroundColor Yellow }
function Fail($text) { $Script:Failures++; Write-Host "  [FAIL] $text" -ForegroundColor Red }
function Stop-Setup($text) { Fail $text; throw 'SETUP-STOPPED' }

# --- helpers --------------------------------------------------------------------
function Get-PeChecksum([string]$path) {
    $stream = [IO.File]::OpenRead($path)
    try {
        $reader = New-Object IO.BinaryReader($stream)
        $stream.Seek(0x3C, 'Begin') | Out-Null
        $lfanew = $reader.ReadInt32()
        # IMAGE_NT_HEADERS: Signature(4) + FileHeader(20) + OptionalHeader.CheckSum at +64
        $stream.Seek($lfanew + 4 + 20 + 64, 'Begin') | Out-Null
        return $reader.ReadUInt32()
    } finally { $stream.Close() }
}

function Get-Sha256([string]$path) { return (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower() }

function Find-SteamLibraries {
    $roots = @()
    foreach ($key in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try {
            $item = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($name in 'SteamPath', 'InstallPath') { if ($item.$name) { $roots += [string]$item.$name } }
        } catch {}
    }
    $roots += 'C:\Program Files (x86)\Steam'
    $libraries = @()
    foreach ($root in ($roots | Select-Object -Unique)) {
        $root = $root -replace '/', '\'
        if (-not (Test-Path $root)) { continue }
        $libraries += $root
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($match in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libraries += ($match.Groups[1].Value -replace '\\\\', '\')
            }
        }
    }
    return @($libraries | Select-Object -Unique)
}

function Find-GameFolder {
    foreach ($library in Find-SteamLibraries) {
        $installDir = 'Call of Duty Black Ops III'
        $manifest = Join-Path $library 'steamapps\appmanifest_311210.acf'
        if (Test-Path $manifest) {
            $match = [regex]::Match((Get-Content $manifest -Raw), '"installdir"\s+"([^"]+)"')
            if ($match.Success) { $installDir = $match.Groups[1].Value }
        }
        $candidate = Join-Path $library "steamapps\common\$installDir"
        if (Test-Path (Join-Path $candidate 'BlackOps3.exe')) { return $candidate }
    }
    return $null
}

function Get-SteamBuildId([string]$game) {
    foreach ($library in Find-SteamLibraries) {
        $manifest = Join-Path $library 'steamapps\appmanifest_311210.acf'
        if (-not (Test-Path $manifest)) { continue }
        $match = [regex]::Match((Get-Content $manifest -Raw), '"buildid"\s+"(\d+)"')
        if ($match.Success) { return $match.Groups[1].Value }
    }
    return $null
}

function Resolve-GameFolder {
    Step 'Black Ops III folder'
    $game = $null
    if ($GamePath) {
        $game = $GamePath.TrimEnd('\', '"')
        if (-not (Test-Path (Join-Path $game 'BlackOps3.exe'))) { Stop-Setup "No BlackOps3.exe in the folder you gave: $game" }
        Ok "Given: $game"
    } else {
        $game = Find-GameFolder
        if ($game) {
            Ok "Found through Steam: $game"
        } else {
            Warn 'Steam does not list Black Ops III on this PC.'
            if ($Host.Name -ne 'ConsoleHost') { Stop-Setup 'Run INSTALL.cmd "<your Black Ops III folder>" with the folder that contains BlackOps3.exe.' }
            $typed = Read-Host '  Type (or paste) the folder that contains BlackOps3.exe, then press Enter'
            $typed = $typed.Trim().Trim('"')
            if (-not $typed -or -not (Test-Path (Join-Path $typed 'BlackOps3.exe'))) { Stop-Setup "No BlackOps3.exe in: $typed" }
            $game = $typed
            Ok "Using: $game"
        }
    }
    return (Resolve-Path $game).Path
}

function Test-GameBuild([string]$game) {
    Step 'Game version'
    $exe = Join-Path $game 'BlackOps3.exe'
    $checksum = Get-PeChecksum $exe
    $build = Get-SteamBuildId $game
    $buildText = ''
    if ($build) { $buildText = " (Steam build $build)" }
    if ($checksum -eq $Script:ExpectedChecksum) {
        Ok ("BlackOps3.exe is the build the mod is made for: checksum 0x{0:X8}{1}" -f $checksum, $buildText)
        return $true
    }
    Warn ("BlackOps3.exe is a different build: checksum 0x{0:X8}{1}, expected 0x{2:X8} (Steam build {3})." -f $checksum, $buildText, $Script:ExpectedChecksum, $Script:ExpectedBuild)
    Info 'ezz BOIII checks this on every start. When the exe is newer (Steam updated the game), ezz'
    Info 'offers to download the compatible BlackOps3.exe itself - press OK in that dialog, then the'
    Info 'mod works. Until then the mod stays switched off and the game runs unmodified.'
    return $false
}

function Get-EzzVersion([string]$exe) {
    try {
        $info = (Get-Item $exe).VersionInfo
        if ($info.ProductVersion -match '^(\d+)\.(\d+)\.(\d+)') { return [version]$matches[0] }
    } catch {}
    return $null
}

function Install-Ezz([string]$game) {
    Step 'ezz BOIII client'
    $exe = Join-Path $game 'boiii.exe'
    $needDownload = $true
    if (Test-Path $exe) {
        $version = Get-EzzVersion $exe
        if ($version -and $version -ge $Script:EzzVersion) {
            if ($version -eq $Script:EzzVersion) { Ok "boiii.exe $version is installed (the version the mod is tested with)." }
            else { Warn "boiii.exe $version is newer than the tested $($Script:EzzVersion). If the mod stays off in the game, put boiii.exe $($Script:EzzVersion) in the folder (INSTALL.cmd does not downgrade)." }
            $needDownload = $false
        } elseif ($version) {
            Warn "boiii.exe $version is older than the required $($Script:EzzVersion) - replacing it (a copy stays as boiii.exe.bak)."
        } else {
            Warn 'boiii.exe is there but has no readable version - replacing it (a copy stays as boiii.exe.bak).'
        }
    } else {
        Info 'boiii.exe is not in the game folder yet.'
    }
    if (-not $needDownload) { return }

    Info "Downloading ezz BOIII $($Script:EzzVersion) from GitHub (6 MB)..."
    $tmp = Join-Path $env:TEMP "boiii-$([guid]::NewGuid().ToString('N')).exe"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Script:EzzUrl -OutFile $tmp
    } catch {
        Stop-Setup "Download failed: $($_.Exception.Message)`n         Download it yourself from https://github.com/Ezz-lol/boiii-free/releases/tag/v3.0.0 and put boiii.exe into $game, then run INSTALL.cmd again."
    }
    $hash = Get-Sha256 $tmp
    if ($hash -ne $Script:EzzSha256) {
        Remove-Item $tmp -Force
        Stop-Setup "The downloaded boiii.exe does not match the known SHA-256 (got $hash). Not installed."
    }
    if (Test-Path $exe) { Copy-Item $exe "$exe.bak" -Force }
    Move-Item $tmp $exe -Force
    Unblock-File $exe -ErrorAction SilentlyContinue
    Ok "boiii.exe $($Script:EzzVersion) installed (SHA-256 verified)."
    Info 'On its first start ezz BOIII sets itself up; that is ezz, not this mod.'
}

function Get-Payload {
    # 1. the zip this script came in: <zip root>\boiii\...
    $local = Join-Path (Split-Path $PSScriptRoot -Parent) 'boiii'
    if (Test-Path (Join-Path $local "plugins\$($Script:PluginName)")) {
        $sums = Join-Path (Split-Path $PSScriptRoot -Parent) 'SHA256SUMS.txt'
        if (Test-Path $sums) {
            foreach ($line in Get-Content $sums) {
                if ($line -match '^([0-9a-f]{64}) \*(boiii/.+)$') {
                    $file = Join-Path (Split-Path $PSScriptRoot -Parent) ($matches[2] -replace '/', '\')
                    if (-not (Test-Path $file)) { Stop-Setup "The zip is incomplete: $($matches[2]) is missing. Extract the whole zip and run INSTALL.cmd again." }
                    if ((Get-Sha256 $file) -ne $matches[1]) { Stop-Setup "$($matches[2]) does not match SHA256SUMS.txt - the download is damaged. Download the zip again." }
                }
            }
            Ok 'Mod files found next to this script, SHA-256 verified.'
        } else {
            Ok 'Mod files found next to this script.'
        }
        return $local
    }

    # 2. a source checkout: fetch the newest release zip
    Info "No mod files next to this script - fetching the newest release of $($Script:Repo)..."
    $api = "https://api.github.com/repos/$($Script:Repo)/releases/latest"
    try {
        $release = Invoke-RestMethod -UseBasicParsing -Uri $api -Headers @{ 'User-Agent' = 'BO3-Splitscreen-4P-setup'; 'Accept' = 'application/vnd.github+json' }
    } catch {
        Stop-Setup "Could not read the release list: $($_.Exception.Message)`n         Download the zip from https://github.com/$($Script:Repo)/releases and run its INSTALL.cmd."
    }
    $asset = $release.assets | Where-Object { $_.name -like 'BO3-Splitscreen-4P-*.zip' } | Select-Object -First 1
    if (-not $asset) { Stop-Setup "Release $($release.tag_name) has no BO3-Splitscreen-4P zip." }
    $dir = Join-Path $env:TEMP "BO3-Splitscreen-4P-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force $dir | Out-Null
    $zip = Join-Path $dir $asset.name
    Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $dir -Force
    if (-not (Test-Path (Join-Path $dir "boiii\plugins\$($Script:PluginName)"))) { Stop-Setup "The release zip $($asset.name) has no boiii\plugins\$($Script:PluginName)." }
    Ok "Downloaded $($asset.name) (release $($release.tag_name))."
    return (Join-Path $dir 'boiii')
}

function Install-Mod([string]$game) {
    Step 'Mod files'
    $payload = Get-Payload
    $target = Join-Path $game 'boiii'
    New-Item -ItemType Directory -Force (Join-Path $target 'plugins'), (Join-Path $target 'ui_scripts') | Out-Null

    $dll = Join-Path $target "plugins\$($Script:PluginName)"
    Copy-Item (Join-Path $payload "plugins\$($Script:PluginName)") $dll -Force
    Unblock-File $dll -ErrorAction SilentlyContinue
    Ok "boiii\plugins\$($Script:PluginName)"

    foreach ($script in $Script:UiScripts) {
        $src = Join-Path $payload "ui_scripts\$script"
        $dst = Join-Path $target "ui_scripts\$script"
        if (-not (Test-Path $src)) { Stop-Setup "ui_scripts\$script is missing from the mod files." }
        if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
        Copy-Item $src $dst -Recurse -Force
        Get-ChildItem $dst -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
        Ok "boiii\ui_scripts\$script"
    }

    # leftovers of mod version 2.0 (a proxy DLL next to the game) would start first and win
    $legacy = Join-Path $game 'XINPUT9_1_0.dll'
    if (Test-Path $legacy) {
        Rename-Item $legacy 'XINPUT9_1_0.dll.old-splitscreen-2.0' -Force
        Warn 'An old XINPUT9_1_0.dll (mod 2.0) was in the game folder; renamed to XINPUT9_1_0.dll.old-splitscreen-2.0.'
    }
    $duplicate = Join-Path $env:LOCALAPPDATA "boiii\plugins\$($Script:PluginName)"
    if (Test-Path $duplicate) {
        Warn "A second copy of the plugin is in $duplicate - ezz loads both. Delete that one."
    }
}

function Install-Shortcut([string]$game) {
    Step 'Desktop shortcut'
    if ($NoShortcut) { Info 'Skipped (-NoShortcut).'; return }
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $path = Join-Path $desktop $Script:ShortcutName
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($path)
        $link.TargetPath = Join-Path $game 'boiii.exe'
        $link.Arguments = '-launch'
        $link.WorkingDirectory = $game
        $link.IconLocation = (Join-Path $game 'boiii.exe') + ',0'
        $link.Description = 'Start Black Ops III with ezz BOIII and the 4-player splitscreen mod'
        $link.Save()
        Ok "$($Script:ShortcutName) on the desktop (boiii.exe -launch)"
    } catch {
        Warn "Could not create the shortcut: $($_.Exception.Message). Start boiii.exe in the game folder instead."
    }
}

function Show-PlayGuide {
    Step 'How to play'
    Info '1. Connect the controllers (Xbox or PlayStation). Steam Input must be ON for Black Ops III'
    Info '   (Steam default). Connect all pads before players join.'
    Info '2. Start the game with the desktop shortcut (or boiii.exe in the game folder).'
    Info '3. Main menu: PLAY OFFLINE, then ZOMBIES or MULTIPLAYER (bots work).'
    Info '4. In the lobby every extra player presses A on their controller to join; B leaves.'
    Info '5. Start the match: 3 players = 3 screens, 4 players = 2 x 2.'
    Info ''
    Info 'Players 3 and 4 can only join offline lobbies (the online lobby allows two per PC).'
    Info 'Prefer the Steam Play button? Right-click the game in Steam > Properties > Launch Options:'
    Info '   "<game folder>\boiii.exe" -launch %command%'
}

# --- check ----------------------------------------------------------------------
function Test-Installation([string]$game) {
    Test-GameBuild $game | Out-Null

    Step 'ezz BOIII client'
    $exe = Join-Path $game 'boiii.exe'
    if (Test-Path $exe) {
        $version = Get-EzzVersion $exe
        if ($version -eq $Script:EzzVersion) { Ok "boiii.exe $version" }
        elseif ($version -and $version -gt $Script:EzzVersion) { Warn "boiii.exe $version (tested with $($Script:EzzVersion))" }
        else { Fail "boiii.exe is missing a version or older than $($Script:EzzVersion) - run INSTALL.cmd" }
    } else { Fail 'boiii.exe is not in the game folder - run INSTALL.cmd' }

    Step 'Mod files'
    $dll = Join-Path $game "boiii\plugins\$($Script:PluginName)"
    if (Test-Path $dll) { Ok ("boiii\plugins\{0} ({1:N0} bytes, {2})" -f $Script:PluginName, (Get-Item $dll).Length, (Get-Item $dll).LastWriteTime.ToString('yyyy-MM-dd')) }
    else { Fail "boiii\plugins\$($Script:PluginName) is missing - run INSTALL.cmd" }
    foreach ($script in $Script:UiScripts) {
        $lua = Join-Path $game "boiii\ui_scripts\$script\__init__.lua"
        if (Test-Path $lua) { Ok "boiii\ui_scripts\$script" } else { Fail "boiii\ui_scripts\$script\__init__.lua is missing - run INSTALL.cmd" }
    }
    if (Test-Path (Join-Path $game 'XINPUT9_1_0.dll')) { Fail 'XINPUT9_1_0.dll (mod 2.0) is in the game folder and would block the plugin - run INSTALL.cmd' }
    $duplicate = Join-Path $env:LOCALAPPDATA "boiii\plugins\$($Script:PluginName)"
    if (Test-Path $duplicate) { Warn "a second copy of the plugin is in $duplicate" }

    Step 'Last game start'
    $log = Join-Path $game 'boiii_players\plugins.log'
    if (Test-Path $log) {
        $text = Get-Content $log -Raw
        if ($text -match 'Loaded: BO3 Local Splitscreen') { Ok 'ezz loaded the plugin on the last start (boiii_players\plugins.log)' }
        elseif ($text -match 'noplugins') { Fail 'the last start used -noplugins, which switches every plugin off' }
        elseif ($text -match 'Failed to load') { Fail "ezz could not load a plugin on the last start: $(($text -split "`n" | Where-Object { $_ -match 'Failed' }) -join '; ')" }
        else { Warn 'the last start did not load the plugin (was it installed after that start?)' }
    } else { Info 'the game has not been started with ezz BOIII yet (no boiii_players\plugins.log)' }
    $dumps = Join-Path $env:LOCALAPPDATA 'boiii\minidumps'
    if (Test-Path $dumps) {
        $recent = Get-ChildItem $dumps -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($recent) { Info "newest crash file: $($recent.FullName) ($($recent.LastWriteTime)) - attach it when reporting a problem" }
    }

    Step 'Controllers'
    try {
        $pads = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.Name -match 'Xbox|Gamepad|Game Controller|Wireless Controller|DualSense|DualShock|XINPUT' } | Select-Object -ExpandProperty Name -Unique)
        if ($pads.Count -gt 0) { Ok "$($pads.Count) controller device(s) seen by Windows: $($pads -join ', ')" }
        else { Info 'no controller is connected right now (connect them before the players join)' }
    } catch { Info 'could not list controllers' }
    Info 'Steam Input must be ON for Black Ops III (Steam > game > Properties > Controller), or the game sees no pad.'
}

# --- uninstall ------------------------------------------------------------------
function Uninstall-Mod([string]$game) {
    Step 'Removing the mod'
    $dll = Join-Path $game "boiii\plugins\$($Script:PluginName)"
    if (Test-Path $dll) { Remove-Item $dll -Force; Ok "removed boiii\plugins\$($Script:PluginName)" } else { Info "boiii\plugins\$($Script:PluginName) was not there" }
    foreach ($script in $Script:UiScripts) {
        $dir = Join-Path $game "boiii\ui_scripts\$script"
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force; Ok "removed boiii\ui_scripts\$script" }
    }
    $shortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) $Script:ShortcutName
    if (Test-Path $shortcut) { Remove-Item $shortcut -Force; Ok 'removed the desktop shortcut' }
    Info 'ezz BOIII (boiii.exe) and the game stay. To remove ezz too, delete boiii.exe from the game folder.'
}

# --- main -----------------------------------------------------------------------
New-Item -ItemType Directory -Force $Script:LogDir | Out-Null
$logFile = Join-Path $Script:LogDir 'setup.log'
try { Start-Transcript -Path $logFile -Append | Out-Null } catch {}

Write-Host ''
Write-Host "$($Script:ModName) setup - $Action" -ForegroundColor White
Write-Host "(log: $logFile)"

$exitCode = 0
try {
    $game = Resolve-GameFolder
    switch ($Action) {
        'install' {
            Test-GameBuild $game | Out-Null
            Install-Ezz $game
            Install-Mod $game
            Install-Shortcut $game
            Show-PlayGuide
        }
        'check'     { Test-Installation $game }
        'uninstall' { Uninstall-Mod $game }
    }
} catch {
    if ($_.Exception.Message -ne 'SETUP-STOPPED') { Fail "Unexpected error: $($_.Exception.Message)" }
}

Write-Host ''
if ($Script:Failures -gt 0) {
    Write-Host "$Action did NOT finish: $($Script:Failures) problem(s) above." -ForegroundColor Red
    $exitCode = 1
} elseif ($Script:Warnings -gt 0) {
    Write-Host "$Action finished with $($Script:Warnings) note(s) above." -ForegroundColor Yellow
} else {
    Write-Host "$Action finished." -ForegroundColor Green
}
try { Stop-Transcript | Out-Null } catch {}
exit $exitCode
