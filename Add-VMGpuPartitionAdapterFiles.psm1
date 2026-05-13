if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue

    if (-not $pwsh) {
        Write-Host ""
        Write-Host "ERROR: PowerShell 7 (pwsh) was not found." -ForegroundColor Red
        Write-Host "Please install PowerShell 7 and run this script again." -ForegroundColor Yellow
        Write-Host "Example: winget install --id Microsoft.PowerShell --source winget" -ForegroundColor Cyan
        Write-Host ""
        exit 1
    }

    if (-not $PSCommandPath) {
        Write-Host ""
        Write-Host "ERROR: This script must be run from a saved .ps1 file." -ForegroundColor Red
        Write-Host ""
        exit 1
    }

    Write-Host "Opening a new PowerShell 7 window..." -ForegroundColor Yellow
    Start-Process -FilePath $pwsh.Source -ArgumentList @(
        '-NoExit',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`""
    )
    exit
}

Import-Module Hyper-V -ErrorAction Stop

function Add-VMGpuPartitionAdapterFiles {
    param(
        [string]$hostname = $ENV:COMPUTERNAME,
        [string]$DriveLetter,
        [string]$GPUName
    )

    if (-not ($DriveLetter -like "*:*")) {
        $DriveLetter = $DriveLetter + ":"
    }

    if ($GPUName -eq "AUTO") {
        $PartitionableGPUList = Get-WmiObject -Class "Msvm_PartitionableGpu" -ComputerName $env:COMPUTERNAME -Namespace "ROOT\virtualization\v2"
        $DevicePathName = $PartitionableGPUList.Name | Select-Object -First 1
        $GPU = Get-PnpDevice | Where-Object {
            ($_.DeviceID -like "*$($DevicePathName.Substring(8,16))*") -and ($_.Status -eq "OK")
        } | Select-Object -First 1
        $GPUName = $GPU.FriendlyName
        $GPUServiceName = $GPU.Service
    }
    else {
        $GPU = Get-PnpDevice | Where-Object {
            (($_.FriendlyName -eq $GPUName) -or ($_.Name -eq $GPUName)) -and ($_.Status -eq "OK")
        } | Select-Object -First 1
        $GPUServiceName = $GPU.Service
    }

    if (-not $GPU) {
        throw "GPU '$GPUName' not found or not in OK state."
    }

    Write-Host "INFO   : Finding and copying driver files for $GPUName to VM. This could take a while..." -ForegroundColor Cyan

    $Drivers = Get-WmiObject Win32_PNPSignedDriver | Where-Object { $_.DeviceName -eq $GPUName }
    New-Item -ItemType Directory -Path "$DriveLetter\windows\system32\HostDriverStore" -Force | Out-Null

    $servicePath = (Get-WmiObject Win32_SystemDriver | Where-Object { $_.Name -eq $GPUServiceName }).Pathname
    if ($servicePath) {
        $servicePath = $servicePath.Trim('"')
        $parts = $servicePath.Split('\')
        if ($parts.Count -ge 6) {
            $ServiceDriverDir = $parts[0..5] -join('\')
            $ServicedriverDest = ("$DriveLetter" + "\" + ($parts[1..5] -join('\'))).Replace("DriverStore","HostDriverStore")
            if (-not (Test-Path $ServicedriverDest)) {
                Copy-Item -Path $ServiceDriverDir -Destination $ServicedriverDest -Recurse -Force
            }
        }
    }

    foreach ($d in $Drivers) {
        $ModifiedDeviceID = $d.DeviceID -replace "\\", "\\"
        $Antecedent = "\\" + $hostname + "\ROOT\cimv2:Win32_PNPSignedDriver.DeviceID=""$ModifiedDeviceID"""
        $DriverFiles = Get-WmiObject Win32_PNPSignedDriverCIMDataFile | Where-Object { $_.Antecedent -eq $Antecedent }
        $DriverName = $d.DeviceName

        if ($DriverName -like "NVIDIA*") {
            New-Item -ItemType Directory -Path "$DriveLetter\Windows\System32\drivers\Nvidia Corporation\" -Force | Out-Null
        }

        foreach ($i in $DriverFiles) {
            $path = $i.Dependent.Split("=")[1] -replace '\\\\', '\'
            $path2 = $path.Substring(1, $path.Length - 2)

            if ($path2 -like "c:\windows\system32\driverstore\*") {
                $parts = $path2.Split('\')
                if ($parts.Count -ge 6) {
                    $DriverDir = $parts[0..5] -join('\')
                    $driverDest = ("$DriveLetter" + "\" + ($parts[1..5] -join('\'))).Replace("driverstore","HostDriverStore")
                    if (-not (Test-Path $driverDest)) {
                        Copy-Item -Path $DriverDir -Destination $driverDest -Recurse -Force
                    }
                }
            }
            else {
                $ParseDestination = $path2.Replace("c:", "$DriveLetter")
                $Destination = $ParseDestination.Substring(0, $ParseDestination.LastIndexOf('\'))
                if (-not (Test-Path -Path $Destination)) {
                    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
                }
                Copy-Item $path2 -Destination $Destination -Force
            }
        }
    }
}

function Pause-Menu {
    Read-Host "Press Enter to continue"
}

function Write-Header {
    param([string]$Title)

    Write-Host ""
    Write-Host "===================================" -ForegroundColor DarkGray
    Write-Host "      Hyper-V GPU-PV Manager" -ForegroundColor Cyan
    Write-Host "===================================" -ForegroundColor DarkGray
    Write-Host $Title -ForegroundColor Yellow
    Write-Host ""
}

function Show-MainMenu {
    Write-Header "Main Menu"
    Write-Host "1. Add GPU to VM"
    Write-Host "2. Remove GPU from VM"
    Write-Host "3. Update drivers in VM"
    Write-Host "4. Set Hyper-V registry override"
    Write-Host "9. Exit"
    Write-Host ""
}

function Select-FromList {
    param(
        [Parameter(Mandatory)]
        [array]$Items,
        [Parameter(Mandatory)]
        [string]$Title,
        [Parameter(Mandatory)]
        [scriptblock]$DisplayScript
    )

    if (-not $Items -or $Items.Count -eq 0) {
        Write-Host "No items found for: $Title" -ForegroundColor Red
        return $null
    }

    Write-Host $Title -ForegroundColor Yellow
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $text = & $DisplayScript $Items[$i]
        Write-Host "$($i + 1). $text"
    }

    Write-Host ""
    do {
        $choice = Read-Host "Choose a number"
        $parsed = 0
        $valid = [int]::TryParse($choice, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $Items.Count
        if (-not $valid) {
            Write-Host "Invalid selection." -ForegroundColor Red
        }
    } until ($valid)

    return $Items[$parsed - 1]
}

function Get-VMSelection {
    $vms = Get-VM | Sort-Object Name
    return Select-FromList -Items $vms -Title "Choose VM-Name:" -DisplayScript {
        param($item)
        "$($item.Name)  [$($item.State)]"
    }
}

function Get-GPUSelection {
    $gpus = Get-PnpDevice | Where-Object {
        $_.Status -eq "OK" -and $_.Class -eq "Display"
    } | Sort-Object {
        if ([string]::IsNullOrWhiteSpace($_.FriendlyName)) { $_.Name } else { $_.FriendlyName }
    }

    return Select-FromList -Items $gpus -Title "Choose GPU:" -DisplayScript {
        param($item)
        if ([string]::IsNullOrWhiteSpace($item.FriendlyName)) { $item.Name } else { $item.FriendlyName }
    }
}

function Get-GPUDisplayName {
    param([Parameter(Mandatory)]$Gpu)

    if ([string]::IsNullOrWhiteSpace($Gpu.FriendlyName)) {
        return $Gpu.Name
    }

    return $Gpu.FriendlyName
}

function Get-VhdPathFromVm {
    param(
        [Parameter(Mandatory)]
        [string]$VMName
    )

    $vhd = Get-VM -VMName $VMName | Select-Object -Property VMId | Get-VHD | Select-Object -First 1
    if (-not $vhd) {
        throw "No VHD/VHDX found for VM '$VMName'."
    }

    return $vhd.Path
}

function Mount-VMWindowsVolume {
    param(
        [Parameter(Mandatory)]
        [string]$VhdPath
    )

    Write-Host "Mounting VHDX..." -ForegroundColor Cyan
    $volumes = Mount-VHD -Path $VhdPath -Passthru | Get-Disk | Get-Partition | Get-Volume
    $candidates = $volumes | Where-Object { $_.DriveLetter }

    if (-not $candidates) {
        throw "No drive letters found after mounting VHDX."
    }

    $windowsCandidates = @()
    foreach ($vol in $candidates) {
        $letter = "$($vol.DriveLetter):"
        if (Test-Path "$letter\Windows\System32") {
            $windowsCandidates += $vol
        }
    }

    if ($windowsCandidates.Count -eq 1) {
        $driveLetter = "$($windowsCandidates[0].DriveLetter):"
        Write-Host "Detected Windows volume: $driveLetter" -ForegroundColor Green
        return $driveLetter
    }

    $selected = Select-FromList -Items $candidates -Title "Choose mounted Windows drive:" -DisplayScript {
        param($item)
        $label = $item.FileSystemLabel
        $fs = $item.FileSystemType
        $size = [math]::Round(($item.Size / 1GB), 2)
        "$($item.DriveLetter):  Label=$label  FS=$fs  Size=$size GB"
    }

    return "$($selected.DriveLetter):"
}

function Dismount-VMWindowsVolume {
    param(
        [Parameter(Mandatory)]
        [string]$VhdPath
    )

    Write-Host "Dismounting VHDX..." -ForegroundColor Cyan
    Dismount-VHD -Path $VhdPath -ErrorAction SilentlyContinue
}

function Ensure-VMOff {
    param(
        [Parameter(Mandatory)]
        [Microsoft.HyperV.PowerShell.VirtualMachine]$VM
    )

    if ($VM.State -eq 'Running') {
        $answer = Read-Host "Checking if VM is on... it is running. Shut it down now? (y/n)"
        if ($answer -match '^(y|yes)$') {
            Write-Host "Shutting down VM..." -ForegroundColor Cyan
            Stop-VM -VMName $VM.Name -Force
            Start-Sleep -Seconds 3
        }
        else {
            throw "Operation cancelled because VM is running."
        }
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    do {
        $answer = Read-Host "$Prompt (y/n)"
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
        Write-Host "Please answer y or n." -ForegroundColor Red
    } until ($false)
}

function Format-BytesHuman {
    param(
        [Parameter(Mandatory)]
        [UInt64]$Bytes
    )

    if ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }
    elseif ($Bytes -ge 1MB) {
        return "{0:N0} MB" -f ($Bytes / 1MB)
    }
    else {
        return "$Bytes bytes"
    }
}

function Get-GpuVramBytes {
    param(
        [Parameter(Mandatory)]
        [string]$GpuName
    )

    $video = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq $GpuName -or $_.Caption -eq $GpuName
    } | Select-Object -First 1

    $regCandidates = Get-ItemProperty `
        -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*' `
        -ErrorAction SilentlyContinue

    $regMatch = $null

    if ($video -and $video.PNPDeviceID) {
        $pnpParts = $video.PNPDeviceID.Split('&')
        if ($pnpParts.Count -ge 2) {
            $gpuDeviceIdShort = ($pnpParts[0..1] -join '&')
            $regMatch = $regCandidates | Where-Object {
                $_.MatchingDeviceId -like "$gpuDeviceIdShort*"
            } | Select-Object -First 1
        }
    }

    if (-not $regMatch) {
        $regMatch = $regCandidates | Where-Object {
            $_.'HardwareInformation.AdapterString' -eq $GpuName
        } | Select-Object -First 1
    }

    if ($regMatch -and $regMatch.'HardwareInformation.qwMemorySize') {
        return [UInt64]$regMatch.'HardwareInformation.qwMemorySize'
    }

    if ($video -and $video.AdapterRAM -and $video.AdapterRAM -gt 0) {
        return [UInt64]$video.AdapterRAM
    }

    return $null
}

