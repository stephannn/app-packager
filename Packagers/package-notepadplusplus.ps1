<#
Vendor: Notepad++ Team
App: Notepad++ (x64)
CMName: Notepad++
VendorUrl: https://notepad-plus-plus.org/
CPE: cpe:2.3:a:notepad-plus-plus:notepad%2b%2b:*:*:*:*:*:*:*:*
ReleaseNotesUrl: https://notepad-plus-plus.org/news/
DownloadPageUrl: https://notepad-plus-plus.org/downloads/

.SYNOPSIS
    Packages Notepad++ (x64) for MECM.

.DESCRIPTION
    Downloads the latest Notepad++ x64 installer from the official GitHub
    releases API, stages content to a versioned local folder with file-based
    detection metadata, and creates an MECM Application with file-version-based
    detection.
    Detection uses notepad++.exe version >= packaged version in the Program
    Files install path.

    Supports two-phase operation:
      -StageOnly    Download, generate content wrappers, write manifest
      -PackageOnly  Read manifest, copy to network, create MECM application

.PARAMETER SiteCode
    ConfigMgr site code PSDrive name (e.g., "MCM").
    The PSDrive is assumed to already exist in the session.

.PARAMETER Comment
    Free-form change/WO text stored on the CM Application Description field.

.PARAMETER FileServerPath
    UNC root that contains your Applications folder (example: \\fileserver\sccm$).
    Content is staged under: <FileServerPath>\Applications\Notepad++\Notepad++\<Version>

.PARAMETER DownloadRoot
    Local root folder for staging downloaded installers.
    Each packager creates a subfolder under this path (e.g., <DownloadRoot>\NotepadPlusPlus).
    Default: C:\temp\ap

.PARAMETER EstimatedRuntimeMins
    Estimated runtime in minutes for the MECM deployment type.
    Default: 15

.PARAMETER MaximumRuntimeMins
    Maximum allowed runtime in minutes for the MECM deployment type.
    Default: 30

.PARAMETER StageOnly
    Runs only the Stage phase: download installer, generate content wrappers
    and stage manifest.

.PARAMETER PackageOnly
    Runs only the Package phase: read stage manifest, copy content to network,
    create MECM application with file-based detection.

.PARAMETER GetLatestVersionOnly
    Outputs only the latest available Notepad++ version string and exits.

.REQUIREMENTS
    - PowerShell 5.1
    - ConfigMgr Admin Console installed (ConfigurationManager PowerShell module available)
    - RBAC permissions to create Applications and Deployment Types
    - Local administrator
    - Write access to FileServerPath
#>

param(
    [string]$SiteCode = "MCM",
    [string]$MECMApplicationFolder = "",
    [string]$Comment = "",
    [string]$FileServerPath = "\\fileserver\sccm$",
    [string]$ApplicationSharePattern = "Applications\{ProductName}\{Version}",
    [string]$AppNamePattern = "{AppName} - {SoftwareVersion}",
    [string]$DownloadRoot = "C:\temp\ap",
    [String]$PSAppDeployToolkitPath = "",
    [int]$EstimatedRuntimeMins = 15,
    [int]$MaximumRuntimeMins = 30,
    [string]$LogPath,
    [switch]$GetLatestVersionOnly,
    [switch]$StageOnly,
    [switch]$PackageOnly,
    [switch]$VerboseLog
)


Import-Module "$PSScriptRoot\AppPackagerCommon.psd1" -Force
Initialize-Logging -LogPath $LogPath -VerboseLogging:$VerboseLog

if ($StageOnly -and $PackageOnly) {
    Write-Log "-StageOnly and -PackageOnly cannot be used together." -Level ERROR
    exit 1
}

# --- Configuration ---
$GitHubApiUrl    = "https://api.github.com/repos/notepad-plus-plus/notepad-plus-plus/releases/latest"
$PluginUrl       = "https://raw.githubusercontent.com/notepad-plus-plus/nppPluginList/refs/heads/master/doc/plugin_list_x64.md"
$DownloadIconUrl = ""
$Plugins         = @("Compare", "JSON Viewer", "JSTool", "XML Tools")

