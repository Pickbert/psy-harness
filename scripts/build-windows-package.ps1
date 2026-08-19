param(
    [string]$OutputDirectory = "",
    [switch]$SkipHarnessBuild,
    [switch]$CreateInstaller,
    [switch]$CreatePortableZip,
    [string]$SigningCertificateThumbprint = "",
    [string]$ChineseLanguageFile = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ProjectDirectory = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$VersionFile = Join-Path $ProjectDirectory "windows\VERSION"
if (-not (Test-Path -LiteralPath $VersionFile -PathType Leaf)) {
    throw "Missing Windows version file: $VersionFile"
}
$AppVersion = (Get-Content -LiteralPath $VersionFile -Raw).Trim()
if ($AppVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw "Invalid Windows version: $AppVersion"
}
$ChineseLanguageUri = "https://raw.githubusercontent.com/jrsoftware/issrc/4adf37ed7f3fd2bd11c6836ba056e3de170fbabf/Files/Languages/Unofficial/ChineseSimplified.isl"
$ExpectedChineseLanguageHash = "7d544b9bb1d142cfa11f2e5d3cc8abe2e55f8e066c5124e3772675aa236e1278"
$VersionParts = $AppVersion.Split('.') | ForEach-Object { [int]$_ }
function Assert-BinaryVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $VersionInfo = (Get-Item -LiteralPath $Path).VersionInfo
    $ActualVersion = @(
        $VersionInfo.FileMajorPart,
        $VersionInfo.FileMinorPart,
        $VersionInfo.FileBuildPart
    )
    for ($Index = 0; $Index -lt $VersionParts.Count; $Index++) {
        if ($ActualVersion[$Index] -ne $VersionParts[$Index]) {
            throw "$Label file version does not match windows/VERSION ($AppVersion): $($VersionInfo.FileVersion)"
        }
    }
}
$ResourceDefinition = Get-Content -LiteralPath (Join-Path $ProjectDirectory "windows\resources.rc") -Raw
if ($ResourceDefinition -notmatch ('VALUE "ProductVersion", "' + [regex]::Escape($AppVersion) + '"')) {
    throw "windows/resources.rc ProductVersion does not match windows/VERSION ($AppVersion)."
}
$ManifestDefinition = Get-Content -LiteralPath (Join-Path $ProjectDirectory "windows\app.manifest") -Raw
$ManifestVersion = "$AppVersion.0"
if ($ManifestDefinition -notmatch ('assemblyIdentity version="' + [regex]::Escape($ManifestVersion) + '"')) {
    throw "windows/app.manifest assembly version does not match windows/VERSION ($AppVersion)."
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $ProjectDirectory "build\windows-agent-package-v$AppVersion"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) {
    throw "Output directory already exists: $OutputDirectory. Choose a new -OutputDirectory so a stale runtime cannot enter the package."
}

$NodeCommand = Get-Command node.exe -ErrorAction Stop
$NpmCommand = Get-Command npm.cmd -ErrorAction Stop
$CorepackCommand = Get-Command corepack.cmd -ErrorAction Stop
$NodeVersion = (& $NodeCommand.Source -p "process.versions.node").Trim()
$NodeParts = $NodeVersion.Split('.')
$NodeMajor = [int]$NodeParts[0]
$NodeMinor = [int]$NodeParts[1]
if (-not (($NodeMajor -eq 22 -and $NodeMinor -ge 19) -or $NodeMajor -ge 24)) {
    throw "DeepSeek Harness requires Node.js 22.19+ or 24+; found $NodeVersion."
}

$Compiler = Get-Command cl.exe -ErrorAction Stop
$ResourceCompiler = Get-Command rc.exe -ErrorAction Stop
$SignTool = $null
if (-not [string]::IsNullOrWhiteSpace($SigningCertificateThumbprint)) {
    $SignTool = Get-Command signtool.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($SignTool)) {
        $SignTool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrWhiteSpace($SignTool)) {
        throw "Signing was requested, but signtool.exe was not found."
    }
}
$HarnessDirectory = Join-Path $ProjectDirectory "ThirdParty\deepseek-harness"
$RuntimeDirectory = Join-Path $OutputDirectory "DesktopPetAgent"
$RuntimeNodeDirectory = Join-Path $RuntimeDirectory "node"
$IntermediateDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "DesktopPet-Windows-Build-$PID"
$ExecutablePath = Join-Path $OutputDirectory "DesktopPet-Windows-x64.exe"
$ResourcePath = Join-Path $IntermediateDirectory "resources.res"
$ObjectOutput = $IntermediateDirectory + [System.IO.Path]::DirectorySeparatorChar
New-Item -ItemType Directory -Path $RuntimeDirectory, $IntermediateDirectory | Out-Null