function Read-VramBytes {
    param(
        [Parameter(Mandatory)]
        [string]$GpuName
    )

    $detectedVramBytes = Get-GpuVramBytes -GpuName $GpuName

    Write-Host ""
    Write-Host "Selected GPU: $GpuName" -ForegroundColor Cyan

    if ($detectedVramBytes) {
        Write-Host "Detected GPU VRAM: $(Format-BytesHuman -Bytes $detectedVramBytes)" -ForegroundColor Green
    }
    else {
        Write-Host "Could not reliably detect total GPU VRAM." -ForegroundColor Yellow
    }

    Write-Host "Enter amount to allocate. Examples: 256MB, 512MB, 0.5GB, 1GB, 1.5GB" -ForegroundColor Yellow

    do {
        $raw = (Read-Host "How much VRAM do you want to allocate to the VM").Trim()

        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Host "Please enter a value." -ForegroundColor Red
            continue
        }

        $normalized = $raw.ToUpperInvariant().Replace(' ', '').Replace(',', '.')
        $match = [regex]::Match($normalized, '^([0-9]+(?:\.[0-9]+)?)(MB|GB)?$')

        if (-not $match.Success) {
            Write-Host "Invalid format. Use values like 512MB, 1GB, 0.5GB, 1.25GB." -ForegroundColor Red
            continue
        }

        $num = 0.0
        $ok = [double]::TryParse(
            $match.Groups[1].Value,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$num
        )

        if (-not $ok -or $num -le 0) {
            Write-Host "Please enter a valid positive number." -ForegroundColor Red
            continue
        }

        $unit = $match.Groups[2].Value
        if ([string]::IsNullOrWhiteSpace($unit)) {
            $unit = 'GB'
        }

        switch ($unit) {
            'MB' { $bytes = [UInt64]([math]::Round($num * 1MB)) }
            'GB' { $bytes = [UInt64]([math]::Round($num * 1GB)) }
            default {
                Write-Host "Unsupported unit." -ForegroundColor Red
                continue
            }
        }

        if ($bytes -lt 128MB) {
            Write-Host "Allocation is very low. Please use at least 128MB." -ForegroundColor Red
            continue
        }

        if ($detectedVramBytes -and $bytes -gt $detectedVramBytes) {
            Write-Host "Requested value exceeds detected GPU VRAM ($(Format-BytesHuman -Bytes $detectedVramBytes))." -ForegroundColor Red
            continue
        }

        return $bytes

    } while ($true)
}

