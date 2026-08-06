#Requires -RunAsAdministrator
Set-Location -Path $PSScriptRoot

<#
.SYNOPSIS
MultiOS-USB Installer & Updater for Windows (UEFI Only)
© 2020-2026 MexIT
https://gitlab.com/MultiOS-USB
https://github.com/Mexit/MultiOS-USB
Read LICENSE file for details
#>

$ErrorActionPreference = "Stop"

# Define human-readable table format for disks
$diskTableFormat = @(
    "Number",
    "FriendlyName",
    @{Label="Size (GB)"; Expression={"{0:N2}" -f ($_.Size / 1GB)}; Alignment="Right"},
    "BusType",
    "OperationalStatus"
)

# Convert a size string like "5GB" or "2048MB" (or a plain byte count) to bytes
function Convert-SizeString {
    param([string]$SizeStr)

    if ($SizeStr -match '^\s*(\d+(\.\d+)?)\s*(MB|GB|TB)\s*$') {
        $num = [double]$Matches[1]
        switch ($Matches[3]) {
            "MB" { return [UInt64]($num * 1MB) }
            "GB" { return [UInt64]($num * 1GB) }
            "TB" { return [UInt64]($num * 1TB) }
        }
    } elseif ($SizeStr -match '^\s*\d+\s*$') {
        return [UInt64]$SizeStr
    }

    throw "Invalid size format: '$SizeStr'. Use formats like 5GB, 2048MB, or a raw byte count."
}

# Run robocopy and treat exit codes >= 8 as real failures.
function Invoke-RobocopySafe {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$Options = @("/E")
    )

    $robocopyArgs = @($Source, $Destination) + $Options + @("/MT:8", "/NP", "/NFL", "/NDL", "/NJH", "/NJS")
    robocopy @robocopyArgs | Out-Null
    $exitCode = $LASTEXITCODE

    if ($exitCode -ge 8) {
        throw "Robocopy failed while copying '$Source' to '$Destination' (exit code $exitCode)."
    }

    return $exitCode
}

# Set GPT partition attribute bits via diskpart
function Set-PartitionGptAttributes {
    param(
        [int]$DiskNumber,
        [int]$PartitionNumber,
        [string]$AttributesHex
    )

    $tempFile = [System.IO.Path]::GetTempFileName()
    @"
select disk $DiskNumber
select partition $PartitionNumber
gpt attributes=$AttributesHex
"@ | Out-File -FilePath $tempFile -Encoding ascii

    diskpart /s $tempFile | Out-Null
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
}

# Temporarily disable AutoPlay so Explorer doesn't pop up when new volumes appear
$script:AutoPlayRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\AutoplayHandlers"
$script:AutoPlayOriginalValue = $null
$script:AutoPlayWasDisabled = $false

function Disable-AutoPlayTemporarily {
    try {
        if (!(Test-Path $script:AutoPlayRegPath)) {
            New-Item -Path $script:AutoPlayRegPath -Force | Out-Null
        }

        $existing = Get-ItemProperty -Path $script:AutoPlayRegPath -Name "DisableAutoplay" -ErrorAction SilentlyContinue
        if ($existing) {
            $script:AutoPlayOriginalValue = $existing.DisableAutoplay
        } else {
            $script:AutoPlayOriginalValue = $null
        }

        Set-ItemProperty -Path $script:AutoPlayRegPath -Name "DisableAutoplay" -Value 1 -Type DWord
        $script:AutoPlayWasDisabled = $true

        Restart-Service -Name ShellHWDetection -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "Warning: Could not disable AutoPlay. Explorer windows may pop up during formatting." -ForegroundColor Yellow
    }
}

function Restore-AutoPlaySetting {
    if (-not $script:AutoPlayWasDisabled) { return }

    try {
        if ($null -ne $script:AutoPlayOriginalValue) {
            Set-ItemProperty -Path $script:AutoPlayRegPath -Name "DisableAutoplay" -Value $script:AutoPlayOriginalValue -Type DWord
        } else {
            Remove-ItemProperty -Path $script:AutoPlayRegPath -Name "DisableAutoplay" -ErrorAction SilentlyContinue
        }

        Restart-Service -Name ShellHWDetection -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "Warning: Could not restore the original AutoPlay setting." -ForegroundColor Yellow
    }
}

