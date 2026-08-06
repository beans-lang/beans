# Exercise the real Windows installer, not a stand-in for it.
#
# The package is built by tools/package_windows_release.sh, a release manifest
# is written beside it, and tools/install-release.ps1 is run against that
# directory exactly as it would run against a GitHub release — same checksum
# check, same staging, same PATH handling. What differs is where the bytes come
# from, and that the target is named rather than detected: see BEANS_TARGET
# below for why detection cannot work here.
#
# usage: pwsh test/install_release.ps1 <beans-target-triple> <dist-directory>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Target,
    [Parameter(Mandatory = $true)] [string] $Dist
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Dist = (Resolve-Path $Dist).Path

function Step([string] $Message) { Write-Host "  $Message" }
function Fail([string] $Message) { Write-Error $Message; exit 1 }

$versionLine = Get-Content (Join-Path $repo 'compiler\version.h') |
    Select-String -Pattern 'char version\[\] = "([^"]*)"'
$version = $versionLine.Matches[0].Groups[1].Value

$archive = Get-ChildItem -Path $Dist -Filter '*.zip' | Select-Object -First 1
if (-not $archive) { Fail "no .zip package in $Dist" }

# --------------------------------------------------------------- manifest
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("beans-itest-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$peek = Join-Path $stage 'peek'
Expand-Archive -LiteralPath $archive.FullName -DestinationPath $peek -Force
$packageRoot = Get-ChildItem -LiteralPath $peek -Directory | Select-Object -First 1
$versionFile = Get-Content (Join-Path $packageRoot.FullName 'VERSION')
function Field([string] $Key) {
    ($versionFile | Where-Object { $_ -like "$Key=*" }) -replace "^$Key=", ''
}
$class = Field 'package'
$arch = Field 'arch'
$libc = Field 'libc'
$selfContained = if ($class -eq 'full') { 'yes' } else { 'no' }
$sha = (Get-FileHash -LiteralPath $archive.FullName -Algorithm SHA256).Hash.ToLowerInvariant()

$manifest = Join-Path $Dist 'beans-release-manifest.tsv'
$lines = @(
    "#version`ttarget`tos`tarch`tlibc`tclass`tasset`tsha256`tself_contained"
    "$version`t$Target`twindows`t$arch`t$libc`t$class`t$($archive.Name)`t$sha`t$selfContained"
)
Set-Content -LiteralPath $manifest -Value $lines -Encoding ascii

# ----------------------------------------------------------- no beansc0
$offending = Get-ChildItem -LiteralPath $peek -Recurse -Force |
    Where-Object { $_.Name -match 'beansc0' }
if ($offending) { Fail "the archive contains a beansc0 path: $($offending[0].FullName)" }
$textHits = Get-ChildItem -LiteralPath $peek -Recurse -File -Include *.md, *.cmd, *.b, VERSION |
    Select-String -Pattern 'beansc0' -List
if ($textHits) { Fail "a packaged file mentions beansc0: $($textHits[0].Path)" }
Step 'no beansc0 in any filename or file content'
Remove-Item -Recurse -Force $peek

# ------------------------------------------------------------- installing
$prefix = Join-Path $stage 'home'
$env:BEANS_INSTALL_BASE_URL = $Dist
# Naming the target is what makes this runnable at all. One Windows runner
# packages seven triples — gnu, gnullvm and msvc across three architectures —
# but host detection can only ever answer with one of them, so every job whose
# target is not the runner's own default would be told there is no package for
# this machine. Detection itself is covered on Unix by test/install_release.sh,
# where each job's target really is its host.
$env:BEANS_TARGET = $Target
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\install-release.ps1') `
    -Prefix $prefix -NoModifyPath | Tee-Object -Variable installOut | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "the installer failed:`n$($installOut -join "`n")" }
if (-not ($installOut -match 'checksum verified')) { Fail 'the installer did not verify a checksum' }
$launcher = Join-Path $prefix 'bin\beansc.cmd'
if (-not (Test-Path -LiteralPath $launcher)) { Fail "no beansc.cmd in $prefix" }

& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\install-release.ps1') `
    -Prefix $prefix -NoModifyPath | Tee-Object -Variable secondOut | Out-Null
if (-not ($secondOut -match 'already installed')) { Fail 'the installer is not idempotent' }
Step 'installer is idempotent'

# A bad checksum must leave the working installation alone.
$badManifest = Join-Path $stage 'bad-manifest.tsv'
(Get-Content $manifest) -replace '\t[0-9a-f]{64}\t', "`t$('0' * 64)`t" |
    Set-Content -LiteralPath $badManifest -Encoding ascii
$env:BEANS_INSTALL_MANIFEST = $badManifest
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\install-release.ps1') `
    -Prefix $prefix -Force 2>&1 | Tee-Object -Variable badOut | Out-Null
if ($LASTEXITCODE -eq 0) { Fail 'the installer accepted a wrong checksum' }
if (-not ($badOut -match 'checksum mismatch')) { Fail 'no checksum mismatch was reported' }
Remove-Item Env:\BEANS_INSTALL_MANIFEST
$still = & $launcher --version
if ($still -notmatch [regex]::Escape($version)) { Fail 'a failed download damaged the installation' }
Step 'a failed download keeps the working installation'

# --------------------------------------------------- what the install can do
$work = Join-Path $stage 'work'
New-Item -ItemType Directory -Path $work -Force | Out-Null
Copy-Item (Join-Path $repo 'examples\hello.b') (Join-Path $work 'hello.b')
# An FFI case the interpreter has to bridge into C. The CRT's div() keeps it free
# of any external library, so this stays a test of the toolchain and nothing else.
@'
import std.io

extern "C" struct DivT {
    quot: i32
    rem: i32
}

extern "C" fn div(numerator: i32, denominator: i32) -> DivT

fn main() {
    unsafe {
        let result: DivT = div(7, 2)
        io.println("{result.quot} {result.rem}")
    }
}
'@ | Set-Content -LiteralPath (Join-Path $work 'ffi.b') -Encoding ascii
Push-Location $work

if ((& $launcher --version) -ne "beansc $version (language 1.0, runtime ABI 4)") {
    Fail 'unexpected --version output'
}
$doctor = & $launcher doctor
if (-not ($doctor -match "^package: *$class$")) { Fail "doctor did not report the $class package" }
if (-not ($doctor -match '^check: *ready$')) { Fail 'doctor says check is not ready' }
if (-not ((& $launcher check hello.b) -match ': ok$')) { Fail 'check failed' }
if ((& $launcher run hello.b) -ne 'hello from beans') { Fail 'run failed' }
& $launcher build --emit ir hello.b -o (Join-Path $work 'hello.ll') | Out-Null
if (-not (Test-Path (Join-Path $work 'hello.ll'))) { Fail '--emit ir produced nothing' }
Step 'version, doctor, check, run and --emit ir work'

if ($class -eq 'full') {
    # Prove the bundled toolchain does the work: every system C tool is
    # shadowed by a stub that refuses to run, so a build that succeeds cannot
    # have used one.
    $shadow = Join-Path $stage 'shadow'
    New-Item -ItemType Directory -Path $shadow -Force | Out-Null
    foreach ($tool in 'clang', 'clang++', 'cc', 'gcc', 'ld', 'ld.lld', 'lld', 'ar', 'llvm-ar', 'link') {
        Set-Content -LiteralPath (Join-Path $shadow "$tool.cmd") `
            -Value "@echo $tool`: hidden by the bundled-toolchain test 1>&2`r`n@exit /b 127"
    }
    $savedPath = $env:Path
    $env:Path = "$shadow;$([Environment]::GetFolderPath('System'));$([Environment]::GetFolderPath('Windows'))"

    & $launcher build hello.b -o (Join-Path $work 'hello.exe') | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'the bundled toolchain could not build hello.b' }
    if ((& (Join-Path $work 'hello.exe')) -ne 'hello from beans') { Fail 'the built exe printed the wrong thing' }
    & $launcher build --emit obj hello.b -o (Join-Path $work 'hello.o') | Out-Null
    if (-not (Test-Path (Join-Path $work 'hello.o'))) { Fail '--emit obj produced nothing' }
    & $launcher build --emit static hello.b -o (Join-Path $work 'hello.lib') | Out-Null
    if (-not (Test-Path (Join-Path $work 'hello.lib'))) { Fail '--emit static produced nothing' }
    & (Join-Path $prefix 'toolchain\bin\llvm-ar.exe') t (Join-Path $work 'hello.lib') | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'the static library is not a readable archive' }
    Step 'bundled toolchain builds exe, obj and static library with no system C tools'

    # The interpreter's C bridge compiles a shim, so this is the FFI path that
    # depends on the toolchain rather than on generated native code.
    if ((& $launcher run ffi.b) -ne '3 1') { Fail 'the interpreter FFI bridge failed' }
    & $launcher build ffi.b -o (Join-Path $work 'ffi.exe') | Out-Null
    if ((& (Join-Path $work 'ffi.exe')) -ne '3 1') { Fail 'the native FFI build failed' }
    Step 'FFI works through both the interpreter bridge and a native build'
    $env:Path = $savedPath
} else {
    & $launcher llvm hello.b | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'llvm failed' }
    Step 'slim package runs every toolchain-free command'
}

Pop-Location
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
Write-Host "ok installer, package contents and command matrix ($class, $Target)"
