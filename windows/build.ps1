param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Push-Location $PSScriptRoot
try {
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $version = '0.6.0'
    $distRoot = Join-Path $PSScriptRoot '..\dist'
    $packageName = "AdsWork-JS-Manager-Windows-x64-$version"
    $packageDir = Join-Path $distRoot $packageName
    $zipPath = Join-Path $distRoot "$packageName.zip"
    $publishDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ads-work-publish-' + [Guid]::NewGuid().ToString('N'))
    if ((Test-Path $packageDir) -or (Test-Path $zipPath)) { throw "Output already exists: $packageDir" }
    & dotnet run --project JsLocalManager.Checks -c Release
    if ($LASTEXITCODE -ne 0) { throw 'Core checks failed.' }
    & dotnet publish JsLocalManager/JsLocalManager.csproj -c Release -r win-x64 --self-contained true -o $publishDir
    if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed.' }
    $installer = Join-Path $publishDir 'MicrosoftEdgeWebview2Setup.exe'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $installer
    $expected = [regex]::Match((Get-Content 'JsLocalManager/RuntimeInstaller.cs' -Raw), '[0-9a-f]{64}').Value
    if ((Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
        throw 'Microsoft bootstrapper changed. Verify its source and update RuntimeInstaller.cs before publishing.'
    }
    $report = Join-Path ([System.IO.Path]::GetTempPath()) ('AdsWork-WebUI-report-' + [Guid]::NewGuid().ToString('N'))
    $check = Start-Process -FilePath (Join-Path $publishDir 'AdsWorkJsManager.exe') -ArgumentList @('--web-check', ('"' + $report + '"')) -Wait -PassThru
    if ($check.ExitCode -ne 0) { throw "Windows WebView2 checks failed. Report: $report" }
    New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
    foreach ($file in @('AdsWorkJsManager.exe', 'WebView2Loader.dll', 'MicrosoftEdgeWebview2Setup.exe')) {
        Copy-Item (Join-Path $publishDir $file) $packageDir
    }
    Copy-Item 'README.md' $packageDir
    Copy-Item 'Licenses' $packageDir -Recurse
    $sums = @('AdsWorkJsManager.exe', 'WebView2Loader.dll', 'MicrosoftEdgeWebview2Setup.exe') | ForEach-Object {
        $hash = (Get-FileHash (Join-Path $packageDir $_) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $_"
    }
    [System.IO.File]::WriteAllText((Join-Path $packageDir 'SHA256SUMS.txt'), ($sums -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
    Compress-Archive -Path $packageDir -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Host "Created: $zipPath"
    Write-Host "Windows WebView2 checks passed. Report: $report"
}
finally {
    if ((Test-Path variable:publishDir) -and (Test-Path $publishDir)) { Remove-Item $publishDir -Recurse -Force }
    Pop-Location
}
