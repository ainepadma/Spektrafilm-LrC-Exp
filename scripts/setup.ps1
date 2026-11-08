# Prepare the Windows x64 worker without changing a global Python installation.
[CmdletBinding()]
param([string]$Proxy)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root '.tools'
$cache = Join-Path $root '.cache'
$version = '3.13.9'
$commit = '3bb2c2d2801ff68b92019cf1dbcbb133d60832bc'
$interpreterDir = Join-Path $root ".runtime\cpython-$version"
$interpreter = Join-Path $interpreterDir 'tools\python.exe'
$venv = Join-Path $root '.venv'
$python = Join-Path $venv 'Scripts\python.exe'

function Set-LocalEnvironment([string]$Name, [string]$Value) {
    $originalEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

function Get-Package([string]$Url, [string]$File, [string]$Digest) {
    if ((Test-Path -LiteralPath $File) -and (Get-FileHash -LiteralPath $File).Hash -eq $Digest) { return }
    $partial = "$File.part"
    $request = @{ Uri = $Url; OutFile = $partial; UseBasicParsing = $true }
    if ($Proxy) { $request.Proxy = $Proxy }
    Invoke-WebRequest @request
    if ((Get-FileHash -LiteralPath $partial).Hash -ne $Digest) {
        throw "Download failed integrity check: $Url"
    }
    Move-Item -LiteralPath $partial -Destination $File -Force
}

function Invoke-Python([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Python failed ($LASTEXITCODE). See the command output above."
    }
}

if (-not [Environment]::Is64BitOperatingSystem -or ($env:PROCESSOR_ARCHITECTURE -notin 'AMD64','x86')) {
    throw 'This setup supports Windows x64.'
}

$originalEnvironment = @{}
try {
    $temp = Join-Path $cache 'setup-tmp'
    New-Item -ItemType Directory -Force -Path $tools,$temp,(Split-Path -Parent $interpreterDir) | Out-Null
    Set-LocalEnvironment 'TEMP' $temp
    Set-LocalEnvironment 'TMP' $temp
    Set-LocalEnvironment 'PIP_CACHE_DIR' (Join-Path $cache 'pip')
    Set-LocalEnvironment 'PIP_DISABLE_PIP_VERSION_CHECK' '1'
    Set-LocalEnvironment 'PIP_CONFIG_FILE' 'NUL'
    Set-LocalEnvironment 'MPLCONFIGDIR' (Join-Path $cache 'matplotlib')
    Set-LocalEnvironment 'NUMBA_CACHE_DIR' (Join-Path $cache 'numba-canonical')
    if ($Proxy) {
        Set-LocalEnvironment 'HTTPS_PROXY' $Proxy
        Set-LocalEnvironment 'HTTP_PROXY' $Proxy
    }

    if (-not (Test-Path -LiteralPath $interpreter)) {
        $package = Join-Path $tools "python-$version.nupkg"
        Get-Package "https://api.nuget.org/v3-flatcontainer/python/$version/python.$version.nupkg" $package 'EA7541C98F77B6F344460B88DB6E677573069979BCBF0BA18747CC2C125ABA25'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $stage = Join-Path $temp ([Guid]::NewGuid().ToString())
        [IO.Compression.ZipFile]::ExtractToDirectory($package, $stage)
        Move-Item -LiteralPath $stage -Destination $interpreterDir
    }
    if (-not (Test-Path -LiteralPath $python)) {
        Invoke-Python $interpreter @('-Im', 'venv', $venv)
    }
    $actual = & $python -Ic 'import platform; print(platform.python_version())'
    if ($LASTEXITCODE -ne 0 -or $actual -ne $version) {
        throw "Expected Python $version in $venv; found $actual."
    }

    Invoke-Python $python @('-Im','pip','install','-r',(Join-Path $root 'requirements.txt'))
    $sourceDigest = 'BDF61F4A9E657ACF0DE78275BBBB350968FC85D5679CB57286ABE0C633ED24C1'
    $provenance = Get-ChildItem "$venv\Lib\site-packages\spektrafilm-*.dist-info\direct_url.json" -ErrorAction SilentlyContinue
    $installed = if ($provenance) { (Get-Content -LiteralPath $provenance.FullName -Raw | ConvertFrom-Json).archive_info.hashes.sha256 }
    if ($installed -ne $sourceDigest) {
        $sourceUrl = "https://codeload.github.com/andreavolpato/spektrafilm/zip/$commit"
        $sourceArchive = Join-Path $tools "spektrafilm-$commit.zip"
        Get-Package $sourceUrl $sourceArchive $sourceDigest
        Invoke-Python $python @('-Im','pip','install','--no-deps',$sourceArchive)
    }
    Invoke-Python $python @('-Ic','from spektrafilm import init_params, simulate')
    Write-Host 'Preparing the full-resolution CPU kernels...'
    Invoke-Python $python @('-Ic','import sys; sys.path.insert(0,sys.argv[1]); from bridge.warmup import prime; prime()', $root)
    Write-Host "Runtime ready: $python"
} finally {
    foreach ($name in $originalEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process')
    }
}
