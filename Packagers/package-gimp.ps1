<#
Vendor: The GIMP Team
App: GIMP (x64)
CMName: GIMP
VendorUrl: https://www.gimp.org/
CPE: cpe:2.3:a:gimp:gimp:*:*:*:*:*:*:*:*
ReleaseNotesUrl: https://www.gimp.org/news/
DownloadPageUrl: https://www.gimp.org/downloads/

.SYNOPSIS
    Packages GIMP (x64) for MECM.

.DESCRIPTION
    Downloads the latest GIMP 3.0.x setup EXE from the GIMP CDN, stages content
    to a versioned local folder with ARP-based detection metadata, and creates an
    MECM Application.

    Supports two-phase operation:
      -StageOnly    Download, generate content wrappers, write manifest
      -PackageOnly  Read manifest, copy to network, create MECM application

    The latest version is resolved by scraping the CDN directory listing for the
    marker file (0.0_LATEST-IS-{version}-{revision}).

.PARAMETER SiteCode
    ConfigMgr site code PSDrive name (e.g., "MCM").

.PARAMETER Comment
    Free-form change/WO text stored on the CM Application Description field.

.PARAMETER FileServerPath
    UNC root that contains your Applications folder (example: \\fileserver\sccm$).
    Content is staged under: <FileServerPath>\Applications\GIMP\GIMP (x64)\<Version>

.PARAMETER DownloadRoot
    Local root folder for staging downloaded installers.
    Default: C:\temp\ap

.PARAMETER EstimatedRuntimeMins
    Estimated runtime in minutes. Default: 15

.PARAMETER MaximumRuntimeMins
    Maximum allowed runtime in minutes. Default: 30

.PARAMETER StageOnly
    Runs only the Stage phase.

.PARAMETER PackageOnly
    Runs only the Package phase.

.PARAMETER GetLatestVersionOnly
    Scrapes the GIMP CDN for the latest version, outputs the version string,
    and exits. No MECM changes are made.

.REQUIREMENTS
    - PowerShell 5.1
    - ConfigMgr Admin Console installed
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
$DownloadPageUrl = "https://download.gimp.org/gimp/v3.0/windows/"
$DownloadIconUrl = "https://www.gimp.org/images/frontpage/wilber-big.png"

$Publisher    = "The GIMP Team"
$AppName      = "GIMP"
$Language     = "MUI"
$Architecture = "x64"

$BaseDownloadRoot = Join-Path $DownloadRoot "GIMP"

# --- Functions ---


function Get-LatestGIMPVersion {
    param([switch]$Quiet)

    Write-Log "CDN directory URL            : $DownloadPageUrl" -Quiet:$Quiet

    try {
        $html = Get-PageContentWithFallback -Url $DownloadPageUrl -Quiet:$Quiet
        if ([string]::IsNullOrWhiteSpace($html)) {
            throw "Could not retrieve $DownloadPageUrl using either Invoke-WebRequest or curl.exe."
        }

        # Look for marker file: 0.0_LATEST-IS-{version}-{revision}
        if ($html -match '0\.0_LATEST-IS-(\d+\.\d+\.\d+)(?:-(\d+))?') {
            $version  = $Matches[1]
            $revision = $Matches[2]
        }
        else {
            throw "Could not find LATEST-IS marker in CDN directory listing."
        }

        # Construct installer filename
        if ($revision -and [int]$revision -gt 1) {
            $fileName = "gimp-$version-setup-$revision.exe"
        }
        elseif ($revision) {
            $fileName = "gimp-$version-setup.exe"
        }
        else {
            $fileName = "gimp-$version-setup.exe"
        }

        Write-Log "Latest GIMP version          : $version (revision: $revision)" -Quiet:$Quiet

        return [PSCustomObject]@{
            Version     = $version
            Revision    = $revision
            FileName    = $fileName
            DownloadUrl = "$DownloadPageUrl$fileName"
        }
    }
    catch {
        Write-Log "Failed to get GIMP version: $($_.Exception.Message)" -Level ERROR
        return $null
    }
}


# ---------------------------------------------------------------------------
# Stage phase
# ---------------------------------------------------------------------------

