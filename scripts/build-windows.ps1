<#
.SYNOPSIS
  Build a static LGPL FFmpeg for Windows using the MSVC toolchain.

.DESCRIPTION
  FFmpeg's configure needs a POSIX shell + make + nasm even when the *compiler*
  is MSVC (cl/link). The CI job provides those via MSYS2 and enters an MSVC
  developer environment (vcvarsall) before invoking this script, so `cl` is on
  PATH. We build with `--toolchain=msvc` so the resulting static .lib match the
  Rust x86_64-pc-windows-msvc toolchain that consumes them.

  All MSYS2-side work runs through that distro's bash *by explicit path* ($MsysBash):
  a bare `bash`/`make` invoked from PowerShell can resolve to Git Bash or a native
  make that doesn't see pkgconf and mishandles /d/... unix paths. We also set
  MSYS2_PATH_TYPE=inherit so the login shell keeps both the MSYS2 tools (pkgconf,
  make, nasm — first on PATH) and the inherited MSVC toolchain (cl/link).

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
# $ErrorActionPreference only governs PowerShell cmdlets — a *native* command
# (git/cmake/make/bash/tar) that exits non-zero does NOT abort the script. Without
# this, a failed FFmpeg configure was ignored and an empty/dependency-only prefix
# got packaged and published as a green artifact. Make native failures fatal too.
$PSNativeCommandUseErrorActionPreference = $true

$RepoRoot = Split-Path -Parent $PSScriptRoot
. "$RepoRoot\scripts\versions.ps1"   # generated shim that dot-sources versions.env values

$Sources = Join-Path $RepoRoot 'sources'
$Build   = Join-Path $RepoRoot "build\windows-$Arch"
$Prefix  = Join-Path $Build 'prefix'
$Dist    = Join-Path $RepoRoot 'dist'
New-Item -ItemType Directory -Force -Path $Sources, $Build, $Prefix, $Dist | Out-Null

# Resolve MSYS2's own bash by absolute path (from the setup-msys2 action's
# msys2-location output). Falling back to a bare `bash` only for local runs where
# the dev already has MSYS2 first on PATH.
$MsysBash = if ($env:MSYS2_ROOT) { Join-Path $env:MSYS2_ROOT 'usr\bin\bash.exe' } else { 'bash' }
# Login shells default to MSYS2_PATH_TYPE=minimal, which drops the inherited Windows
# PATH — and with it the MSVC cl/link that Enter-VsDevShell adds. 'inherit' keeps the
# MSYS2 tools first and the MSVC toolchain after.
$env:MSYS2_PATH_TYPE = 'inherit'
# MSYS2's /etc/profile cd's a login shell to $HOME unless CHERE_INVOKING is set, which
# would silently move the FFmpeg out-of-tree build out of our obj dir into ~ (it only
# "worked" because --prefix is absolute). Keep the caller's working directory.
$env:CHERE_INVOKING = '1'
function Bash([string]$Script) { & $MsysBash -lc $Script }

# FFmpeg's --toolchain=msvc links with `link`, but MSYS2 coreutils ships its own
# /usr/bin/link.exe which — first on the inherited PATH — would shadow MSVC's
# link.exe and fail every link test. The build never needs the coreutils one, so
# remove it; `link` then resolves to MSVC's. (Canonical FFmpeg-on-MSVC workaround.)
if ($env:MSYS2_ROOT) {
  $coreutilsLink = Join-Path $env:MSYS2_ROOT 'usr\bin\link.exe'
  if (Test-Path $coreutilsLink) { Remove-Item -Force $coreutilsLink }
}