# Find the drive letters of an already-installed MultiOS-USB
function Get-MultiOsDriveLetters {
    param([int]$DiskNumber)

    $efiLetter = $null
    $efiPartitionNumber = $null
    $efiLetterWasAssigned = $false

    $dataLetter = $null
    $dataPartitionNumber = $null
    $dataLetterWasAssigned = $false

    $partitions = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue
    foreach ($p in $partitions) {
        $assignedNow = $false

        if (-not $p.DriveLetter) {
            try {
                Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber -AssignDriveLetter -ErrorAction Stop | Out-Null
                $p = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber -ErrorAction Stop
                $assignedNow = $true
            } catch {
                continue
            }
        }

        if (-not $p.DriveLetter) { continue }

        $vol = Get-Volume -Partition $p -ErrorAction SilentlyContinue
        if (-not $vol) { continue }

        if ($vol.FileSystemLabel -eq "MultiOS-EFI") {
            $efiLetter = $p.DriveLetter
            $efiPartitionNumber = $p.PartitionNumber
            $efiLetterWasAssigned = $assignedNow
        }
        if ($vol.FileSystemLabel -eq "MultiOS-USB") {
            $dataLetter = $p.DriveLetter
            $dataPartitionNumber = $p.PartitionNumber
            $dataLetterWasAssigned = $assignedNow
        }
    }

    return [PSCustomObject]@{
        EfiLetter             = $efiLetter
        EfiPartitionNumber    = $efiPartitionNumber
        EfiLetterWasAssigned  = $efiLetterWasAssigned
        DataLetter            = $dataLetter
        DataPartitionNumber   = $dataPartitionNumber
        DataLetterWasAssigned = $dataLetterWasAssigned
    }
}

function Update-MultiOsUsb {
    param(
        [string]$SourceRoot,
        [string]$EfiDrive,
        [string]$DataDrive
    )

    Write-Host "`n[1/3] Updating EFI/boot files ($EfiDrive)..." -ForegroundColor Cyan
    Invoke-RobocopySafe -Source (Join-Path $SourceRoot "part_1") -Destination $EfiDrive -Options @("/E", "/MIR") | Out-Null

    Write-Host "[2/3] Updating MultiOS-USB core files..." -ForegroundColor Cyan
    $srcMultiOsUsb = Join-Path $SourceRoot "part_2\MultiOS-USB"
    $dstMultiOsUsb = Join-Path $DataDrive "MultiOS-USB"
    Invoke-RobocopySafe -Source $srcMultiOsUsb -Destination $dstMultiOsUsb -Options @("/E", "/MIR", "/XD", "config_priv", "tools_priv") | Out-Null

    Write-Host "[3/3] Updating config_priv (existing user files are preserved)..." -ForegroundColor Cyan
    $srcConfigPriv = Join-Path $srcMultiOsUsb "config_priv"
    $dstConfigPriv = Join-Path $dstMultiOsUsb "config_priv"
    if (Test-Path $srcConfigPriv) {
        Invoke-RobocopySafe -Source $srcConfigPriv -Destination $dstConfigPriv -Options @("/E") | Out-Null
    }
}