function Invoke-StageGIMP {
    Write-Log ""
    Write-Log ("=" * 60)
    Write-Log "$AppName - STAGE phase"
    Write-Log ("=" * 60)
    Write-Log ""

    Initialize-Folder -Path $BaseDownloadRoot

    # --- Get latest version ---
    $versionInfo = Get-LatestGIMPVersion
    if (-not $versionInfo) { throw "Could not determine latest GIMP version." }

    $version          = $versionInfo.Version
    $installerFileName = $versionInfo.FileName
    $downloadUrl      = $versionInfo.DownloadUrl

    Write-Log "Download URL                 : $downloadUrl"
    Write-Log "Version                      : $version"
    Write-Log ""

    # --- Download ---
    $localExe = Join-Path $BaseDownloadRoot $installerFileName
    Write-Log "Local installer path         : $localExe"

    if (-not (Test-Path -LiteralPath $localExe)) {
        Write-Log "Downloading GIMP..."
        Invoke-DownloadWithRetry -Url $downloadUrl -OutFile $localExe
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

    Write-Log ""
    Write-Log "PSAppDeployToolkitPath: $PSAppDeployToolkitPath"

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

    # --- Generate content wrappers ---
    $majorVer = $version.Split('.')[0]

    if([string]::IsNullOrWhiteSpace($PSAppDeployToolkitPath) -eq $true -or (Test-Path -LiteralPath $PSAppDeployToolkitPath) -eq $false) {
        $wrapperContent = New-ExeWrapperContent `
            -InstallerFileName $installerFileName `
            -InstallArgs "'/VERYSILENT', '/NORESTART', '/ALLUSERS', '/SP-'" `
            -UninstallCommand "C:\Program Files\GIMP $majorVer\uninst\unins000.exe" `
            -UninstallArgs "'/VERYSILENT', '/NORESTART'"

        Write-ContentWrappers -OutputPath $localContentPath `
            -InstallPs1Content $wrapperContent.Install `
            -UninstallPs1Content $wrapperContent.Uninstall
    }

    # --- Write stage manifest ---
    # GIMP uses a stable InnoSetup ARP key: GIMP-{major}_is1
    $arpRegistryKey = "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\GIMP-${majorVer}_is1"

    Write-Log "ARP Registry Key             : $arpRegistryKey"
    Write-Log ""

    $manifestPath = Join-Path $localContentPath "stage-manifest.json"
    Write-StageManifest -Path $manifestPath -ManifestData @{
        AppName          = $AppName
        DisplayName     = $AppName
        Publisher        = $Publisher
        SoftwareVersion  = $version
        InstallerFile    = $installerFileName
        InstallerType    = "EXE"
        InstallArgs      = "/VERYSILENT /NORESTART /ALLUSERS /SP-"
        UninstallCommand = "C:\Program Files\GIMP $majorVer\uninst\unins000.exe"
        UninstallArgs    = "/VERYSILENT /NORESTART"
        RunningProcess   = @("gimp")
        Detection       = @{
            Type      = "Compound"
            Connector = "AND"  # Set to "And" or "Or"
            Clauses   = @(
                @{
                    Type                = "RegistryKeyValue"
                    RegistryKeyRelative = $arpRegistryKey
                    ValueName           = "DisplayVersion"
                    PropertyType        = "Version"
                    ExpectedValue       = $version
                    Operator            = "GreaterEquals"
                    Is64Bit             = $true
                },
                @{
                    Type                = "RegistryKey"
                    RegistryKeyRelative = "SOFTWARE\SCCM\$($Publisher)_$($AppName)_$($version)_$($Language)_$($Architecture)_01"
                    Is64Bit             = $arpEntry.Is64Bit
                }
            )
        }
        IconFileName    = if($localIco -and (Test-Path -LiteralPath $localIco)) { $AppName + ([System.IO.Path]::GetExtension($DownloadIconUrl)) } else { "" }
    }

    Set-Content -LiteralPath (Join-Path $BaseDownloadRoot "staged-version.txt") -Value $version -Encoding ASCII -ErrorAction Stop

    Write-Log ""
    Write-Log "Stage complete               : $localContentPath"

    return $localContentPath
}


# ---------------------------------------------------------------------------
# Package phase
# ---------------------------------------------------------------------------

function Invoke-PackageGIMP {
    Write-Log ""
    Write-Log ("=" * 60)
    Write-Log "$AppName - PACKAGE phase"
    Write-Log ("=" * 60)
    Write-Log ""

    Initialize-Folder -Path $BaseDownloadRoot

    $versionFile = Join-Path $BaseDownloadRoot "staged-version.txt"
    if (-not (Test-Path -LiteralPath $versionFile)) {
        throw "Version marker not found - run Stage phase first: $versionFile"
    }
    $version = (Get-Content -LiteralPath $versionFile -Raw -ErrorAction Stop).Trim()

    $localContentPath = Join-Path $BaseDownloadRoot $version
    $manifestPath     = Join-Path $localContentPath "stage-manifest.json"

    $manifest = Read-StageManifest -Path $manifestPath

    Write-Log "AppName                      : $($manifest.AppName)"
    Write-Log "Publisher                    : $($manifest.Publisher)"
    Write-Log "SoftwareVersion              : $($manifest.SoftwareVersion)"
    Write-Log ""

    if (-not (Test-NetworkShareAccess -Path $FileServerPath)) {
        throw "Network root path not accessible: $FileServerPath"
    }

    $publish = Publish-StagedContentToNetwork `
        -FileServerPath $FileServerPath `
        -PathPattern $ApplicationSharePattern `
        -Manifest $manifest `
        -LocalContentPath $localContentPath `
        -ManifestPath $manifestPath `
        -PSAppDeployToolkitPath $PSAppDeployToolkitPath

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
        $info = Get-LatestGIMPVersion -Quiet
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
    Write-Log "CdnDirectoryUrl              : $CdnDirectoryUrl"
    Write-Log ""

    if ($StageOnly) {
        Invoke-StageGIMP
    }
    elseif ($PackageOnly) {
        Invoke-PackageGIMP
    }
    else {
        Invoke-StageGIMP
        Invoke-PackageGIMP
    }

    Write-Log ""
    Write-Log "Script execution complete."
}
catch {
    Write-LogErrorRecord -ErrorRecord $_ -Context 'package-gimp'
    Write-Log "SCRIPT FAILED: $($_.Exception.Message)" -Level ERROR
    exit 1
}
finally {
    Set-Location $startLocation -ErrorAction SilentlyContinue
}
