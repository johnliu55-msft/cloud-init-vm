param (
    [parameter(Mandatory)][string]$VMName,
    [parameter(Mandatory)][string]$CloudImageUri,
    [string]$MetaDataPath,
    [string]$MetaData,
    [string]$UserDataPath,
    [string]$UserData,
    [string]$WorkingFolder = '.\work',
    [int64]$VMDiskSize = 40GB,
    [int64]$VMMemoryStartupBytes = 2GB,
    [string]$VMSwitchName = 'Default Switch'
)

$ErrorActionPreference = "Continue"

#region Output logging
    function WriteInfo($message) {
        Write-Host $message
    }

    function WriteInfoHighlighted($message) {
        Write-Host $message -ForegroundColor Cyan
    }

    function WriteSuccess($message) {
        Write-Host $message -ForegroundColor Green
    }

    function WriteWarning($message) {
        Write-Host $message -ForegroundColor Yellow
    }

    function WriteError($message) {
        Write-Host $message -ForegroundColor Red
    }

    function WriteErrorAndExit($message) {
        Write-Host $message -ForegroundColor Red
        # Uncomment the following to enable user interaction
        # Write-Host "Press enter to continue ..."
        # Stop-Transcript
        # Read-Host | Out-Null
        Exit
    }
#endregion

function Install-QemuImg {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [parameter(Mandatory)][string]$WorkingFolder
    )

    WriteInfoHighlighted "Install qemu-img for Windows"

    $status = $true

    $tools = "$workingFolder\Tools"
    if (-not(Test-Path -Path $tools)) {
        WriteInfo "$tools doesn't exist. Create a new folder"
        New-Item -Path $tools -ItemType Directory -Force | Out-Null
    }

    #
    # https://cloudbase.it/qemu-img-windows/
    #
    $uri = 'https://cloudbase.it/downloads/qemu-img-win-x64-2_3_0.zip'
    $zip = Split-Path -Path $uri -Leaf
    $target = "$tools\$zip"
    if (-not(Test-Path -Path $target)) {
        Start-BitsTransfer -Source $uri -Destination $target | Out-Null

        if ($? -ne $true) {
            WriteError "Failed to download qemu-img"
        }
    }

    if (-not(Test-Path -Path $target)) {
        WriteError "Unable to download from $uri to $target"
        $status = $false
    }

    if ($status) {

        $qemu = "$tools\qemu-img"
        if (-not(Test-Path -Path "$qemu\qemu-img.exe")) {
            Expand-Archive -Path $target -DestinationPath $qemu | Out-Null
        }

        if (-not(Test-Path -Path "$qemu\qemu-img.exe")) {
            WriteError "Unable to find $qemu\qemu-img.exe"
            $status = $false
        }
    }

    if (-not($status)) {
        return $null
    } else {
        return "$qemu\qemu-img.exe"
    }

}

function Get-CloudImage {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$QemuToolPath,
        [string]$WorkingFolder = '.\work\'
    )

    # Download cloud image
    $img_dir = Join-Path -Path $workingFolder -ChildPath 'images'
    New-Item -Path $img_dir -ItemType Directory -Force | Out-Null
    $img_name = Split-Path -Path $Source -Leaf
    $img_path = Join-Path -Path $img_dir -ChildPath $img_name

    WriteInfoHighlighted "Download $Source into $img_path"
    if (Test-Path $img_path) {
        WriteWarning "Cloud image `"$img_path`" already exists. Will NOT download the specified URI"
        WriteWarning "Remove `"$img_path`" if you want to download image"
    } else {
        Start-BitsTransfer -Source $Source -Destination $img_path | Out-Null
        if (-not($?)) {
            WriteErrorAndExit "Unable to download cloud image"
        }
    }

    # Convert the cloud image to vhdx
    $img_file_base = (Get-Item $img_path).BaseName
    $img_vhdx_path = Join-Path -Path $img_dir -ChildPath "$img_file_base.vhdx"
    WriteInfo "Convert cloud image: $img_path to VHDX: $img_vhdx_path"
    $qemuargs = 'convert', $img_path, '-O', 'vhdx', '-o', 'subformat=dynamic', $img_vhdx_path
    & $QemuToolPath $qemuargs
    if ($LASTEXITCODE -ne 0) {
        return $null
    } else {
        return $img_vhdx_path
    }
}

