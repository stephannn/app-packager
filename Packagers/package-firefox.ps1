<#
Vendor: Mozilla
App: Mozilla Firefox
CMName: Mozilla Firefox
VendorUrl: https://www.mozilla.org/firefox/enterprise/
CPE: cpe:2.3:a:mozilla:firefox:*:*:*:*:*:*:*:*
ReleaseNotesUrl: https://www.mozilla.org/en-US/firefox/releases/
DownloadPageUrl: https://www.mozilla.org/en-US/firefox/enterprise/

.SYNOPSIS
    Packages Mozilla Firefox (x64) MSI for MECM.

.DESCRIPTION
    Downloads the latest Mozilla Firefox x64 MSI from the official Mozilla
    release servers, stages content to a versioned local folder with file-based
    detection metadata, and creates an MECM Application with file-version-based
    detection.
    Detection uses firefox.exe version >= packaged version in the Program Files
    install path.

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
    Content is staged under: <FileServerPath>\Applications\Mozilla\Firefox\<Version>

.PARAMETER DownloadRoot
    Local root folder for staging downloaded installers.
    Each packager creates a subfolder under this path (e.g., <DownloadRoot>\Firefox).
    Default: C:\temp\ap

.PARAMETER EstimatedRuntimeMins
    Estimated runtime in minutes for the MECM deployment type.
    Default: 15

.PARAMETER MaximumRuntimeMins
    Maximum allowed runtime in minutes for the MECM deployment type.
    Default: 30

.PARAMETER StageOnly
    Runs only the Stage phase: download MSI, generate content wrappers
    and stage manifest.

.PARAMETER PackageOnly
    Runs only the Package phase: read stage manifest, copy content to network,
    create MECM application with file-based detection.

.PARAMETER GetLatestVersionOnly
    Outputs only the latest available Firefox version string and exits.

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
$VersionsJsonUrl  = "https://product-details.mozilla.org/1.0/firefox_versions.json"
$DownloadBase     = "https://releases.mozilla.org/pub/firefox/releases"
$DownloadIconUrl  = ""

$Publisher    = "Mozilla"
$AppName      = "Firefox"
$Language     = "DE"
$Architecture = "x64"

$BaseDownloadRoot = Join-Path $DownloadRoot "Firefox"

# --- Functions ---


function Get-LatestFirefoxVersion {
    param([switch]$Quiet)

    Write-Log "Versions JSON URL            : $VersionsJsonUrl" -Quiet:$Quiet
    $firefoxVersion = "LATEST_FIREFOX_VERSION"

    try {
        $jsonText = Get-PageContentWithFallback -Url $VersionsJsonUrl -Quiet:$Quiet
        if ([string]::IsNullOrWhiteSpace($jsonText)) {
            throw "Could not retrieve $VersionsJsonUrl using either Invoke-WebRequest or curl.exe."
        }

        $json = ConvertFrom-Json $jsonText
        $version = $json."$firefoxVersion"
        if ([string]::IsNullOrWhiteSpace($version)) {
            throw "$firefoxVersion field was empty."
        }

        Write-Log "Latest Firefox version       : $version" -Quiet:$Quiet
        return $version
    }
    catch {
        Write-Log "Failed to get Firefox version: $($_.Exception.Message)" -Level ERROR
        return $null
    }
}


# ---------------------------------------------------------------------------
# Stage phase
# ---------------------------------------------------------------------------

