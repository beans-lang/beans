# Install Beans for the current user.
#
#   irm https://github.com/beans-lang/beans/releases/latest/download/beans-install.ps1 | iex
#
# Only built-in PowerShell is used — Invoke-WebRequest to download,
# Get-FileHash to verify, Expand-Archive to unpack. No jq, no Python, no Node,
# no Git, and no administrator rights: everything lands under the user's
# LOCALAPPDATA by default.
#
# Nothing is installed until the download has been checksummed, unpacked into a
# staging directory, and the compiler in it has answered `--version`. A failure
# at any step leaves an existing installation exactly as it was.

[CmdletBinding()]
param(
    [string] $Version,
    [string] $Prefix,
    [string] $Target,
    [switch] $Force,
    [switch] $NoModifyPath,
    [switch] $Help,
    [int] $WaitForPid
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# The installed Windows launcher uses this private option for self-upgrades.
# It exits before the installer moves the directory that held beansc.cmd and
# beansc.real.exe, so Windows never has to replace a running file.
if ($WaitForPid -gt 0) {
    try { Wait-Process -Id $WaitForPid -ErrorAction SilentlyContinue } catch { }
}

$Repo = if ($env:BEANS_INSTALL_REPO) { $env:BEANS_INSTALL_REPO } else { 'beans-lang/beans' }
$ManifestName = 'beans-release-manifest.tsv'

function Write-Note([string] $Message) { Write-Host "beans: $Message" }
function Die([string] $Message) { Write-Error "beans: error: $Message"; exit 1 }

# `irm ... | iex` gives the script no parameters, so the environment variables
# are the only way to configure that entry point.
if (-not $Version -and $env:BEANS_VERSION) { $Version = $env:BEANS_VERSION }
if (-not $Prefix -and $env:BEANS_HOME) { $Prefix = $env:BEANS_HOME }
if (-not $Target -and $env:BEANS_TARGET) { $Target = $env:BEANS_TARGET }
if (-not $Force -and $env:BEANS_INSTALL_FORCE -eq '1') { $Force = $true }
if (-not $NoModifyPath -and $env:BEANS_INSTALL_NO_MODIFY_PATH -eq '1') { $NoModifyPath = $true }

if ($Help) {
    @'
usage: beans-install.ps1 [options]

  -Version <v>      install this release instead of the latest (e.g. 0.9.0)
  -Prefix <dir>     install here instead of %LOCALAPPDATA%\Beans
  -Target <triple>  force a Beans target instead of detecting one
  -Force            reinstall even when this version is already installed
  -NoModifyPath     do not touch the user PATH
  -Help             show this message

environment:
  BEANS_HOME        same as -Prefix
  BEANS_VERSION     same as -Version
  BEANS_TARGET      same as -Target
'@ | Write-Host
    exit 0
}

if (-not $Prefix) {
    $localAppData = $env:LOCALAPPDATA
    if (-not $localAppData) { $localAppData = Join-Path $env:USERPROFILE 'AppData\Local' }
    $Prefix = Join-Path $localAppData 'Beans'
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("beans-install-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

function Remove-Work {
    if ($script:work -and (Test-Path $script:work)) {
        Remove-Item -Recurse -Force $script:work -ErrorAction SilentlyContinue
    }
}

try {
    # ------------------------------------------------------------- platform
    $machine = $env:PROCESSOR_ARCHITECTURE
    try {
        $machine = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    } catch { }

    if (-not $Target) {
        switch -Regex ($machine) {
            '^(X64|AMD64)$'    { $Target = 'x86_64-pc-windows-gnullvm' }
            '^(Arm64|ARM64)$'  { $Target = 'aarch64-pc-windows-gnullvm' }
            '^(X86|x86)$'      { $Target = 'i686-pc-windows-gnu' }
        }
    }

    # ------------------------------------------------------------- manifest
    $base = $env:BEANS_INSTALL_BASE_URL
    if (-not $base) {
        if ($Version) {
            $base = "https://github.com/$Repo/releases/download/v$Version"
        } else {
            $base = "https://github.com/$Repo/releases/latest/download"
        }
    }
    $manifestSource = $env:BEANS_INSTALL_MANIFEST
    if (-not $manifestSource) { $manifestSource = "$base/$ManifestName" }

    # A local base is how CI exercises this script end to end without a
    # published release. A URL still goes over HTTPS with the same checks, so
    # the tested code path is the shipped one.
    function Get-Asset([string] $From, [string] $To) {
        if ($From -match '^https?://') {
            Invoke-WebRequest -Uri $From -OutFile $To -UseBasicParsing
        } else {
            if (-not (Test-Path -LiteralPath $From)) { throw "no such file: $From" }
            Copy-Item -LiteralPath $From -Destination $To -Force
        }
    }

    $manifestPath = Join-Path $work $ManifestName
    try {
        Get-Asset $manifestSource $manifestPath
    } catch {
        Die "cannot download the release manifest from $manifestSource"
    }

    $rows = @()
    foreach ($line in Get-Content -LiteralPath $manifestPath) {
        if ($line.StartsWith('#') -or $line.Trim() -eq '') { continue }
        $fields = $line -split "`t"
        if ($fields.Count -lt 9) { continue }
        $rows += , [pscustomobject]@{
            Version = $fields[0]; Target = $fields[1]; OS = $fields[2]
            Arch = $fields[3]; Libc = $fields[4]; Class = $fields[5]
            Asset = $fields[6]; Sha256 = $fields[7]; SelfContained = $fields[8]
        }
    }

    # A target can be published as both a full and a slim package. Prefer full:
    # it is the one that needs nothing else installed.
    $row = $null
    if ($Target) {
        $matching = @($rows | Where-Object { $_.Target -eq $Target })
        $row = $matching | Where-Object { $_.Class -eq 'full' } | Select-Object -First 1
        if (-not $row) { $row = $matching | Select-Object -First 1 }
    }

    if (-not $row) {
        Write-Host "beans: no released package matches this machine."
        Write-Host ""
        Write-Host "  operating system: Windows"
        Write-Host "  architecture:     $machine"
        Write-Host "  libc:             ucrt/msvcrt (Windows)"
        if ($Target) { Write-Host "  beans target:     $Target" }
        else { Write-Host "  beans target:     could not be determined" }
        Write-Host ""
        Write-Host "Published targets:"
        foreach ($r in $rows) { Write-Host ("  {0} ({1})" -f $r.Target, $r.Class) }
        Write-Host ""
        Write-Host "Pick one explicitly with `$env:BEANS_TARGET='<triple>', or build from source:"
        Write-Host "  https://github.com/$Repo#install"
        exit 1
    }

    if ($Version -and $Version -ne $row.Version) {
        Die "the manifest at $manifestSource publishes $($row.Version), not $Version"
    }

    # ------------------------------------------------------ already installed
    $launcher = Join-Path $Prefix 'bin\beansc.cmd'
    if (-not $Force -and (Test-Path -LiteralPath $launcher)) {
        $installed = ''
        try { $installed = (& $launcher --version 2>$null) -join ' ' } catch { }
        if ($installed -match [regex]::Escape($row.Version)) {
            Write-Note "beans $($row.Version) is already installed in $Prefix"
            Write-Note "re-run with -Force to reinstall"
            exit 0
        }
    }

    # ------------------------------------------------------------- download
    Write-Note "downloading $($row.Asset) ($($row.Class) package for $($row.Target))"
    $archive = Join-Path $work $row.Asset
    try {
        Get-Asset "$base/$($row.Asset)" $archive
    } catch {
        Die "cannot download $base/$($row.Asset)"
    }

    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $row.Sha256.ToLowerInvariant()) {
        Die "checksum mismatch for $($row.Asset)`n  expected $($row.Sha256)`n  actual   $actual`nNothing was installed."
    }
    Write-Note "checksum verified"

    # -------------------------------------------------- unpack and validate
    $stage = Join-Path $work 'stage'
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        Expand-Archive -LiteralPath $archive -DestinationPath $stage -Force
    } catch {
        Die "cannot unpack $($row.Asset); nothing was installed"
    }
    $unpacked = Get-ChildItem -LiteralPath $stage -Directory | Select-Object -First 1
    if (-not $unpacked) { Die "$($row.Asset) does not contain a package directory" }
    $stagedLauncher = Join-Path $unpacked.FullName 'bin\beansc.cmd'
    if (-not (Test-Path -LiteralPath $stagedLauncher)) {
        Die "$($row.Asset) has no bin\beansc.cmd; nothing was installed"
    }

    # The staged compiler has to answer before anything is moved into place, so
    # a corrupt or wrong-architecture download can never replace a working
    # installation.
    $stagedVersion = ''
    try { $stagedVersion = (& $stagedLauncher --version 2>$null) -join ' ' } catch { }
    if (-not $stagedVersion) {
        Die "the downloaded compiler does not run on this machine ($machine); nothing was installed"
    }
    Write-Note "staged $stagedVersion"

    # --------------------------------------------------------------- install
    $parent = Split-Path -Parent $Prefix
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $previous = $null
    if (Test-Path -LiteralPath $Prefix) {
        $previous = "$Prefix.old-$PID"
        Move-Item -LiteralPath $Prefix -Destination $previous
    }
    try {
        Move-Item -LiteralPath $unpacked.FullName -Destination $Prefix
    } catch {
        if ($previous) { Move-Item -LiteralPath $previous -Destination $Prefix }
        Die "cannot install into $Prefix"
    }
    if ($previous) { Remove-Item -Recurse -Force $previous -ErrorAction SilentlyContinue }

    # ------------------------------------------------------------------ PATH
    $binDir = Join-Path $Prefix 'bin'
    $pathUpdated = $false
    if (-not $NoModifyPath) {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (-not $userPath) { $userPath = '' }
        $entries = $userPath -split ';' | Where-Object { $_ -ne '' }
        # Idempotent: an installation that has already added this entry must not
        # add a second copy of it.
        $already = $entries | Where-Object { $_.TrimEnd('\') -ieq $binDir.TrimEnd('\') }
        if (-not $already) {
            $joined = (@($binDir) + $entries) -join ';'
            [Environment]::SetEnvironmentVariable('Path', $joined, 'User')
            $pathUpdated = $true
        }
    }

    # ---------------------------------------------------------------- report
    Write-Host ""
    Write-Note "installed beans $($row.Version) into $Prefix"
    if ($row.SelfContained -eq 'yes') {
        Write-Note "this is a full package: native builds work with nothing else installed"
    } else {
        Write-Note "this is a $($row.Class) package: a native build needs clang on your PATH"
    }
    if ($pathUpdated) {
        Write-Note "PATH updated for your user account"
    }
    Write-Note "open a new terminal, or enable Beans in this one with:"
    Write-Host ""
    Write-Host "    `$env:Path = `"$binDir;`$env:Path`""
    Write-Host ""

    $env:Path = "$binDir;$env:Path"
    & $launcher --version
    if ($LASTEXITCODE -ne 0) { Die "the installed compiler did not run" }
    Write-Note "run 'beansc doctor' to see what this installation can build"
} finally {
    Remove-Work
}
