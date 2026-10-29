#requires -Version 5.1
<#
.SYNOPSIS
  Builds bo3_local_splitscreen.dll from src\, runs the offline smoke test and
  packages the release zip (dist\Splitscreen4P-<version>.zip).

  Works on a developer PC with Visual Studio 2022 (C++ build tools) and in
  GitHub Actions (.github\workflows\build.yml) with the same command:

      .\build.ps1                 player build
      .\build.ps1 -Diag           diagnostic build (trace in %LOCALAPPDATA%\boiii)
      .\build.ps1 -NoUpdateCheck  no network code at all (Nexus Mods variant)
      .\build.ps1 -SkipPackage    DLL + smoke test only

  MinHook (TsudaKageyu/minhook, pinned commit) is fetched into deps\minhook on
  the first run; set MINHOOK=<folder> to use your own copy instead.
#>
param(
    [switch]$Diag,
    [switch]$NoUpdateCheck,
    [switch]$SkipPackage,
    [string]$Version = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root = $PSScriptRoot
Set-Location $root   # cl/link get relative paths only: no quoting, no trailing-backslash trouble

if (-not $Version) { $Version = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim() }
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "VERSION must be MAJOR.MINOR.PATCH, got '$Version'" }

$PackageName   = 'Splitscreen4P'
$UpdateRepo    = 'manavdillon/Splitscreen4P'
$MinHookCommit = 'c3fcafdc10146beb5919319d0683e44e3c30d537'   # tag v1.3.4
$MinHookZip    = "https://github.com/TsudaKageyu/minhook/archive/$MinHookCommit.zip"

function Step($text) { Write-Host ''; Write-Host "== $text" -ForegroundColor Cyan }
function Run($exe, [string[]]$arguments) {
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "$exe failed with exit code $LASTEXITCODE" }
}

