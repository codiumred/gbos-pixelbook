# Write-speed test of the USB drive that holds the Pixelbook image, using ONLY unused space.
# Android's /data lives on this drive, and its first boot is write-heavy and uses synchronous writes.
#
#   powershell -ExecutionPolicy Bypass -File pixelbook\windows\bench_usb_write.ps1 -DiskNumber 1
#
# Safety: writes only to a 1 GiB window that starts at 24 GiB and is checked to lie beyond the end of
# every partition (the Pixelbook image is about 20.2 GB). Refuses non-USB disks, boot/system disks and
# drives where that window does not fit. Requires an Administrator PowerShell.
param([Parameter(Mandatory = $true)][int]$DiskNumber)
$ErrorActionPreference = "Stop"

$disk = Get-Disk -Number $DiskNumber
if ($disk.IsBoot -or $disk.IsSystem) { throw "Disk $DiskNumber is a Windows boot/system disk; refusing." }
if ($disk.BusType -ne "USB") { throw "Disk $DiskNumber is not a USB disk; refusing." }
$windowStart = [long]24GB
$windowSize = [long]1GB
if ($disk.Size -lt ($windowStart + $windowSize)) { throw "Disk is too small for the test window." }
$parts = Get-Partition -DiskNumber $DiskNumber
$lastEnd = ($parts | ForEach-Object { $_.Offset + $_.Size } | Measure-Object -Maximum).Maximum
if ($lastEnd -gt $windowStart) { throw "A partition ends at $lastEnd, beyond the test window start $windowStart; refusing." }
Write-Host ("Disk {0}: {1}, partitions end at {2:N0} MB, test window {3:N0}-{4:N0} MB" -f $DiskNumber,
    $disk.FriendlyName, ($lastEnd / 1MB), ($windowStart / 1MB), (($windowStart + $windowSize) / 1MB))

$stream = New-Object System.IO.FileStream("\\.\PhysicalDrive$DiskNumber", [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite, 1, [System.IO.FileOptions]::WriteThrough)
try {
    $rng = New-Object System.Random 777
    function Test-Writes([int]$blockSize, [double]$seconds, [bool]$sync) {
        $buf = New-Object byte[] $blockSize
        $rng.NextBytes($buf)
        $blocks = [long]($windowSize / $blockSize)
        $n = 0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $seconds) {
            $stream.Position = $windowStart + [long]($rng.NextDouble() * $blocks) * $blockSize
            $stream.Write($buf, 0, $blockSize)
            if ($sync) { $stream.Flush($true) }
            $n++
        }
        $t = $sw.Elapsed.TotalSeconds
        [pscustomobject]@{ Test = "$($blockSize / 1KB) KiB random write" + $(if ($sync) { ", flushed" } else { "" })
                           IOPS = [math]::Round($n / $t, 1); MBps = [math]::Round($n * $blockSize / $t / 1MB, 3)
                           AvgMs = [math]::Round(1000 * $t / [math]::Max($n, 1), 1) }
    }
    $r = @()
    $r += Test-Writes 4096 10 $true
    $r += Test-Writes 4096 10 $false
    $r += Test-Writes 65536 8 $true
    $buf = New-Object byte[] (1MB); $rng.NextBytes($buf)
    $stream.Position = $windowStart
    $sw = [System.Diagnostics.Stopwatch]::StartNew(); $w = 0
    while ($sw.Elapsed.TotalSeconds -lt 8 -and $w -lt 900) { $stream.Write($buf, 0, $buf.Length); $w++ }
    $r += [pscustomobject]@{ Test = "1 MiB sequential write"; IOPS = ""; MBps = [math]::Round($w / $sw.Elapsed.TotalSeconds, 2); AvgMs = "" }
    $r | Format-Table -AutoSize
} finally { $stream.Close() }
Write-Host "Done. Only the unused window beyond the image was written."
