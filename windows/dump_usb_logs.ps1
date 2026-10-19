# Copy the log-bearing partitions of a Googlebook-on-Pixelbook USB drive into files, read-only.
# Windows does not mount these Linux/Android partitions, so they are read as raw bytes.
#
# Run from an *Administrator* PowerShell, in the repository root:
#   powershell -ExecutionPolicy Bypass -File pixelbook\windows\dump_usb_logs.ps1            (lists disks)
#   powershell -ExecutionPolicy Bypass -File pixelbook\windows\dump_usb_logs.ps1 -DiskNumber N
#
# Opens the disk for reading only and never writes to it. Refuses to run on a disk whose
# partition layout does not match the Pixelbook image (so the wrong disk cannot be picked by accident).
param([int]$DiskNumber = -1, [string]$Out = "build\pixelbook\usb-dump", [switch]$IncludeUserdata)
$ErrorActionPreference = "Stop"

# GPT partition number, name and exact size in the image (pixelbook-googlebook-eve.img).
# (An array of objects on purpose: an [ordered] table indexed by an int is positional, not by key.)
$want = @(
    [pscustomobject]@{ Number = 33; Name = "GBLOG";    Size = 268435456 },
    [pscustomobject]@{ Number = 17; Name = "metadata"; Size = 67108864 },
    [pscustomobject]@{ Number = 24; Name = "misc";     Size = 4194304 }
)
# userdata is 4 GB of mostly empty space; only copied when asked for (-IncludeUserdata).
if ($IncludeUserdata) { $want += [pscustomobject]@{ Number = 1; Name = "userdata"; Size = 4336885760 } }

if ($DiskNumber -lt 0) {
    Get-Disk | Format-Table Number, FriendlyName, BusType, PartitionStyle, @{n = "SizeGB"; e = { [math]::Round($_.Size / 1GB, 1) } }, IsBoot, IsSystem
    Write-Host "Run again with -DiskNumber <Number of the USB drive>."
    exit 0
}

$disk = Get-Disk -Number $DiskNumber
if ($disk.IsBoot -or $disk.IsSystem) { throw "Disk $DiskNumber is a Windows boot/system disk; refusing." }

# Show what Windows sees, so a mismatch can be diagnosed.
$parts = Get-Partition -DiskNumber $DiskNumber
Write-Host "Disk $DiskNumber has $($parts.Count) partitions."
$bad = @()
foreach ($w in $want) {
    $p = $parts | Where-Object { $_.PartitionNumber -eq $w.Number }
    if (-not $p) { $bad += "partition $($w.Number) ($($w.Name)) is missing"; continue }
    if ($p.Size -ne $w.Size) { $bad += "partition $($w.Number) ($($w.Name)) is $($p.Size) bytes, expected $($w.Size)" }
}
if ($bad.Count) {
    $parts | Format-Table PartitionNumber, Offset, Size, Type -AutoSize
    throw ("Disk $DiskNumber does not match the Pixelbook image: " + ($bad -join "; "))
}

New-Item -ItemType Directory -Force $Out | Out-Null
$stream = New-Object System.IO.FileStream("\\.\PhysicalDrive$DiskNumber", [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
try {
    $buf = New-Object byte[] (4MB)
    foreach ($w in $want) {
        $p = $parts | Where-Object { $_.PartitionNumber -eq $w.Number }
        $file = Join-Path $Out ("p{0:D2}-{1}.img" -f $w.Number, $w.Name)
        if ((Test-Path $file) -and ((Get-Item $file).Length -eq $p.Size)) {
            Write-Host "skipping partition $($w.Number) ($($w.Name)): already copied"
            continue
        }
        Write-Host ("reading partition {0} ({1}, {2:N0} MB) -> {3}" -f $w.Number, $w.Name, ($p.Size / 1MB), $file)
        $dst = [System.IO.File]::Create($file)
        try {
            $stream.Position = $p.Offset
            $left = $p.Size
            while ($left -gt 0) {
                $len = [int][math]::Min([long]$buf.Length, [long]$left)
                $got = $stream.Read($buf, 0, $len)
                if ($got -le 0) { throw "short read" }
                $dst.Write($buf, 0, $got)
                $left -= $got
            }
        } finally { $dst.Close() }
    }
} finally { $stream.Close() }
Write-Host "Done. Files are in $Out"
