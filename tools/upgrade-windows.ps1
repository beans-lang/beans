# Start a Beans upgrade after the installed beansc.cmd launcher exits.
# Windows does not allow a running executable (or its active batch launcher) to
# be moved aside. Copy the real installer to a temporary path, start it in the
# same console, then let the launcher exit and release the installation files.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Prefix
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $Prefix 'libexec\beans-install.ps1'
if (-not (Test-Path -LiteralPath $source)) {
    Write-Error 'beans: error: this Beans installation has no upgrade helper'
    exit 1
}

try {
    $parent = (Get-CimInstance Win32_Process -Filter "ProcessId = $PID").ParentProcessId
} catch {
    Write-Error 'beans: error: cannot find the beansc launcher process'
    exit 1
}

$copy = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("beans-upgrade-" + [System.Guid]::NewGuid().ToString('N') + '.ps1')
Copy-Item -LiteralPath $source -Destination $copy -Force

function Quote-ProcessArgument([string] $Value) {
    return '"' + $Value.Replace('"', '\"') + '"'
}

$engine = (Get-Process -Id $PID).Path
$arguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Quote-ProcessArgument $copy),
    '-Prefix', (Quote-ProcessArgument $Prefix),
    '-NoModifyPath',
    '-WaitForPid', "$parent"
) -join ' '

Start-Process -FilePath $engine -ArgumentList $arguments -NoNewWindow | Out-Null
Write-Host 'beans: upgrade started; it will continue after beansc exits'