$Publisher     = "GNU"
$AppName       = "Notepad++"
$Language      = "MUI"
$Architecture  = "x64"

$BaseDownloadRoot = Join-Path $DownloadRoot "NotepadPlusPlus"

# --- Functions ---


function Get-LatestNotepadPlusPlusVersion {
    param([switch]$Quiet)

    Write-Log "GitHub API URL               : $GitHubApiUrl" -Quiet:$Quiet

    try {
        $json = Get-PageContentWithFallback -Url $GitHubApiUrl -Quiet:$Quiet
        if ([string]::IsNullOrWhiteSpace($json)) {
            throw "Could not retrieve $GitHubApiUrl using either Invoke-WebRequest or curl.exe."
        }

        $release = ConvertFrom-Json $json
        $version = $release.tag_name -replace '^v'

        $downloadUrl = $null
        foreach ($asset in $release.assets) {
            if ($asset.name -like "*Installer.x64.exe") {
                $downloadUrl = $asset.browser_download_url
                break
            }
        }

        if (-not $downloadUrl) {
            throw "Could not find x64 installer asset in GitHub release."
        }

        Write-Log "Latest Notepad++ version     : $version" -Quiet:$Quiet

        return [PSCustomObject]@{
            Version     = $version
            DownloadUrl = $downloadUrl
            FileName    = [System.IO.Path]::GetFileName($downloadUrl)
        }
    }
    catch {
        Write-Log "Failed to get Notepad++ version: $($_.Exception.Message)" -Level ERROR
        return $null
    }
}


function Get-NotepadPlusPlusPlugin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PluginName,
        [switch]$Quiet
    )

    Write-Log "GitHub Plugin URL               : $PluginUrl" -Quiet:$Quiet

    try {
        try {
            $markdownText = Get-PageContentWithFallback -Url $PluginUrl -Quiet:$Quiet
        }
        catch {
            throw "Failed to download the plugin list: $_"
        }

        $escapedName = [regex]::Escape($PluginName)
        $pattern = "(?m)^\|\s*$escapedName\s*\|.*?\|.*?\|\s*\[.*?\]\((https?://[^\s\)]+)\)"

        if ($markdownText -match $pattern) {
            $downloadUrl = $Matches[1]
        }

        if (-not $downloadUrl) {
            throw "Could not find the plugin."
        }

        if ($downloadUrl -match '/releases/download/(v?[\d\.]+)/') {
            $version = $Matches[1]
        }

        Write-Log "Notepad++ plugin $PluginName  : $version" -Quiet:$Quiet

        return [PSCustomObject]@{
            Version     = $version
            DownloadUrl = $downloadUrl
            FileName    = [System.IO.Path]::GetFileName($downloadUrl)
        }
    }
    catch {
        Write-Log "Failed to get Notepad++ plugin: $($_.Exception.Message)" -Level ERROR
        return $null
    }
}


# ---------------------------------------------------------------------------
# Stage phase
# ---------------------------------------------------------------------------