# Unix-style equivalents of the build paths, for the pkgconf / configure / make
# invocations below. cygpath only rewrites the string, so the target dirs needn't
# exist yet (ffmpeg is cloned later).
$PrefixUnix = (Bash "cygpath -u '$Prefix'").Trim()
$SrcUnix    = (Bash "cygpath -u '$Sources/ffmpeg'").Trim()
$RepoUnix   = (Bash "cygpath -u '$RepoRoot'").Trim()

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
  # Keep the Windows prefix here: it becomes ffnvcodec.pc's embedded prefix=, which
  # pkgconf turns into the -I cl sees. cl accepts a drive-letter path (D:\... / D:/...)
  # but not cygpath's /d/... form, so the unix prefix belongs only in PKG_CONFIG_PATH.
  & make -C (Join-Path $Sources 'nv-codec-headers') install "PREFIX=$Prefix"

  Fetch-Git 'amf' $env:AMF_REPO $env:AMF_REF
  Copy-Item -Recurse -Force (Join-Path $Sources 'amf\amf\public\include') (Join-Path $Prefix 'include\AMF')

  # libvpl (oneVPL dispatcher): static CMake build, installed into the prefix.
  Fetch-Git 'libvpl' $env:LIBVPL_REPO $env:LIBVPL_REF
  cmake -S (Join-Path $Sources 'libvpl') -B (Join-Path $Build 'libvpl') -G Ninja `
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF "-DCMAKE_INSTALL_PREFIX=$Prefix"
  cmake --build (Join-Path $Build 'libvpl') --target install

  # libvpl's static dispatcher calls the Win32 registry (advapi32) and
  # StringFromGUID2 (ole32), but its generated vpl.pc lists only -lvpl, so a
  # static link leaves those unresolved (LNK2019) and FFmpeg's libvpl check
  # fails. Append the system libs to the .pc Libs line: pkg-config then emits
  # them and FFmpeg's mslink wrapper converts -ladvapi32/-lole32 → *.lib the
  # same way it already handles -lvpl. (Patching the .pc beats --extra-libs,
  # which bypasses that conversion and reaches link as the bogus '/ladvapi32'.)
  $vplPc = Join-Path $Prefix 'lib\pkgconfig\vpl.pc'
  (Get-Content $vplPc) -replace '^(Libs:.*)$', '$1 -ladvapi32 -lole32' | Set-Content $vplPc
}

# --- Configure + build FFmpeg ------------------------------------------------
# flags.sh is the single source of truth for configure flags; run it through the
# same MSYS2 bash so the identical logic drives every platform.
$flags = (Bash "source '$RepoUnix/scripts/flags.sh'; configure_flags windows $Arch") -split "`n" |
         Where-Object { $_ -ne '' }

$obj = Join-Path $Build 'obj'
New-Item -ItemType Directory -Force -Path $obj | Out-Null
$ObjUnix = (Bash "cygpath -u '$obj'").Trim()
Push-Location $obj
# Put our prefix on the MSVC INCLUDE/LIB search paths. --prefix alone does NOT add
# prefix/include to the compiler's search path, so FFmpeg's amf check (a bare header
# at prefix/include/AMF, not a pkg-config lib) wouldn't find AMF/core/*.h. cl/link
# read these env vars and inherit them through bash, same as VsDevShell's own paths.
$env:INCLUDE = "$Prefix\include;$env:INCLUDE"
$env:LIB     = "$Prefix\lib;$env:LIB"
# PKG_CONFIG_PATH must be a unix-style path: pkgconf splits it on ':' and expects
# '/'-separated paths, so a Windows path (drive-letter colon + backslashes) parses as
# garbage and none of our .pc files are found. Export it (cygpath-converted) inside
# the bash command, alongside unix prefix/src paths. configure_flags also passes
# --pkg-config=pkgconf so FFmpeg calls the binary by its real MSYS2 name.
try {
  Bash "export PKG_CONFIG_PATH='$PrefixUnix/lib/pkgconfig'; '$SrcUnix/configure' --prefix='$PrefixUnix' $($flags -join ' ')"
} catch {
  # configure failures are usually a single failed feature check buried in its log;
  # surface the tail so CI shows the real cause (full log is uploaded as an artifact).
  Write-Host '===== ffbuild/config.log (tail 200) ====='
  Bash "tail -200 '$ObjUnix/ffbuild/config.log' 2>&1 || echo 'NO config.log found'"
  throw
}
Bash "make -j$env:NUMBER_OF_PROCESSORS && make install"
Pop-Location

# Guard: never package a prefix that lacks FFmpeg itself. Native errors are fatal
# now, so this is defense-in-depth against the original failure mode — publishing a
# deps-only or empty prefix as a green artifact.
if (-not (Test-Path (Join-Path $Prefix 'include\libavcodec\avcodec.h'))) {
  throw "FFmpeg did not install into $Prefix (no libavcodec headers) — refusing to package an incomplete artifact."
}

# --- Package -----------------------------------------------------------------
$name = "tether-ffmpeg-$env:TETHER_FFMPEG_VERSION-windows-$Arch-lgpl-static"
tar -C $Build -cJf (Join-Path $Dist "$name.tar.xz") 'prefix'
# Emit the same "<hash>  <file>\n" (two spaces, LF) format as the unix
# `shasum -a 256` so `sha256sum -c` / `shasum -c` verifies every platform's
# checksum uniformly. WriteAllText avoids Out-File's CRLF + BOM.
$hash = (Get-FileHash (Join-Path $Dist "$name.tar.xz") -Algorithm SHA256).Hash.ToLower()
[System.IO.File]::WriteAllText((Join-Path $Dist "$name.tar.xz.sha256"), "$hash  $name.tar.xz`n")
Write-Host "[tether-ffmpeg] wrote dist\$name.tar.xz"
