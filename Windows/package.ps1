param([string]$Version = '1.6.0')

$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw '版本号必须是 major.minor.patch。' }
$projectRoot = Split-Path -Parent $PSScriptRoot
$archiveDir = Join-Path $projectRoot ("dist/releases/" + $Version)
if (Test-Path -LiteralPath $archiveDir) { throw "版本留档已存在：$archiveDir" }

& (Join-Path $PSScriptRoot 'build.ps1')
$exe = Join-Path $PSScriptRoot 'PetsPet.exe'
$productVersion = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
if ($productVersion -ne $Version) { throw "EXE 版本不一致：$productVersion；预期 $Version" }

$selfTest = Start-Process -FilePath $exe -ArgumentList '--self-test' -Wait -PassThru
if ($selfTest.ExitCode -ne 0) { throw 'Windows 规则检查失败。' }
$selfTestResult = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'data/self-test.json') -Raw | ConvertFrom-Json
if (-not $selfTestResult.passed -or $selfTestResult.assertions -lt 70) { throw 'Windows 规则检查结果不完整。' }

$renderTest = Start-Process -FilePath $exe -ArgumentList '--render-checks' -Wait -PassThru
if ($renderTest.ExitCode -ne 0) { throw 'Windows 视觉样本生成失败。' }
$renderResult = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'data/render-checks.json') -Raw | ConvertFrom-Json
if (-not $renderResult.passed -or $renderResult.renderedImages -ne 66) { throw 'Windows 视觉样本结果不完整。' }

$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("petspet-windows-" + [guid]::NewGuid().ToString('N'))
$packageName = "PetsPet-Windows-$Version-x64"
$stage = Join-Path $stageRoot $packageName
try {
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Copy-Item -LiteralPath $exe -Destination (Join-Path $stage 'PetsPet.exe')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination (Join-Path $stage 'README.md')
    $stagedArchive = Join-Path $stageRoot 'archive'
    New-Item -ItemType Directory -Path $stagedArchive | Out-Null
    $zip = Join-Path $stagedArchive ("$packageName.zip")
    Compress-Archive -LiteralPath $stage -DestinationPath $zip
    $expanded = Join-Path $stageRoot 'expanded'
    Expand-Archive -LiteralPath $zip -DestinationPath $expanded
    $packedExe = Join-Path $expanded ("$packageName/PetsPet.exe")
    if ((Get-FileHash -LiteralPath $packedExe -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash) {
        throw '压缩包中的 EXE 与通过检查的 EXE 不一致。'
    }
    $checksum = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText((Join-Path $stagedArchive 'SHA256SUMS-Windows.txt'), "$checksum  $packageName.zip`n", (New-Object System.Text.UTF8Encoding($false)))
    New-Item -ItemType Directory -Path (Split-Path -Parent $archiveDir) -Force | Out-Null
    Move-Item -LiteralPath $stagedArchive -Destination $archiveDir
    Write-Host "已生成并校验：$(Join-Path $archiveDir ("$packageName.zip"))"
    Write-Host "规则断言：$($selfTestResult.assertions)；视觉样本：$($renderResult.renderedImages)"
} finally {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
}