# Read a MultiOS-USB.version file
function Get-MultiOsVersion {
    param([string]$VersionFilePath)

    if (-not (Test-Path $VersionFilePath)) { return $null }

    $raw = (Get-Content -Path $VersionFilePath -Raw -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $raw = $raw.Trim()

    try {
        return [version]$raw
    } catch {
        Write-Host "Warning: could not parse version string '$raw' in $VersionFilePath." -ForegroundColor Yellow
        return $null
    }
}

# Check for required directories
if (!(Test-Path ".\part_1") -or !(Test-Path ".\part_2")) {
    Write-Host "Error: Directories 'part_1' or 'part_2' not found in the current location!" -ForegroundColor Red
    Write-Host "Make sure you are running the script from the correct folder." -ForegroundColor Yellow
    Exit
}

Write-Host "MultiOS-USB Installer & Updater for Windows (UEFI Only)`n" -ForegroundColor Cyan

# Display USB devices by default
Write-Host "Detected USB devices:" -ForegroundColor Cyan
Write-Host "-------------------------------------------------------------"
$usbDisks = Get-Disk | Where-Object { $_.BusType -eq "USB" }

if ($usbDisks) {
    $usbDisks | Format-Table $diskTableFormat -AutoSize
} else {
    Write-Host "No USB devices detected." -ForegroundColor Yellow
}
Write-Host "-------------------------------------------------------------"

# Prompt for disk or Advanced Mode
$diskNum = Read-Host "Enter disk number, type 'ALL' to list all drives, or 'Q' to quit"

# Handle quick exit (Q or empty Enter)
if ([string]::IsNullOrWhiteSpace($diskNum) -or $diskNum -match "^[Qq]$") {
    Write-Host "Operation cancelled. Exiting..." -ForegroundColor Yellow
    Exit
}

# Handle Advanced Mode (case-sensitive)
if ($diskNum -cmatch "^ALL$") {
    Write-Host "`nWARNING: ADVANCED MODE. Listing all available drives!" -ForegroundColor DarkYellow -BackgroundColor Black
    Write-Host "-------------------------------------------------------------"

    $allDisks = Get-Disk | Where-Object { $_.OperationalStatus -match "Online" }
    if (!$allDisks) {
        Write-Host "Error: No matching devices detected." -ForegroundColor Red
        Exit
    }

    $allDisks | Format-Table $diskTableFormat -AutoSize
    Write-Host "-------------------------------------------------------------"

    $diskNum = Read-Host "Enter the disk number to use, or 'Q' to quit"

    # Handle quick exit for Advanced Mode
    if ([string]::IsNullOrWhiteSpace($diskNum) -or $diskNum -match "^[Qq]$") {
        Write-Host "Operation cancelled. Exiting..." -ForegroundColor Yellow
        Exit
    }

    $targetDisksList = $allDisks
} else {
    $targetDisksList = $usbDisks
}

# Validate selection
$targetDisk = $targetDisksList | Where-Object { $_.Number -eq $diskNum }

if (!$targetDisk) {
    Write-Host "Error: Invalid disk number or device not found in the current list." -ForegroundColor Red
    Exit
}

# Prevent formatting the OS drive
if ($targetDisk.IsSystem -eq $true -or $targetDisk.IsBoot -eq $true) {
    Write-Host "`n[!] CRITICAL ERROR: The selected device is a System or Boot drive!" -ForegroundColor White -BackgroundColor Red
    Write-Host "[!] Operation aborted to prevent destruction of the Operating System." -ForegroundColor White -BackgroundColor Red
    Exit
}

try {
$existingDrives = Get-MultiOsDriveLetters -DiskNumber $diskNum
$scriptMode = "Install"

if ($existingDrives.EfiLetter -and $existingDrives.DataLetter) {
    $efiDrive = "$($existingDrives.EfiLetter):\"
    $dataDrive = "$($existingDrives.DataLetter):\"

    Write-Host "`nMultiOS-USB is already installed on disk $diskNum (EFI: $efiDrive | Data: $dataDrive)." -ForegroundColor Cyan
    Write-Host "-------------------------------------------------------------"
    Write-Host " [1] Update"
    Write-Host " [2] Reinstall from scratch (formats the entire disk, deletes everything)"
    Write-Host " [Q] Quit"
    Write-Host "-------------------------------------------------------------"
    $modeChoice = Read-Host "Choose an option"

    if ([string]::IsNullOrWhiteSpace($modeChoice) -or $modeChoice -match "^[Qq]$") {
        Write-Host "Operation cancelled. Exiting..." -ForegroundColor Yellow
        Exit
    } elseif ($modeChoice -eq "1") {
        $scriptMode = "Update"
    } elseif ($modeChoice -eq "2") {
        $scriptMode = "Install"
    } else {
        Write-Host "Error: Invalid option." -ForegroundColor Red
        Exit
    }
}

if ($scriptMode -eq "Update") {
    $srcVersionPath = Join-Path (Get-Location).Path "part_2\MultiOS-USB\MultiOS-USB.version"
    $dstVersionPath = Join-Path $dataDrive "MultiOS-USB\MultiOS-USB.version"

    $sourceVersion = Get-MultiOsVersion -VersionFilePath $srcVersionPath
    $installedVersion = Get-MultiOsVersion -VersionFilePath $dstVersionPath

    $requiredConfirmWord = "YeS"

    if ($sourceVersion -and $installedVersion) {
        Write-Host "`nInstalled version: $installedVersion | Source (update) version: $sourceVersion" -ForegroundColor Cyan

        if ($sourceVersion -lt $installedVersion) {
            Write-Host "`n++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++" -ForegroundColor Red -BackgroundColor Black
            Write-Host "++   WARNING: This source is OLDER than the installed version!      ++" -ForegroundColor Red -BackgroundColor Black
            Write-Host "++   Installed: $installedVersion   ->   Source: $sourceVersion" -ForegroundColor Red -BackgroundColor Black
            Write-Host "++   This would DOWNGRADE the drive. Files added by the newer       ++" -ForegroundColor Red -BackgroundColor Black
            Write-Host "++   version (outside config_priv/tools_priv/ISOs) may be DELETED.  ++" -ForegroundColor Red -BackgroundColor Black
            Write-Host "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++`n" -ForegroundColor Red -BackgroundColor Black
            $requiredConfirmWord = "DOWNGRADE"
        } elseif ($sourceVersion -eq $installedVersion) {
            Write-Host "The installed version is already up to date ($installedVersion)." -ForegroundColor Green
        }
    } else {
        Write-Host "`nNote: could not determine version numbers (missing or unreadable MultiOS-USB.version file) - proceeding without a version check." -ForegroundColor Yellow
    }

    $confirm = Read-Host "Update this drive with the current source files? Type '$requiredConfirmWord' to continue"

    if ($confirm -cne $requiredConfirmWord) {
        Write-Host "Answer was not '$requiredConfirmWord'. Exiting..." -ForegroundColor Yellow
        Exit
    }

    try {
        Update-MultiOsUsb -SourceRoot (Get-Location).Path -EfiDrive $efiDrive -DataDrive $dataDrive

        Write-Host "`n++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++" -ForegroundColor Green
        Write-Host "++ MultiOS-USB has been successfully updated!                       ++" -ForegroundColor Green
        Write-Host "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++" -ForegroundColor Green
    }
    catch {
        Write-Host "`n==================================================================" -ForegroundColor Red
        Write-Host "Update error!" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Yellow
        Write-Host "==================================================================" -ForegroundColor Red
    }

    Exit
}

# Select MultiOS-USB partition Size
$sizeInput = Read-Host "Enter MultiOS-USB partition size (e.g., 5GB, 2048MB) or press Enter to use maximum space"
$useMaxSize = $false
$dataSize = 0

if ([string]::IsNullOrWhiteSpace($sizeInput)) {
    $useMaxSize = $true
} else {
    try {
        $dataSize = Convert-SizeString $sizeInput
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        Exit
    }
}

Write-Host "`n++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++" -ForegroundColor Red -BackgroundColor Black
Write-Host "++   Are you absolutely sure you want to use the selected device?   ++" -ForegroundColor Red -BackgroundColor Black
Write-Host "++             THIS WILL DELETE ALL DATA ON THE DEVICE              ++" -ForegroundColor Red -BackgroundColor Black
Write-Host "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++`n" -ForegroundColor Red -BackgroundColor Black

$confirm = Read-Host "Are you sure? Type 'YeS' to install MultiOS-USB on disk $diskNum ($($targetDisk.FriendlyName))"

if ($confirm -cne "YeS") {
    Write-Host "Answer was not 'YeS'. Exiting..." -ForegroundColor Yellow
    Exit
}

Disable-AutoPlayTemporarily

try {
    # Clean disk and initialize GPT
    Write-Host "`n[1/5] Cleaning disk and initializing GPT..." -ForegroundColor Cyan

    $diskInfo = Get-Disk -Number $diskNum -ErrorAction Stop
    if ($diskInfo.PartitionStyle -ne "RAW") {
        try {
            Clear-Disk -Number $diskNum -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
        } catch {
            throw "Failed to clean disk $diskNum. The disk may be write-protected, in use by another process, or otherwise inaccessible. Original error: $($_.Exception.Message)"
        }
    } else {
        Write-Host "Disk is brand new (not yet initialized) - skipping Clear-Disk." -ForegroundColor DarkGray
    }
    Initialize-Disk -Number $diskNum -PartitionStyle GPT -ErrorAction Stop

    # Detect and remove a Microsoft Reserved (MSR) partition
    $msrGptType = "{e3c9e316-0b5c-4db8-817d-f92df00215ae}"
    $msrPartitions = Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue | Where-Object { $_.GptType -eq $msrGptType }

    if ($msrPartitions) {
        Write-Host "Removing auto-created Microsoft Reserved (MSR) partition..." -ForegroundColor DarkGray
        foreach ($msr in $msrPartitions) {
            $tempFile = [System.IO.Path]::GetTempFileName()
            @"
select disk $diskNum
select partition $($msr.PartitionNumber)
delete partition override
"@ | Out-File -FilePath $tempFile -Encoding ascii

            diskpart /s $tempFile | Out-Null
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    # Create EFI Partition
    Write-Host "[2/5] Creating and formatting MultiOS-EFI partition as FAT16..." -ForegroundColor Cyan
    $part1 = New-Partition -DiskNumber $diskNum -Size 25MB -GptType "{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}" -AssignDriveLetter:$false -ErrorAction Stop

    # Set GPT attribute bits 0 and 63 (equivalent to: sgdisk -A 1:set:0 -A 1:set:63)
    Set-PartitionGptAttributes -DiskNumber $diskNum -PartitionNumber $part1.PartitionNumber -AttributesHex "0x8000000000000001"

    Format-Volume -Partition $part1 -FileSystem FAT -NewFileSystemLabel "MultiOS-EFI" -Confirm:$false -ErrorAction Stop | Out-Null
    Add-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $part1.PartitionNumber -AssignDriveLetter -ErrorAction Stop | Out-Null

    $part1 = Get-Partition -DiskNumber $diskNum -PartitionNumber $part1.PartitionNumber -ErrorAction Stop
    if (-not $part1.DriveLetter) {
        throw "Failed to assign a drive letter to the EFI partition. No free drive letters may be available on this system."
    }
    $drive1 = $($part1.DriveLetter) + ":\"

    # Create MultiOS-USB Partition (exFAT)
    Write-Host "[3/5] Creating and formatting MultiOS-USB partition..." -ForegroundColor Cyan
    if ($useMaxSize) {
        $part2 = New-Partition -DiskNumber $diskNum -UseMaximumSize -GptType "{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}" -AssignDriveLetter:$false -ErrorAction Stop
    } else {
        $part2 = New-Partition -DiskNumber $diskNum -Size $dataSize -GptType "{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}" -AssignDriveLetter:$false -ErrorAction Stop
    }
    Format-Volume -Partition $part2 -FileSystem exFAT -NewFileSystemLabel "MultiOS-USB" -Confirm:$false -ErrorAction Stop | Out-Null
    Add-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $part2.PartitionNumber -AssignDriveLetter -ErrorAction Stop | Out-Null

    $part2 = Get-Partition -DiskNumber $diskNum -PartitionNumber $part2.PartitionNumber -ErrorAction Stop
    if (-not $part2.DriveLetter) {
        throw "Failed to assign a drive letter to the Data partition. No free drive letters may be available on this system."
    }
    $drive2 = $($part2.DriveLetter) + ":\"

    # Copy files
    Write-Host "[4/5] Copying UEFI boot files to $drive1..." -ForegroundColor Cyan
    Invoke-RobocopySafe -Source ".\part_1" -Destination $drive1 | Out-Null

    Write-Host "[5/5] Copying data files to $drive2..." -ForegroundColor Cyan
    Invoke-RobocopySafe -Source ".\part_2" -Destination $drive2 | Out-Null

    Write-Host "`n++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++" -ForegroundColor Green
    Write-Host "++ MultiOS-USB has been successfully installed! (UEFI Mode)         ++" -ForegroundColor Green
    Write-Host "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++" -ForegroundColor Green
}
catch {
    Write-Host "`n==================================================================" -ForegroundColor Red
    Write-Host "Installation error!" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    Write-Host "==================================================================" -ForegroundColor Red
}
finally {
    Restore-AutoPlaySetting
}
}
finally {
    if ($existingDrives -and $existingDrives.EfiLetterWasAssigned -and $existingDrives.EfiPartitionNumber) {
        $stillThere = Get-Partition -DiskNumber $diskNum -PartitionNumber $existingDrives.EfiPartitionNumber -ErrorAction SilentlyContinue
        if ($stillThere -and $stillThere.DriveLetter -eq $existingDrives.EfiLetter) {
            Remove-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $existingDrives.EfiPartitionNumber -AccessPath "$($existingDrives.EfiLetter):\" -ErrorAction SilentlyContinue
        }
    }
}