function Invoke-StageFirefox {
    Write-Log ""
    Write-Log ("=" * 60)
    Write-Log "$AppName - STAGE phase"
    Write-Log ("=" * 60)
    Write-Log ""

    Initialize-Folder -Path $BaseDownloadRoot

    # --- Get version ---
    $version = Get-LatestFirefoxVersion
    if (-not $version) { throw "Could not resolve Firefox version." }

    $msiFileName = "Firefox Setup $version.msi"
    
    $downloadUrl = "$DownloadBase/$version/win64/$($Language.ToLower())/" + ($msiFileName -replace ' ', '%20')

    Write-Log "Version                      : $version"
    Write-Log "Installer filename           : $msiFileName"
    Write-Log ""

    # --- Download ---
    $localMsi = Join-Path $BaseDownloadRoot $msiFileName
    Write-Log "Local MSI path               : $localMsi"

    if (-not (Test-Path -LiteralPath $localMsi)) {
        Write-Log "Download URL                 : $downloadUrl"
        Write-Log ""
        Write-Log "Downloading MSI..."
        Invoke-DownloadWithRetry -Url $downloadUrl -OutFile $localMsi
    }
    else {
        Write-Log "Local MSI exists. Skipping download."
    }

    $localIco = Invoke-DownloadIconWithRetry -Url $DownloadIconUrl -OutFile ([IO.Path]::Combine($BaseDownloadRoot, $AppName + ([System.IO.Path]::GetExtension($DownloadIconUrl)))) -AppName $AppName

    Write-Log ""
    Write-Log "PSAppDeployToolkitPath: $PSAppDeployToolkitPath"

    # --- Extract MSI properties ---
    $props = Get-MsiPropertyMap -MsiPath $localMsi

    $productVersionRaw = $props["ProductVersion"]

    # --- Versioned local content folder ---
    $localContentPath = Join-Path $BaseDownloadRoot $version
    Initialize-Folder -Path $localContentPath

    $stagedMsi = Join-Path $localContentPath $msiFileName
    if (-not (Test-Path -LiteralPath $stagedMsi)) {
        Copy-Item -LiteralPath $localMsi -Destination $stagedMsi -Force -ErrorAction Stop
        Write-Log "Copied MSI to staged folder  : $stagedMsi"
    }
    else {
        Write-Log "Staged MSI exists. Skipping copy."
    }
    if(-not (Test-Path -LiteralPath (Join-Path $localContentPath ([System.IO.Path]::GetFileName($localIco))))) {
        Copy-Item -LiteralPath $localIco -Destination (Join-Path $localContentPath ([System.IO.Path]::GetFileName($localIco))) -Force -ErrorAction Stop
        Write-Log "Copied ICO to staged folder  : $localContentPath"
    }
    else {
        Write-Log "Staged ICO exists. Skipping copy."
    }

    if([string]::IsNullOrWhiteSpace($PSAppDeployToolkitPath) -eq $true -or (Test-Path -LiteralPath $PSAppDeployToolkitPath) -eq $false) {
        # --- Generate content wrappers ---
        # Install uses standard MSI wrapper
        $wrappers = New-MsiWrapperContent -MsiFileName $msiFileName

        # Firefox MSI is a thin wrapper around the EXE installer. msiexec /x
        # returns 1605 because the product isn't registered as an MSI install.
        # Use the native uninstaller (helper.exe /S) instead.
        $customUninstall = (
            '$helperPath = Join-Path $env:ProgramFiles ''Mozilla Firefox\uninstall\helper.exe''',
            'if (-not (Test-Path -LiteralPath $helperPath)) { exit 0 }',
            '$proc = Start-Process -FilePath $helperPath -ArgumentList @(''/S'') -Wait -PassThru -NoNewWindow',
            'exit $proc.ExitCode'
        ) -join "`r`n"

        Write-ContentWrappers -OutputPath $localContentPath `
            -InstallPs1Content $wrappers.Install `
            -UninstallPs1Content $customUninstall

    }

    # --- Write stage manifest ---
    $detectionPath = "{0}\Mozilla Firefox" -f $env:ProgramFiles

    Write-Log ""
    Write-Log "Detection path               : $detectionPath"
    Write-Log "Detection file               : firefox.exe"
    Write-Log ""

    $manifestPath = Join-Path $localContentPath "stage-manifest.json"
    Write-StageManifest -Path $manifestPath -ManifestData @{
        AppName         = $AppName
        DisplayName     = $AppName
        Publisher       = $Publisher
        SoftwareVersion = $version
        InstallerFile   = $msiFileName
        InstallerType   = "MSI"
        InstallArgs     = "/qn /norestart"
        UninstallArgs   = "/qn /norestart"
        RunningProcess  = @("firefox")
        Detection       = @{
            Type      = "Compound"
            Connector = "AND"  # Set to "And" or "Or"
            Clauses   = @(
                @{
                    Type          = "File"
                    FilePath      = $detectionPath
                    FileName      = "firefox.exe"
                    PropertyType  = "Version"
                    Operator      = "GreaterEquals"
                    ExpectedValue = $productVersionRaw
                    Is64Bit       = $true
                },
                @{
                    Type                = "RegistryKey"
                    RegistryKeyRelative = "SOFTWARE\SCCM\$($Publisher)_$($AppName)_$($productVersionRaw)_$($Language)_$($Architecture)_01"
                    Is64Bit             = $arpEntry.Is64Bit
                }
            )
        }
        IconFileName    = if($localIco -and (Test-Path -LiteralPath $localIco)) { $AppName + ([System.IO.Path]::GetExtension($DownloadIconUrl)) } else { "" }
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

function Invoke-PackageFirefox {
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
        $v = Get-LatestFirefoxVersion -Quiet
        if (-not $v) { exit 1 }
        Write-Output $v
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
    Write-Log "VersionsJsonUrl              : $VersionsJsonUrl"
    Write-Log ""

    if ($StageOnly) {
        Invoke-StageFirefox
    }
    elseif ($PackageOnly) {
        Invoke-PackageFirefox
    }
    else {
        Invoke-StageFirefox
        Invoke-PackageFirefox
    }

    Write-Log ""
    Write-Log "Script execution complete."
}
catch {
    Write-LogErrorRecord -ErrorRecord $_ -Context 'package-firefox'
    Write-Log "SCRIPT FAILED: $($_.Exception.Message)" -Level ERROR
    exit 1
}
finally {
    Set-Location $startLocation -ErrorAction SilentlyContinue
}