# --- MSVC environment ---------------------------------------------------------
function Import-VsEnvironment {
    if (Get-Command cl.exe -ErrorAction SilentlyContinue) { Write-Host 'cl.exe already on PATH'; return }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) {
        throw 'Visual Studio 2022 with the C++ build tools is not installed (vswhere.exe missing). Install "Desktop development with C++" or build through GitHub Actions.'
    }
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw 'No Visual Studio with the x64 C++ tools found.' }
    $vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found under $vs" }
    Write-Host "Using $vs"
    $lines = cmd /c "`"$vcvars`" >nul 2>&1 && set"
    foreach ($line in $lines) {
        if ($line -match '^([^=]+)=(.*)$') { Set-Item -Path "Env:$($matches[1])" -Value $matches[2] }
    }
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { throw 'vcvars64.bat ran but cl.exe is still not on PATH' }
}

# --- MinHook ------------------------------------------------------------------
function Get-MinHook {
    if ($env:MINHOOK -and (Test-Path (Join-Path $env:MINHOOK 'src\hook.c'))) {
        Write-Host "MinHook from MINHOOK=$env:MINHOOK"
        return $env:MINHOOK
    }
    $dir = Join-Path $root 'deps\minhook'
    if (Test-Path (Join-Path $dir 'src\hook.c')) { Write-Host "MinHook in $dir"; return $dir }
    Write-Host "Fetching MinHook $MinHookCommit"
    $deps = Join-Path $root 'deps'
    $tmp = Join-Path $deps 'minhook.zip'
    New-Item -ItemType Directory -Force $deps | Out-Null
    Invoke-WebRequest -UseBasicParsing -Uri $MinHookZip -OutFile $tmp
    Expand-Archive -Path $tmp -DestinationPath $deps -Force
    Move-Item (Join-Path $deps "minhook-$MinHookCommit") $dir
    Remove-Item $tmp
    if (-not (Test-Path (Join-Path $dir 'src\hook.c'))) { throw 'MinHook download did not contain src\hook.c' }
    return $dir
}

# --- build --------------------------------------------------------------------
Step "Build $PackageName $Version"
Import-VsEnvironment
$minhookAbs = Get-MinHook
$minhook = $minhookAbs
if ($minhookAbs.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
    $minhook = $minhookAbs.Substring($root.Length).TrimStart('\', '/')
}
if ($minhook -match ' ') { throw "MinHook path must not contain spaces for cl.exe: $minhook" }

$obj = 'out\obj'
if (Test-Path 'out') { Remove-Item 'out' -Recurse -Force }
New-Item -ItemType Directory -Force "$obj\smoke" | Out-Null

$gitHash = ''
try { $gitHash = (git rev-parse --short=10 HEAD 2>$null) } catch {}
if (-not $gitHash) { $gitHash = 'nogit' }

# Build-time constants, force-included into the component (16_update_check.inl).
@"
#pragma once
#define SS_MOD_VERSION "$Version"
#define SS_UPDATE_REPO_PATH L"/repos/$UpdateRepo/releases/latest"
#define SS_BUILD_ID "$gitHash"
"@ | Set-Content -Path "$obj\ss_build.hpp" -Encoding ASCII

$cc = @('/nologo', '/c', '/O1', '/GL', '/Gy', '/Gw', '/MT', '/DNDEBUG', '/DWIN32', '/D_WINDOWS', '/W3', '/Brepro')
if ($Diag)          { $cc += '/DSS_DIAG' }
if ($NoUpdateCheck) { $cc += '/DSS_NO_UPDATE_CHECK' }
# /FI resolves like #include "file" (relative to the source, then /I dirs), so $obj goes on /I.
$cpp = $cc + @('/std:c++20', '/EHsc', '/Zc:__cplusplus', "/I$obj", '/FIss_build.hpp')

Step 'Compile MinHook'
Run cl ($cc + @("/I$minhook\include", "/Fo$obj\", "$minhook\src\buffer.c", "$minhook\src\hook.c", "$minhook\src\trampoline.c", "$minhook\src\hde\hde64.c"))
Step 'Compile the component'
Run cl ($cpp + @('/Isrc\standalone\compat', "/Fo$obj\", 'src\component\splitscreen.cpp'))
Step 'Compile the plugin runtime'
Run cl ($cpp + @("/I$minhook\include", "/Fo$obj\", 'src\standalone\runtime.cpp', 'src\standalone\ezz_plugin.cpp'))
Step 'Link bo3_local_splitscreen.dll'
Run link @('/nologo', '/DLL', '/LTCG', '/OPT:REF', '/OPT:ICF', '/DEBUG:NONE', '/Brepro', '/MANIFEST:NO', '/MACHINE:X64',
           '/DEF:src\standalone\ezz_plugin.def', '/OUT:out\bo3_local_splitscreen.dll', "/IMPLIB:$obj\bo3_local_splitscreen.lib",
           "$obj\buffer.obj", "$obj\hook.obj", "$obj\trampoline.obj", "$obj\hde64.obj",
           "$obj\splitscreen.obj", "$obj\runtime.obj", "$obj\ezz_plugin.obj", 'kernel32.lib')

Step 'Smoke test (loads the DLL the way ezz does, outside the game)'
$ccExe = @($cc | Where-Object { $_ -ne '/c' })   # compile AND link in one call
Run cl ($ccExe + @('/std:c++20', '/EHsc', "/Fo$obj\smoke\", 'src\standalone\test\smoke.cpp', '/link', '/LTCG', '/OUT:out\smoke.exe', 'kernel32.lib', 'user32.lib'))
Run 'out\smoke.exe' @()

$dll = Get-Item 'out\bo3_local_splitscreen.dll'
Write-Host ("Built {0} ({1:N0} bytes, sha256 {2})" -f $dll.Name, $dll.Length, (Get-FileHash $dll -Algorithm SHA256).Hash.ToLower())

if ($SkipPackage) { return }

# --- package ------------------------------------------------------------------
Step 'Package'
$stage = "dist\$PackageName-$Version"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force "$stage\boiii\plugins", "$stage\boiii\ui_scripts", "$stage\setup" | Out-Null

Copy-Item $dll.FullName "$stage\boiii\plugins\"
foreach ($script in 'zz_mplan', 'zz_splitscreen', 'zz_table_insert') {
    Copy-Item "src\ui_scripts\$script" "$stage\boiii\ui_scripts\$script" -Recurse
}
Copy-Item 'setup\INSTALL.cmd', 'setup\CHECK.cmd', 'setup\UNINSTALL.cmd' $stage
Copy-Item 'setup\splitscreen-setup.ps1' "$stage\setup\"

$readme = Get-Content 'docs\PLAYER_README.txt' -Raw
if ($readme -notmatch [regex]::Escape("Splitscreen4P $Version")) { throw "docs\PLAYER_README.txt does not name version $Version" }
$license = Get-Content (Join-Path $minhookAbs 'LICENSE.txt') -Raw
$readme = $readme.Replace('{VERSION}', $gitHash).Replace('{MINHOOK_LICENSE}', $license.Trim())
Set-Content -Path "$stage\README.txt" -Value $readme -Encoding UTF8

$stageAbs = (Resolve-Path $stage).Path
$sums = Get-ChildItem $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
    $rel = $_.FullName.Substring($stageAbs.Length + 1).Replace('\', '/')
    "{0} *{1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $rel
}
Set-Content -Path "$stage\SHA256SUMS.txt" -Value ($sums -join "`n") -Encoding ASCII

$zip = "dist\$PackageName-$Version.zip"
if (Test-Path $zip) { Remove-Item $zip }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stageAbs, (Join-Path $root $zip), [IO.Compression.CompressionLevel]::Optimal, $false)
$zipItem = Get-Item $zip
Write-Host ("Packaged {0} ({1:N0} bytes, sha256 {2})" -f $zipItem.FullName, $zipItem.Length, (Get-FileHash $zipItem -Algorithm SHA256).Hash.ToLower())