function Invoke-StageNotepadPlusPlus {
    Write-Log ""
    Write-Log ("=" * 60)
    Write-Log "$AppName - STAGE phase"
    Write-Log ("=" * 60)
    Write-Log ""

    Initialize-Folder -Path $BaseDownloadRoot

    # --- Get version ---
    $releaseInfo = Get-LatestNotepadPlusPlusVersion
    if (-not $releaseInfo) { throw "Could not resolve Notepad++ version." }

    $version           = $releaseInfo.Version
    $downloadUrl       = $releaseInfo.DownloadUrl
    $installerFileName = $releaseInfo.FileName

    Write-Log "Version                      : $version"
    Write-Log "Installer filename           : $installerFileName"
    Write-Log ""

    # --- Download ---
    $localExe = Join-Path $BaseDownloadRoot $installerFileName
    Write-Log "Local installer path         : $localExe"

    if (-not (Test-Path -LiteralPath $localExe)) {
        Write-Log "Download URL                 : $downloadUrl"
        Write-Log ""
        Write-Log "Downloading installer..."
        Invoke-DownloadWithRetry -Url $downloadUrl -OutFile $localExe -ExtraCurlArgs @('-A', 'PowerShell')
    }
    else {
        Write-Log "Local installer exists. Skipping download."
    }

    if($DownloadIconUrl){
        Write-Log "Downloading ICO..."
        try {
            $localIco = ([IO.Path]::Combine($BaseDownloadRoot, $AppName + ([System.IO.Path]::GetExtension($DownloadIconUrl))))
            Invoke-DownloadWithRetry -Url $DownloadIconUrl -OutFile $localIco
        }
        catch {
            Write-Log "Failed to download ICO: $($_.Exception.Message)" -Level WARN
            $localIco = ""
        }
    }

    $Plugins | ForEach-Object {
        Write-Log "Downloading Plugin $_"
        $pluginInfo = Get-NotepadPlusPlusPlugin -PluginName $_
        if (-not $pluginInfo) { throw "Could not resolve Notepad++ plugin." }

        $pluginVersion      = $pluginInfo.Version
        $pluginDownloadUrl  = $pluginInfo.DownloadUrl
        $pluginFileName     = $pluginInfo.FileName

        $localPlugin = Join-Path $BaseDownloadRoot $pluginFileName

        Write-Log "Downloading plugin $pluginFileName in version $pluginVersion"
        Invoke-DownloadWithRetry -Url $pluginDownloadUrl -OutFile $localPlugin -ExtraCurlArgs @('-A', 'PowerShell')

    }

    # --- Versioned local content folder ---
    $localContentPath = Join-Path $BaseDownloadRoot $version
    Initialize-Folder -Path $localContentPath

    $stagedExe = Join-Path $localContentPath $installerFileName
    if (-not (Test-Path -LiteralPath $stagedExe)) {
        Copy-Item -LiteralPath $localExe -Destination $stagedExe -Force -ErrorAction Stop
        Write-Log "Copied EXE to staged folder  : $stagedExe"
    }
    else {
        Write-Log "Staged EXE exists. Skipping copy."
    }
    if(-not (Test-Path -LiteralPath (Join-Path $localContentPath ([System.IO.Path]::GetFileName($localIco))))) {
        Copy-Item -LiteralPath $localIco -Destination (Join-Path $localContentPath ([System.IO.Path]::GetFileName($localIco))) -Force -ErrorAction Stop
        Write-Log "Copied ICO to staged folder  : $localContentPath"
    }
    else {
        Write-Log "Staged ICO exists. Skipping copy."
    }
    if($Plugins) {
        Get-ChildItem $BaseDownloadRoot | Where-Object {
            $fileName = $_.Name; ($Plugins.Where({ $fileName -like "*$($_.Trim().Replace(' ', ''))*" }).Count -gt 0) -or ($Plugins.Where({ $fileName -like "*$($_)*" }).Count -gt 0) } | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $localContentPath -Force -ErrorAction Stop
                Write-Log "Copied Plugin '$($_.Name)' to staged folder : $localContentPath" 
            }
    }

    # --- Generate content wrappers ---
    # Install: kill Notepad++ process first, then run NSIS silent installer
    $installContent = (
        'Stop-Process -Name "notepad++" -Force -ErrorAction SilentlyContinue',
        ('$exePath = Join-Path $PSScriptRoot ''{0}''' -f $installerFileName),
        '$proc = Start-Process -FilePath $exePath -ArgumentList @(''/S'', ''/noUpdater'') -Wait -PassThru -NoNewWindow',
        'exit $proc.ExitCode'
    ) -join "`r`n"

    # Uninstall: run NSIS uninstaller from install path
    $uninstallContent = (
        '$proc = Start-Process -FilePath ''C:\Program Files\Notepad++\uninstall.exe'' -ArgumentList @(''/S'') -Wait -PassThru -NoNewWindow',
        'exit $proc.ExitCode'
    ) -join "`r`n"

    if([string]::IsNullOrWhiteSpace($PSAppDeployToolkitPath) -eq $true -or (Test-Path -LiteralPath $PSAppDeployToolkitPath) -eq $false) {
        Write-ContentWrappers -OutputPath $localContentPath `
            -InstallPs1Content $installContent `
            -UninstallPs1Content $uninstallContent
    }

    # --- Write stage manifest ---
    $detectionPath = "{0}\Notepad" -f $env:ProgramFiles

    

    $installScript = @"