Push-Location $ProjectDirectory
try {
    & $ResourceCompiler.Source /nologo /c 65001 /I windows /fo $ResourcePath windows\resources.rc
    if ($LASTEXITCODE -ne 0) { throw "Windows resource compilation failed with exit code $LASTEXITCODE." }

    & $Compiler.Source /nologo /std:c++20 /O2 /EHsc /MT /utf-8 /DUNICODE /D_UNICODE /D_WIN32_WINNT=0x0A00 `
        /I windows windows\DesktopPet.cpp windows\AgentRuntime.cpp windows\FileAnalysisRuntime.cpp `
        $ResourcePath "/Fo$ObjectOutput" "/Fe$ExecutablePath" `
        /link /SUBSYSTEM:WINDOWS /INCREMENTAL:NO `
        gdiplus.lib shell32.lib ole32.lib advapi32.lib winhttp.lib uuid.lib comctl32.lib user32.lib gdi32.lib
    if ($LASTEXITCODE -ne 0) { throw "Windows application compilation failed with exit code $LASTEXITCODE." }
    Assert-BinaryVersion -Path $ExecutablePath -Label "DesktopPet-Windows-x64.exe"

    Push-Location $HarnessDirectory
    try {
        $env:COREPACK_NPM_REGISTRY = "https://registry.npmjs.org"
        $env:npm_config_registry = "https://registry.npmjs.org"
        & $CorepackCommand.Source pnpm install --frozen-lockfile --ignore-scripts --child-concurrency=1 --network-concurrency=8
        if ($LASTEXITCODE -ne 0) { throw "Harness dependency installation failed with exit code $LASTEXITCODE." }
        if (-not $SkipHarnessBuild) {
            & $NodeCommand.Source node_modules\typescript\bin\tsc -b tsconfig.host.json
            if ($LASTEXITCODE -ne 0) { throw "Harness TypeScript build failed with exit code $LASTEXITCODE." }
            & $NodeCommand.Source node_modules\tsdown\dist\run.mjs --env.DSH_BUILD_FACE host
            if ($LASTEXITCODE -ne 0) { throw "Harness host bundle failed with exit code $LASTEXITCODE." }
        }
        # pnpm 11's legacy hoisted deploy silently omits some direct workspace
        # dependencies. Use the dedicated-lockfile deploy implementation while
        # retaining a flat, link-free node_modules tree for ZIP/Inno packaging.
        & $CorepackCommand.Source pnpm --filter dsh-jsonrpc-agent-pkg deploy --prod `
            --ignore-scripts --config.inject-workspace-packages=true `
            --config.node-linker=hoisted --config.link-workspace-packages=true `
            $RuntimeNodeDirectory
        if ($LASTEXITCODE -ne 0) { throw "Harness runtime deployment failed with exit code $LASTEXITCODE." }
    }
    finally {
        Pop-Location
    }

    $FileAnalysisSource = Join-Path $ProjectDirectory "Agent\windows-file-analysis"
    $FileAnalysisRuntime = Join-Path $RuntimeDirectory "file-analysis"
    New-Item -ItemType Directory -Path $FileAnalysisRuntime | Out-Null
    Copy-Item -LiteralPath (Join-Path $FileAnalysisSource "package.json") -Destination $FileAnalysisRuntime
    Copy-Item -LiteralPath (Join-Path $FileAnalysisSource "package-lock.json") -Destination $FileAnalysisRuntime
    Copy-Item -LiteralPath (Join-Path $FileAnalysisSource "file-analysis.mjs") -Destination $FileAnalysisRuntime
    Push-Location $FileAnalysisRuntime
    try {
        & $NpmCommand.Source ci --omit=dev --ignore-scripts --registry=https://registry.npmjs.org
        if ($LASTEXITCODE -ne 0) { throw "File analysis dependency installation failed with exit code $LASTEXITCODE." }
    }
    finally {
        Pop-Location
    }

    Copy-Item -LiteralPath $NodeCommand.Source -Destination (Join-Path $RuntimeDirectory "node.exe")
    Copy-Item -LiteralPath (Join-Path $ProjectDirectory "Agent\cordis-windows.yml") `
        -Destination (Join-Path $RuntimeDirectory "DesktopPetAgent.cordis.yml")
    Copy-Item -LiteralPath (Join-Path $ProjectDirectory "Agent\SYSTEM_PROMPT.md") `
        -Destination (Join-Path $RuntimeDirectory "DesktopPetAgentSystemPrompt.md")
    Copy-Item -LiteralPath (Join-Path $ProjectDirectory "Agent\THIRD_PARTY_NOTICES.md") `
        -Destination (Join-Path $RuntimeDirectory "THIRD_PARTY_NOTICES.md")
    Copy-Item -LiteralPath $VersionFile -Destination (Join-Path $OutputDirectory "VERSION")
    Copy-Item -LiteralPath (Join-Path $ProjectDirectory "ThirdParty\deepseek-harness\LICENSE") `
        -Destination (Join-Path $RuntimeDirectory "DeepSeekHarness-LICENSE.txt")
    Copy-Item -LiteralPath (Join-Path $ProjectDirectory "ThirdParty\deepseek-harness\pnpm-lock.yaml") `
        -Destination (Join-Path $RuntimeDirectory "DeepSeekHarness-pnpm-lock.yaml")
    Copy-Item -LiteralPath (Join-Path $FileAnalysisRuntime "node_modules\exceljs\LICENSE") `
        -Destination (Join-Path $RuntimeDirectory "ExcelJS-LICENSE.txt")
    Copy-Item -LiteralPath (Join-Path $FileAnalysisRuntime "node_modules\mammoth\LICENSE") `
        -Destination (Join-Path $RuntimeDirectory "Mammoth-LICENSE.txt")
    Copy-Item -LiteralPath (Join-Path $FileAnalysisRuntime "node_modules\pdfjs-dist\LICENSE") `
        -Destination (Join-Path $RuntimeDirectory "PDFJS-LICENSE.txt")

    $NodeDirectory = Split-Path -Parent $NodeCommand.Source
    $NodeLicenseCandidates = @(
        (Join-Path $NodeDirectory "LICENSE"),
        (Join-Path $NodeDirectory "LICENSE.txt"),
        (Join-Path (Split-Path -Parent $NodeDirectory) "LICENSE")
    )
    $NodeLicense = $NodeLicenseCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($NodeLicense)) {
        throw "Cannot package node.exe without locating its complete LICENSE file."
    }
    Copy-Item -LiteralPath $NodeLicense -Destination (Join-Path $RuntimeDirectory "NodeJS-LICENSE.txt")

    $RequiredRuntimeFiles = @(
        "node.exe",
        "DesktopPetAgent.cordis.yml",
        "DesktopPetAgentSystemPrompt.md",
        "THIRD_PARTY_NOTICES.md",
        "DeepSeekHarness-LICENSE.txt",
        "DeepSeekHarness-pnpm-lock.yaml",
        "NodeJS-LICENSE.txt",
        "ExcelJS-LICENSE.txt",
        "Mammoth-LICENSE.txt",
        "PDFJS-LICENSE.txt",
        "file-analysis\file-analysis.mjs",
        "file-analysis\package-lock.json",
        "file-analysis\node_modules\exceljs\package.json",
        "file-analysis\node_modules\mammoth\package.json",
        "file-analysis\node_modules\pdfjs-dist\package.json",
        "node\node_modules\@deepseek-ai\dsh-sdk-jsonrpc-demo\lib\packaged-bin.js",
        "node\node_modules\@deepseek-ai\dsh-sandbox-windows-acl\lib\runner.js",
        "node\node_modules\node-pty\prebuilds\win32-x64\conpty.node",
        "node\node_modules\node-pty\prebuilds\win32-x64\conpty\conpty.dll",
        "node\node_modules\node-pty\prebuilds\win32-x64\conpty\OpenConsole.exe",
        "node\node_modules\@koromix\koffi-win32-x64\win32_x64\koffi.node"
    )
    $DeployManifestPath = Join-Path $HarnessDirectory "python\sdk-runtime\package.json"
    $DeployManifest = Get-Content -LiteralPath $DeployManifestPath -Raw | ConvertFrom-Json
    $RequiredAgentPackages = @($DeployManifest.dependencies.PSObject.Properties.Name)
    if ($RequiredAgentPackages.Count -eq 0) {
        throw "Harness deploy manifest declares no runtime dependencies: $DeployManifestPath"
    }
    $RequiredRuntimeFiles += @($RequiredAgentPackages | ForEach-Object {
        $PackagePath = $_.Replace('/', '\')
        "node\node_modules\$PackagePath\package.json"
    })
    foreach ($RelativePath in $RequiredRuntimeFiles) {
        $FullPath = Join-Path $RuntimeDirectory $RelativePath
        if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
            throw "Packaged Agent runtime is incomplete; missing $RelativePath."
        }
    }

    $AgentSmokeWorkspace = Join-Path $IntermediateDirectory "agent-smoke-workspace"
    New-Item -ItemType Directory -Path $AgentSmokeWorkspace | Out-Null
    & $NodeCommand.Source (Join-Path $ProjectDirectory "scripts\windows-agent-smoke.mjs") `
        $RuntimeDirectory $AgentSmokeWorkspace
    if ($LASTEXITCODE -ne 0) {
        throw "Packaged Agent prompt smoke test failed with exit code $LASTEXITCODE."
    }

    if (-not [string]::IsNullOrWhiteSpace($SigningCertificateThumbprint)) {
        & $SignTool sign /sha1 $SigningCertificateThumbprint /fd SHA256 `
            /tr http://timestamp.digicert.com /td SHA256 $ExecutablePath
        if ($LASTEXITCODE -ne 0) { throw "Application signing failed with exit code $LASTEXITCODE." }
    }

    $ReleaseDirectory = Split-Path -Parent $OutputDirectory
    $ReleaseBaseName = "DesktopPet-Windows-v$AppVersion-Agent-x64"
    $ReleaseFiles = [System.Collections.Generic.List[string]]::new()
    if ($CreatePortableZip) {
        $PortableZip = Join-Path $ReleaseDirectory "$ReleaseBaseName-Portable.zip"
        if (Test-Path -LiteralPath $PortableZip) {
            throw "Portable archive already exists: $PortableZip"
        }
        Compress-Archive -Path (Join-Path $OutputDirectory "*") -DestinationPath $PortableZip -CompressionLevel Optimal
        $ReleaseFiles.Add($PortableZip)
    }
    if ($CreateInstaller) {
        $IsccCandidates = @(
            (Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
            "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
            "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) }
        $Iscc = $IsccCandidates | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($Iscc)) {
            throw "Inno Setup 6 compiler (ISCC.exe) is required for -CreateInstaller."
        }
        if ([string]::IsNullOrWhiteSpace($ChineseLanguageFile)) {
            $ChineseLanguageFile = Join-Path (Split-Path -Parent $Iscc) "Languages\ChineseSimplified.isl"
            if (-not (Test-Path -LiteralPath $ChineseLanguageFile -PathType Leaf)) {
                $ChineseLanguageFile = Join-Path ([System.IO.Path]::GetTempPath()) "DesktopPet-ChineseSimplified-6.7.3.isl"
                Invoke-WebRequest -Uri $ChineseLanguageUri -OutFile $ChineseLanguageFile
            }
        }
        $ChineseLanguageFile = [System.IO.Path]::GetFullPath($ChineseLanguageFile)
        if (-not (Test-Path -LiteralPath $ChineseLanguageFile -PathType Leaf)) {
            throw "ChineseSimplified.isl was not found. Pass its path with -ChineseLanguageFile."
        }
        $ChineseLanguageHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ChineseLanguageFile).Hash.ToLowerInvariant()
        if ($ChineseLanguageHash -ne $ExpectedChineseLanguageHash) {
            throw "ChineseSimplified.isl SHA-256 mismatch: expected $ExpectedChineseLanguageHash, got $ChineseLanguageHash."
        }
        $InnoArguments = [System.Collections.Generic.List[string]]::new()
        $InnoArguments.Add("/DAppVersion=$AppVersion")
        $InnoArguments.Add("/DSourceDir=$OutputDirectory")
        $InnoArguments.Add("/DProjectDir=$ProjectDirectory")
        $InnoArguments.Add("/DChineseLanguageFile=$ChineseLanguageFile")
        $InnoArguments.Add("/O$ReleaseDirectory")
        $InnoArguments.Add("/F$ReleaseBaseName-Setup")
        if (-not [string]::IsNullOrWhiteSpace($SigningCertificateThumbprint)) {
            $InnoArguments.Add("/DSigningEnabled=1")
            $InnoArguments.Add("/Sdesktoppet=`"$SignTool`" sign /sha1 $SigningCertificateThumbprint /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 `$f")
        }
        $InnoArguments.Add((Join-Path $ProjectDirectory "installer\DesktopPet.iss"))
        $InnoArgumentArray = $InnoArguments.ToArray()
        & $Iscc $InnoArgumentArray
        if ($LASTEXITCODE -ne 0) { throw "Installer compilation failed with exit code $LASTEXITCODE." }
        $InstallerPath = Join-Path $ReleaseDirectory "$ReleaseBaseName-Setup.exe"
        if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
            throw "Installer compiler did not create $InstallerPath."
        }
        Assert-BinaryVersion -Path $InstallerPath -Label "Setup installer"
        $ReleaseFiles.Add($InstallerPath)
    }
    if ($ReleaseFiles.Count -gt 0) {
        $ChecksumPath = Join-Path $ReleaseDirectory "$ReleaseBaseName-SHA256SUMS.txt"
        $ChecksumLines = foreach ($ReleaseFile in $ReleaseFiles) {
            $Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ReleaseFile).Hash.ToLowerInvariant()
            "$Hash  $(Split-Path -Leaf $ReleaseFile)"
        }
        [System.IO.File]::WriteAllLines($ChecksumPath, $ChecksumLines, [System.Text.UTF8Encoding]::new($false))
        Write-Output $ChecksumPath
    }

    Write-Output $ExecutablePath
    Write-Output $RuntimeDirectory
}
finally {
    Pop-Location
}