function New-CloudInitVHDX {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)][string]$Path,
        [string]$MetaDataPath,
        [string]$MetaData,
        [string]$UserDataPath,
        [string]$UserData,
        $Size = 50MB
    )

    if ($MetaData -and $MetaDataPath) {
        throw "Only one of -MetaData or -MetaDataPath should be given"
    } elseif ($MetaDataPath) {
        $MetaData = Get-Content $MetaDataPath -Encoding UTF8 -Raw
    } elseif ($MetaData) {
        # do nothing
    } else {
        throw "Either -MetaData or -MetaDataPath should be provided"
        return
    }

    if ($UserData -and $UserDataPath) {
        throw "Only one of -UserData or -UserDataPath should be given"
        return
    } elseif ($UserDataPath) {
        $UserData = Get-Content $UserDataPath -Encoding UTF8 -Raw
    } elseif ($UserData) {
        # do nothing
    } else {
        throw "Either -UserData or -UserDataPath should be provided"
        return
    }

    if (Test-Path $Path) {
        WriteWarning "Cloud init VHDX `"$Path`" already exists. Not creating new cloud init disk"
        WriteWarning "Delete the VHDX to create a new one with latest cloud-init configs"
        return
    }

    # Create a new VHDX and mount it
    New-VHD -Path $Path -SizeBytes $Size -Fixed | Out-Null
    Mount-VHD -Path $Path | Out-Null
    $disk = get-vhd -path $Path
    Initialize-Disk $disk.DiskNumber | Out-Null
    $partition = New-Partition -AssignDriveLetter -UseMaximumSize -DiskNumber $disk.DiskNumber
    Format-Volume -NewFileSystemLabel 'CIDATA' -FileSystem FAT -Confirm:$false -Force -Partition $partition | Out-Null

    # Copy cloud init data
    $driveletter = (Get-Partition -DiskNumber $disk.DiskNumber -PartitionNumber $partition.PartitionNumber).DriveLetter
    WriteInfo "Drive letter for the VHDX: $driveletter"
    Set-Content -Path "${driveletter}:\meta-data" -Value $MetaData
    Set-Content -Path "${driveletter}:\user-data" -Value $UserData
    WriteInfo "Cloud init config copied"
    #  Unmount the VHD
    WriteInfo "Unmount VHD"
    Dismount-VHD -Path $Path
}

function New-CloudInitVM {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$CloudImageVHDXPath,
        [string]$MetaDataPath,
        [string]$MetaData,
        [string]$UserDataPath,
        [string]$UserData,
        [string]$VMDiskFolder= '.\disks',
        [int64]$VMDiskSize,
        [int64]$VMMemoryStartupBytes = 2GB,
        [string]$VMSwitchName
    )
    $cloud_init_vhdx_path = Join-Path -Path $VMDiskFolder -ChildPath "$Name-cloudinit.vhdx"
    $vm_disk_path = Join-Path -Path $VMDiskFolder -ChildPath "$Name-disk.vhdx"

    # Ensure folders for disks exists
    New-Item -Path $VMDiskFolder -ItemType Directory -Force | Out-Null

    # Create the cloud init VHDX
    New-CloudInitVHDX -Path $cloud_init_vhdx_path -MetaDataPath $MetaDataPath -MetaData $MetaData -UserDataPath $UserDataPath -UserData $UserData

    # Copy the cloud image to prevent overwriting the original VHDX
    Copy-Item -Path $CloudImageVHDXPath -Destination $vm_disk_path
    if ($VMDiskSize) {
        Resize-VHD -Path $vm_disk_path -SizeBytes $VMDiskSize
    }

    # Create VM
    # TODO: Maybe there's a better way to remove this if block?
    if ($VMSwitchName) {
        New-VM -Name $Name -MemoryStartupBytes $VMMemoryStartupBytes -Generation 2 -VHDPath $vm_disk_path -SwitchName $VMSwitchName
    } else {
        New-VM -Name $Name -MemoryStartupBytes $VMMemoryStartupBytes -Generation 2 -VHDPath $vm_disk_path
    }
    Set-VMFirmware -VMName $Name -EnableSecureBoot Off
    Add-VMHardDiskDrive -VMName $Name -Path $cloud_init_vhdx_path
}
function Validate {
    # Validate whether VM name exists
    $vm_exists = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm_exists) {
        WriteErrorAndExit "VM name `"$VMName`" already exists"
    }
}
#region main
# $CLOUDIMAGE_URI = 'https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img'

# Validate arguments
Validate
# Install qemu-img for Windows for converting .img to VHDX
$qemu = Install-QemuImg $WorkingFolder
if (-not($qemu)) {
    WriteErrorAndExit "Unable to install qemu-img"
}
$qemu.GetType()
WriteSuccess "Successfully installed qemu-img for Windows"

# Download and convert the cloud image (".img" file) to VHDX
$converted_vhdx_path = Get-CloudImage -Source $CloudImageUri -QemuToolPath $qemu -WorkingFolder $WorkingFolder
if (-not($converted_vhdx_path)) {
    WriteErrorAndExit "Unable to convert cloud image to VHDX"
}
WriteSuccess "Successfully downloaded and converted cloud image to VHDX: $converted_vhdx_path"

# Create a VM provisioned by cloud-init files
New-CloudInitVM -Name $VMName `
    -CloudImageVHDXPath  $converted_vhdx_path `
    -MetaDataPath $MetaDataPath `
    -MetaData $MetaData `
    -UserDataPath $UserDataPath `
    -UserData $UserData `
    -VMDiskFolder $(Join-Path -Path $WorkingFolder -ChildPath 'disks') `
    -VMDiskSize $VMDiskSize `
    -VMMemoryStartupBytes $VMMemoryStartupBytes `
    -VMSwitchName $VMSwitchName

Start-VM -Name $VMName
#endregion