function Set-HyperVRegistryOverrideFlow {
    try {
        Write-Header "Set Hyper-V registry override"

        $regPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\HyperV'
        $valueName = 'RequireSupportedDeviceAssignment'
        $valueData = 0

        Write-Host "This will ensure the following registry setting exists:" -ForegroundColor Yellow
        Write-Host "$regPath\$valueName = $valueData (DWORD)" -ForegroundColor Cyan
        Write-Host ""

        if (-not (Read-YesNo -Prompt "Continue")) {
            Write-Host "Cancelled." -ForegroundColor Yellow
            return
        }

        if (-not (Test-Path $regPath)) {
            Write-Host "Registry path does not exist. Creating it..." -ForegroundColor Yellow
            New-Item -Path $regPath -Force | Out-Null
        }
        else {
            Write-Host "Registry path already exists." -ForegroundColor DarkGray
        }

        New-ItemProperty -Path $regPath -Name $valueName -PropertyType DWord -Value $valueData -Force | Out-Null

        $result = Get-ItemProperty -Path $regPath -Name $valueName -ErrorAction Stop

        Write-Host "Registry value set successfully." -ForegroundColor Green
        Write-Host "$valueName = $($result.$valueName)" -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        Pause-Menu
    }
}

function Add-GpuToVmFlow {
    $mounted = $false
    $vhdPath = $null

    try {
        Write-Header "Add GPU to VM"

        $vm = Get-VMSelection
        if (-not $vm) { return }

        Write-Host ""
        $gpu = Get-GPUSelection
        if (-not $gpu) { return }

        $gpuDisplayName = Get-GPUDisplayName -Gpu $gpu
        $vramBytes = Read-VramBytes -GpuName $gpuDisplayName

        Write-Host ""
        Write-Host "Summary:" -ForegroundColor Yellow
        Write-Host "VM          : $($vm.Name)"
        Write-Host "GPU         : $gpuDisplayName"
        Write-Host "VRAM        : $(Format-BytesHuman -Bytes $vramBytes)"
        Write-Host ""

        if (-not (Read-YesNo -Prompt "Continue")) {
            Write-Host "Cancelled." -ForegroundColor Yellow
            return
        }

        Ensure-VMOff -VM $vm

        Write-Host "Adding GPU..." -ForegroundColor Cyan

        if (Get-VMGpuPartitionAdapter -VMName $vm.Name -ErrorAction SilentlyContinue) {
            Write-Host "Existing GPU adapter found. Removing old adapter first..." -ForegroundColor Yellow
            Remove-VMGpuPartitionAdapter -VMName $vm.Name -Confirm:$false
        }

        Set-VM -VMName $vm.Name -GuestControlledCacheTypes $true
        Set-VM -VMName $vm.Name -LowMemoryMappedIoSpace 1GB
        Set-VM -VMName $vm.Name -HighMemoryMappedIoSpace 32GB

        Add-VMGpuPartitionAdapter -VMName $vm.Name
        Set-VMGpuPartitionAdapter -VMName $vm.Name `
            -MinPartitionVRAM $vramBytes `
            -MaxPartitionVRAM $vramBytes `
            -OptimalPartitionVRAM $vramBytes

        $vhdPath = Get-VhdPathFromVm -VMName $vm.Name
        Write-Host "Found VHDX: $vhdPath" -ForegroundColor DarkGray

        $driveLetter = Mount-VMWindowsVolume -VhdPath $vhdPath
        $mounted = $true

        Write-Host "Adding drivers to VHDX..." -ForegroundColor Cyan
        Add-VMGpuPartitionAdapterFiles -hostname $env:COMPUTERNAME -DriveLetter $driveLetter -GPUName $gpuDisplayName

        Write-Host "GPU added and drivers copied successfully." -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        if ($mounted -and $vhdPath) {
            Dismount-VMWindowsVolume -VhdPath $vhdPath
        }
        Pause-Menu
    }
}

function Remove-GpuFromVmFlow {
    try {
        Write-Header "Remove GPU from VM"

        $vm = Get-VMSelection
        if (-not $vm) { return }

        Write-Host ""
        Write-Host "Selected VM: $($vm.Name)" -ForegroundColor Cyan

        if (-not (Read-YesNo -Prompt "Continue")) {
            Write-Host "Cancelled." -ForegroundColor Yellow
            return
        }

        Ensure-VMOff -VM $vm

        if (Get-VMGpuPartitionAdapter -VMName $vm.Name -ErrorAction SilentlyContinue) {
            Write-Host "Removing GPU from VM..." -ForegroundColor Cyan
            Remove-VMGpuPartitionAdapter -VMName $vm.Name -Confirm:$false
            Write-Host "GPU partition adapter removed." -ForegroundColor Green
        }
        else {
            Write-Host "No GPU partition adapter found on this VM." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        Pause-Menu
    }
}

function Update-DriversInVmFlow {
    $mounted = $false
    $vhdPath = $null

    try {
        Write-Header "Update drivers in VM"

        $vm = Get-VMSelection
        if (-not $vm) { return }

        Write-Host ""
        $gpu = Get-GPUSelection
        if (-not $gpu) { return }

        $gpuDisplayName = Get-GPUDisplayName -Gpu $gpu

        Write-Host ""
        Write-Host "Summary:" -ForegroundColor Yellow
        Write-Host "VM          : $($vm.Name)"
        Write-Host "GPU         : $gpuDisplayName"
        Write-Host ""

        if (-not (Read-YesNo -Prompt "Continue")) {
            Write-Host "Cancelled." -ForegroundColor Yellow
            return
        }

        Ensure-VMOff -VM $vm

        $vhdPath = Get-VhdPathFromVm -VMName $vm.Name
        Write-Host "Found VHDX: $vhdPath" -ForegroundColor DarkGray

        $driveLetter = Mount-VMWindowsVolume -VhdPath $vhdPath
        $mounted = $true

        Write-Host "Updating drivers in VHDX..." -ForegroundColor Cyan
        Add-VMGpuPartitionAdapterFiles -hostname $env:COMPUTERNAME -DriveLetter $driveLetter -GPUName $gpuDisplayName

        Write-Host "Driver update complete." -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        if ($mounted -and $vhdPath) {
            Dismount-VMWindowsVolume -VhdPath $vhdPath
        }
        Pause-Menu
    }
}

do {
    Show-MainMenu
    $selection = Read-Host "Choose an option"

    switch ($selection) {
        '1' { Add-GpuToVmFlow }
        '2' { Remove-GpuFromVmFlow }
        '3' { Update-DriversInVmFlow }
        '4' { Set-HyperVRegistryOverrideFlow }
        '9' { break }
        default {
            Write-Host "Invalid choice." -ForegroundColor Red
            Pause-Menu
        }
    }
} while ($true)