Start-Process -FilePath '.\$installerFileName' -ArgumentList '/S /noUpdater /D=$detectionPath' -Wait -NoNewWindow;
Get-ChildItem -Path '.' -Filter '*.zip' | ForEach-Object {
    Expand-Archive -LiteralPath `$_.FullName -DestinationPath ([System.IO.Path]::Combine('$detectionPath', 'plugins', (`$_.BaseName -replace '[\._-](v?\d+.*|x64|64|Release|uni).*$', ''))) -Force
}
"@
    $inlineArgs = "-NoProfile -ExecutionPolicy Bypass -Command `"$($installScript -replace '\r?\n', ' ')`""

    $uninstallScript = @"
Get-Item -Path '$detectionPath\plugins' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force;
if(Test-Path '$detectionPath\uninstall.exe') {Start-Process -FilePath '$detectionPath\uninstall.exe' -ArgumentList '/S -Wait -NoNewWindow'};
"@
    $uninlineArgs = "-NoProfile -ExecutionPolicy Bypass -Command `"$($uninstallScript -replace '\r?\n', ' ')`""

    Write-Log ""
    Write-Log "Detection path               : $detectionPath"
    Write-Log "Detection file               : notepad++.exe"
    Write-Log ""

    $manifestPath = Join-Path $localContentPath "stage-manifest.json"
    Write-StageManifest -Path $manifestPath -ManifestData @{
        AppName          = $AppName
        DisplayName      = $AppName
        Publisher        = $Publisher
        SoftwareVersion  = $version
        Architecture     = $Architecture
        Language         = $Language
        InstallerFile    = "powershell.exe"
        InstallerType    = "EXE"
        InstallArgs      = $inlineArgs
        UninstallCommand = "powershell.exe"
        UninstallArgs    = $uninlineArgs
        RunningProcess   = @("notepad++")
        Detection        = @{
            Type      = "Compound"
            Connector = "AND"  # Set to "And" or "Or"
            Clauses   = @(
                @{
                    Type          = "File"
                    FilePath      = $detectionPath
                    FileName      = "notepad++.exe"
                    PropertyType  = "Version"
                    Operator      = "GreaterEquals"
                    ExpectedValue = $version
                    Is64Bit       = $true
                },
                @{
                    Type                = "RegistryKey"
                    RegistryKeyRelative = "SOFTWARE\SCCM\$($Publisher)_$($AppName)_$($version)_$($Language)_$($Architecture)_01"
                    Is64Bit             = $arpEntry.Is64Bit
                }
            )
        }
        IconFileName     = if($localIco -and (Test-Path -LiteralPath $localIco)) { $AppName + ([System.IO.Path]::GetExtension($DownloadIconUrl)) } else { "" }
    }

    # Save version marker for Package phase
    Set-Content -LiteralPath (Join-Path $BaseDownloadRoot "staged-version.txt") -Value $version -Encoding ASCII -ErrorAction Stop

    Write-Log ""
    Write-Log "Stage complete               : $localContentPath"

    return $localContentPath
}


# ---------------------------------------------------------------------------
# Package phase
# ---------------------------------------------------------------------------

