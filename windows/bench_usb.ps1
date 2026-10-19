# Read-only speed test of the USB drive that holds the Pixelbook image.
# Android's first boot is dominated by small random reads, so 4 KiB random-read speed matters most.
#
# Run from an *Administrator* PowerShell:
#   powershell -ExecutionPolicy Bypass -File pixelbook\windows\bench_usb.ps1 -DiskNumber 1
#
# Reads only (inside the image's 'super' partition region, which this test never modifies).
param([Parameter(Mandatory = $true)][int]$DiskNumber)
$ErrorActionPreference = "Stop"

$disk = Get-Disk -Number $DiskNumber
if ($disk.IsBoot -or $disk.IsSystem) { throw "Disk $DiskNumber is a Windows boot/system disk; refusing." }
Write-Host ("Disk {0}: {1}, {2} GB, bus {3}" -f $DiskNumber, $disk.FriendlyName, [math]::Round($disk.Size / 1GB, 1), $disk.BusType)

$stream = New-Object System.IO.FileStream("\\.\PhysicalDrive$DiskNumber", [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite, 1)
try {
    $rng = New-Object System.Random 12345
    $base = [long]1GB          # start of the tested region
    $span = [long]6GB          # region size; far larger than any cache
    function Test-Random([int]$blockSize, [double]$seconds) {
        $buf = New-Object byte[] $blockSize
        $blocks = [long]($span / $blockSize)
        $n = 0; $bytes = 0L
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $seconds) {
            $off = $base + [long]($rng.NextDouble() * $blocks) * $blockSize
            $stream.Position = $off
            $got = $stream.Read($buf, 0, $blockSize)
            $n++; $bytes += $got
        }
        $t = $sw.Elapsed.TotalSeconds
        [pscustomobject]@{ Block = "$($blockSize / 1KB) KiB random"; IOPS = [math]::Round($n / $t); MBps = [math]::Round($bytes / $t / 1MB, 2) }
    }
    function Test-Sequential([double]$seconds) {
        $buf = New-Object byte[] (1MB)
        $stream.Position = $base + $span + 1GB
        $bytes = 0L
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $seconds) { $bytes += $stream.Read($buf, 0, $buf.Length) }
        [pscustomobject]@{ Block = "1 MiB sequential"; IOPS = ""; MBps = [math]::Round($bytes / $sw.Elapsed.TotalSeconds / 1MB, 2) }
    }
    $r = @()
    $r += Test-Random 4096 10
    $r += Test-Random 65536 6
    $r += Test-Sequential 8
    $r | Format-Table -AutoSize
    Write-Host "Rule of thumb for this project: 4 KiB random reads under ~2 MB/s mean a first boot of 30+ minutes;"
    Write-Host "a SATA/NVMe-class USB SSD typically gives 20-60 MB/s there."
} finally { $stream.Close() }
