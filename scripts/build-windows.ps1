<#
.SYNOPSIS
  Build a static LGPL FFmpeg for Windows using the MSVC toolchain.

.DESCRIPTION
  FFmpeg's configure needs a POSIX shell + make + nasm even when the *compiler*
  is MSVC (cl/link). The CI job provides those via MSYS2 and enters an MSVC
  developer environment (vcvarsall) before invoking this script, so `cl` is on
  PATH. We build with `--toolchain=msvc` so the resulting static .lib match the
  Rust x86_64-pc-windows-msvc toolchain that consumes them.

  Hardware encoders are runtime-loaded (FFmpeg dlopens the vendor DLLs), so we
  only need build-time *headers* (nvenc, amf) and the oneVPL dispatcher (libvpl,
  built static). None of those exist on Windows arm64, so arm64 is
  MediaFoundation + D3D11VA only.

.PARAMETER Arch
  x86_64 or arm64.
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('x86_64', 'arm64')]
  [string]$Arch
)
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. "$RepoRoot\scripts\versions.ps1"   # generated shim that dot-sources versions.env values

$Sources = Join-Path $RepoRoot 'sources'
$Build   = Join-Path $RepoRoot "build\windows-$Arch"
$Prefix  = Join-Path $Build 'prefix'
$Dist    = Join-Path $RepoRoot 'dist'
New-Item -ItemType Directory -Force -Path $Sources, $Build, $Prefix, $Dist | Out-Null

# --- Enter the MSVC developer environment ------------------------------------
# Microsoft's own Enter-VsDevShell (ships with Visual Studio on the runner) —
# no third-party action, no Node runtime to deprecate. It sets cl/link/INCLUDE/
# LIB for this PowerShell session; the cmake and MSYS2 `bash` child processes
# invoked below inherit that environment. arm64 builds cross from the x64 host.
$vsArch  = if ($Arch -eq 'x86_64') { 'x64' } else { 'arm64' }
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath  = & $vswhere -latest -products * -property installationPath
Import-Module (Join-Path $vsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation `
  -DevCmdArguments "-arch=$vsArch -host_arch=x64 -no_logo"

function Fetch-Git($Name, $Repo, $Ref) {
  $dest = Join-Path $Sources $Name
  if (Test-Path (Join-Path $dest '.git')) { return }
  git clone --quiet $Repo $dest
  git -C $dest checkout --quiet $Ref
}

# --- Build-time dependencies (x86_64 vendor encoders only) -------------------
Fetch-Git 'ffmpeg' $env:FFMPEG_REPO $env:FFMPEG_REF
if ($Arch -eq 'x86_64') {
  # nvenc + amf are header-only: install their headers into the prefix so
  # FFmpeg's configure finds ffnvcodec.pc / AMF/core/Factory.h.
  Fetch-Git 'nv-codec-headers' $env:NV_CODEC_HEADERS_REPO $env:NV_CODEC_HEADERS_REF
  & make -C (Join-Path $Sources 'nv-codec-headers') install "PREFIX=$Prefix"

  Fetch-Git 'amf' $env:AMF_REPO $env:AMF_REF
  Copy-Item -Recurse -Force (Join-Path $Sources 'amf\amf\public\include') (Join-Path $Prefix 'include\AMF')

  # libvpl (oneVPL dispatcher): static CMake build, installed into the prefix.
  Fetch-Git 'libvpl' $env:LIBVPL_REPO $env:LIBVPL_REF
  cmake -S (Join-Path $Sources 'libvpl') -B (Join-Path $Build 'libvpl') -G Ninja `
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF "-DCMAKE_INSTALL_PREFIX=$Prefix"
  cmake --build (Join-Path $Build 'libvpl') --target install
}

# --- Configure + build FFmpeg ------------------------------------------------
# flags.sh is the single source of truth for configure flags; run it via the
# MSYS2 bash that CI puts on PATH so the same logic drives every platform.
$flags = (bash -lc "source '$RepoRoot/scripts/flags.sh'; configure_flags windows $Arch") -split "`n" |
         Where-Object { $_ -ne '' }

$obj = Join-Path $Build 'obj'
New-Item -ItemType Directory -Force -Path $obj | Out-Null
Push-Location $obj
$env:PKG_CONFIG_PATH = Join-Path $Prefix 'lib\pkgconfig'
bash -lc "'$Sources/ffmpeg/configure' --prefix='$Prefix' $($flags -join ' ')"
bash -lc "make -j$env:NUMBER_OF_PROCESSORS && make install"
Pop-Location

# --- Package -----------------------------------------------------------------
$name = "tether-ffmpeg-$env:TETHER_FFMPEG_VERSION-windows-$Arch-lgpl-static"
tar -C $Build -cJf (Join-Path $Dist "$name.tar.xz") 'prefix'
(Get-FileHash (Join-Path $Dist "$name.tar.xz") -Algorithm SHA256).Hash.ToLower() |
  Out-File -Encoding ascii (Join-Path $Dist "$name.tar.xz.sha256")
Write-Host "[tether-ffmpeg] wrote dist\$name.tar.xz"