function Invoke-PackageNotepadPlusPlus {
    Write-Log ""
    Write-Log ("=" * 60)
    Write-Log "$AppName - PACKAGE phase"
    Write-Log ("=" * 60)
    Write-Log ""

    # --- Resolve version from local staging ---
    Initialize-Folder -Path $BaseDownloadRoot

    $versionFile = Join-Path $BaseDownloadRoot "staged-version.txt"
    if (-not (Test-Path -LiteralPath $versionFile)) {
        throw "Version marker not found - run Stage phase first: $versionFile"
    }
    $version = (Get-Content -LiteralPath $versionFile -Raw -ErrorAction Stop).Trim()

    $localContentPath = Join-Path $BaseDownloadRoot $version
    $manifestPath     = Join-Path $localContentPath "stage-manifest.json"

    # --- Read manifest ---
    $manifest = Read-StageManifest -Path $manifestPath

    Write-Log "AppName                      : $($manifest.AppName)"
    Write-Log "Publisher                    : $($manifest.Publisher)"
    Write-Log "SoftwareVersion              : $($manifest.SoftwareVersion)"
    Write-Log "Detection Path               : $($manifest.Detection.FilePath)"
    Write-Log "Detection File               : $($manifest.Detection.FileName)"
    Write-Log ""

    # --- Network share ---
    if (-not (Test-NetworkShareAccess -Path $FileServerPath)) {
        throw "Network root path not accessible: $FileServerPath"
    }

    $publish = Publish-StagedContentToNetwork `
        -FileServerPath $FileServerPath `
        -PathPattern $ApplicationSharePattern `
        -Manifest $manifest `
        -LocalContentPath $localContentPath `
        -ManifestPath $manifestPath `
        -PSAppDeployToolkitPath $PSAppDeployToolkitPath `
        -SkipStageManifestCopy

    $networkAppRoot = $publish.NetworkAppRoot
    #$networkContentPath = $publish.NetworkContentPath
    $manifest = $publish.Manifest

    Write-Log "Starting to create MECM application..."
    # --- MECM application ---
    New-MECMApplicationFromManifest `
        -Manifest $manifest `
        -AppNamePattern $AppNamePattern `
        -SiteCode $SiteCode `
        -MCMAppFolder $MECMApplicationFolder `
        -Comment $Comment `
        -NetworkContentPath $networkAppRoot `
        -PSAppDeployToolkitPath $PSAppDeployToolkitPath `
        -EstimatedRuntimeMins $EstimatedRuntimeMins `
        -MaximumRuntimeMins $MaximumRuntimeMins
}


# --- Latest-only mode ---
if ($GetLatestVersionOnly) {
    try {
        $ProgressPreference = 'SilentlyContinue'
        $info = Get-LatestNotepadPlusPlusVersion -Quiet
        if (-not $info) { exit 1 }
        Write-Output $info.Version
        exit 0
    }
    catch {
        exit 1
    }
}

# --- Main ---
try {
    $startLocation = Get-Location

    Write-Log ""
    Write-Log ("=" * 60)
    Write-Log "$AppName Auto-Packager starting"
    Write-Log ("=" * 60)
    Write-Log ""
    Write-Log ("RunAsUser                    : {0}\{1}" -f $env:USERDOMAIN,$env:USERNAME)
    Write-Log ("Machine                      : {0}" -f $env:COMPUTERNAME)
    Write-Log "Start location               : $startLocation"
    Write-Log "SiteCode                     : $SiteCode"
    Write-Log "FileServerPath               : $FileServerPath"
    Write-Log "BaseDownloadRoot             : $BaseDownloadRoot"
    Write-Log "GitHubApiUrl                 : $GitHubApiUrl"
    Write-Log ""

    if ($StageOnly) {
        Invoke-StageNotepadPlusPlus
    }
    elseif ($PackageOnly) {
        Invoke-PackageNotepadPlusPlus
    }
    else {
        Invoke-StageNotepadPlusPlus
        Invoke-PackageNotepadPlusPlus
    }

    Write-Log ""
    Write-Log "Script execution complete."
}
catch {
    Write-LogErrorRecord -ErrorRecord $_ -Context 'package-notepadplusplus'
    Write-Log "SCRIPT FAILED: $($_.Exception.Message)" -Level ERROR
    exit 1
}
finally {
    Set-Location $startLocation -ErrorAction SilentlyContinue
}
