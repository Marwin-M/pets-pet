$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$outputPath = Join-Path $projectRoot 'PetsPet.exe'
$frameworkRoot = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$compiler = Join-Path $frameworkRoot 'csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    throw '没有找到 Windows 自带的 C# 编译工具。请确认 .NET Framework 4.x 可用。'
}
if (Get-Process -Name 'PetsPet' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $outputPath }) {
    throw 'PetsPet 正在运行。请先从它的右键菜单选择“退出”，再重新生成。'
}
$references = @(
    'System.dll', 'System.Core.dll', 'System.Drawing.dll',
    'System.Windows.Forms.dll', 'System.Web.Extensions.dll',
    (Join-Path $frameworkRoot 'WPF\UIAutomationClient.dll'),
    (Join-Path $frameworkRoot 'WPF\UIAutomationTypes.dll'),
    (Join-Path $frameworkRoot 'WPF\WindowsBase.dll')
)
$compilerArgs = @(
    '/nologo', '/target:winexe', '/platform:x64', '/optimize+',
    '/codepage:65001', '/warn:4', '/warnaserror+',
    ('/out:' + $outputPath),
    ('/win32manifest:' + (Join-Path $projectRoot 'app.manifest')),
    ('/win32icon:' + (Join-Path $projectRoot 'assets\AppIcon.ico')),
    ('/resource:' + (Join-Path $projectRoot 'assets\AppIcon.ico') + ',PetsPet.AppIcon.ico'),
    ('/resource:' + (Join-Path $projectRoot '..\Resources\MenuBarIcon.png') + ',PetsPet.MenuBarIcon.png'),
    ('/resource:' + (Join-Path $projectRoot 'Sidebar.js') + ',PetsPet.Sidebar.js')
)
$compilerArgs += $references | ForEach-Object { '/reference:' + $_ }
$compilerArgs += Join-Path $projectRoot 'PetsPet.cs'
$compilerArgs += Join-Path $projectRoot 'Integration.cs'
$compilerArgs += Join-Path $projectRoot 'AssemblyInfo.cs'
& $compiler @compilerArgs
if ($LASTEXITCODE -ne 0) { throw '生成程序失败，请查看上方错误。' }
Write-Host ('已生成：' + (Join-Path $projectRoot 'PetsPet.exe'))
