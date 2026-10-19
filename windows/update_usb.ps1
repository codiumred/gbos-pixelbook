# Update a Googlebook-on-Pixelbook USB stick in place with a new image, writing only what changed.
#
# A full flash (Rufus, DD mode) writes all 28.7 GB; between builds typically only the EFI partition (kernel,
# initrd, boot options), GBRUNCH (/oem) and GBVENDOR change, about 0.5 GB. This script compares the new image
# with the image that is currently on the stick (the "base", i.e. the file you flashed last time), partition by
# partition, and writes:
#   - every partition whose bytes differ between base and new image,
#   - the partitions Android itself writes to at runtime (logs, metadata, misc, persist), so the stick ends up
#     exactly as after a full flash (GBLOG is emptied: copy your logs off first),
#   - the primary and backup partition tables when they differ.
# Userdata is skipped unless -IncludeUserdata (with /data in RAM it is not used).
#
# Safety: refuses Windows boot/system disks and non-USB disks, refuses unless the stick's partition table is
# byte-identical to the base image's (so it really holds the base image) and the partition layout of base and
# new image is the same (otherwise a full flash is needed). Without -Write it only reports what it would do.
# Everything written is read back and compared.
#
# Run from an *Administrator* PowerShell, in the repository root:
#   powershell -ExecutionPolicy Bypass -File pixelbook\windows\update_usb.ps1                       (lists disks)
#   powershell -ExecutionPolicy Bypass -File pixelbook\windows\update_usb.ps1 -DiskNumber N -Base <old.img>
#   powershell -ExecutionPolicy Bypass -File pixelbook\windows\update_usb.ps1 -DiskNumber N -Base <old.img> -Write
param(
    [int]$DiskNumber = -1,
    [string]$Image = "build\pixelbook\pixelbook-googlebook-eve.img",
    [string]$Base = "",
    [switch]$Write,
    [switch]$IncludeUserdata,
    [switch]$PlanOnly        # compare -Base and -Image only; no disk is opened
)
$ErrorActionPreference = "Stop"
$Sector = 512
# partitions Android writes at runtime: always restored from the new image, like a full flash would
$RuntimeWritten = @("GBLOG", "metadata", "misc", "frp_persist", "desktop_security_persist", "desktop_security_storage")

function Read-Bytes([System.IO.Stream]$s, [long]$offset, [int]$count) {
    $buf = New-Object byte[] $count
    $s.Position = $offset
    $got = 0
    while ($got -lt $count) {
        $n = $s.Read($buf, $got, $count - $got)
        if ($n -le 0) { throw "short read at $offset" }
        $got += $n
    }
    return ,$buf
}

function Get-Gpt([System.IO.Stream]$s) {
    $hdr = Read-Bytes $s $Sector $Sector
    if ([System.Text.Encoding]::ASCII.GetString($hdr, 0, 8) -ne "EFI PART") { throw "no GPT" }
    $backupLba = [BitConverter]::ToUInt64($hdr, 32)
    $entLba = [BitConverter]::ToUInt64($hdr, 72)
    $count = [BitConverter]::ToUInt32($hdr, 80)
    $esz = [BitConverter]::ToUInt32($hdr, 84)
    $tableBytes = [long]$count * $esz
    $tableSectors = [long][math]::Ceiling($tableBytes / $Sector)
    $ents = Read-Bytes $s ([long]$entLba * $Sector) ([int]$tableBytes)
    $parts = @()
    for ($i = 0; $i -lt $count; $i++) {
        $e = $i * $esz
        $used = $false
        for ($j = 0; $j -lt 16; $j++) { if ($ents[$e + $j] -ne 0) { $used = $true; break } }
        if (-not $used) { continue }
        $first = [BitConverter]::ToUInt64($ents, $e + 32)
        $last = [BitConverter]::ToUInt64($ents, $e + 40)
        $name = [System.Text.Encoding]::Unicode.GetString($ents, $e + 56, 72).TrimEnd([char]0)
        $type = New-Object Guid (, [byte[]]$ents[$e..($e + 15)])
        $uniq = New-Object Guid (, [byte[]]$ents[($e + 16)..($e + 31)])
        $attr = [BitConverter]::ToUInt64($ents, $e + 48)
        $parts += [pscustomobject]@{ Index = $i + 1; Name = $name; Offset = [long]$first * $Sector; Size = ([long]$last - $first + 1) * $Sector
                                     Type = $type; Unique = $uniq; Attr = $attr }
    }
    # primary: protective MBR + header + entries; backup: entries + header at the end of the image
    $primary = [pscustomobject]@{ Name = "(primary GPT)"; Offset = [long]0; Size = ([long]$entLba + $tableSectors) * $Sector }
    $backup = [pscustomobject]@{ Name = "(backup GPT)"; Offset = ([long]$backupLba - $tableSectors) * $Sector; Size = ($tableSectors + 1) * $Sector }
    return [pscustomobject]@{ Parts = $parts; Primary = $primary; Backup = $backup }
}

function Get-RangeHash([System.IO.Stream]$s, [long]$offset, [long]$size) {
    $h = [System.Security.Cryptography.IncrementalHash]::CreateHash([System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $buf = New-Object byte[] (4MB)
    $s.Position = $offset
    $left = $size
    while ($left -gt 0) {
        $len = [int][math]::Min([long]$buf.Length, $left)
        $got = 0
        while ($got -lt $len) {
            $n = $s.Read($buf, $got, $len - $got)
            if ($n -le 0) { throw "short read at $($s.Position)" }
            $got += $n
        }
        $h.AppendData($buf, 0, $len)
        $left -= $len
    }
    return [BitConverter]::ToString($h.GetHashAndReset()).Replace("-", "")
}

if ($DiskNumber -lt 0 -and -not $PlanOnly) {
    Get-Disk | Format-Table Number, FriendlyName, BusType, PartitionStyle, @{n = "SizeGB"; e = { [math]::Round($_.Size / 1GB, 1) } }, IsBoot, IsSystem
    Write-Host "Run again with -DiskNumber <Number of the USB stick> -Base <image file currently on the stick>."
    exit 0
}
if (-not $Base) { throw "-Base is required: the image file that was flashed to the stick last time" }
$Image = (Resolve-Path $Image).Path
$Base = (Resolve-Path $Base).Path
if ($Image -eq $Base) { throw "-Image and -Base are the same file" }
$imgLen = (Get-Item $Image).Length

if (-not $PlanOnly) {
    $disk = Get-Disk -Number $DiskNumber
    if ($disk.IsBoot -or $disk.IsSystem) { throw "Disk $DiskNumber is a Windows boot/system disk; refusing." }
    if ($disk.BusType -ne "USB") { throw "Disk $DiskNumber is on bus $($disk.BusType), not USB; refusing." }
    if ($disk.Size -lt $imgLen) { throw "Disk $DiskNumber ($($disk.Size) bytes) is smaller than the image ($imgLen bytes)." }
    $lettered = @(Get-Partition -DiskNumber $DiskNumber | Where-Object { $_.DriveLetter })
    if ($lettered.Count) {
        throw ("Disk $DiskNumber has mounted volumes ({0}:). Remove their drive letters in Disk Management first." -f (($lettered | ForEach-Object { $_.DriveLetter }) -join ":, "))
    }
}

$new = [System.IO.File]::OpenRead($Image)
$old = [System.IO.File]::OpenRead($Base)
try {
    $gn = Get-Gpt $new
    $go = Get-Gpt $old
    # same layout: same partitions by name at the same place and size
    foreach ($p in $gn.Parts) {
        $q = $go.Parts | Where-Object { $_.Name -eq $p.Name }
        if (-not $q -or $q.Offset -ne $p.Offset -or $q.Size -ne $p.Size) {
            throw "Partition layout differs between base and new image ($($p.Name)); use a full flash this time."
        }
    }
    if ($gn.Parts.Count -ne $go.Parts.Count) { throw "Partition count differs between base and new image; use a full flash." }

    # the stick must hold the base image: the same partitions (name, type, unique GUID, place, size) as the base.
    # Header fields and partition attribute bits may legitimately differ after a boot (firmware or Android can
    # rewrite them); those are reported and then replaced, since both partition tables are always rewritten.
    if (-not $PlanOnly) {
        $dev = New-Object System.IO.FileStream("\\.\PhysicalDrive$DiskNumber", [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { $gs = Get-Gpt $dev } finally { $dev.Close() }
        $mismatch = @(); $notes = @()
        foreach ($p in $go.Parts) {
            $q = $gs.Parts | Where-Object { $_.Name -eq $p.Name }
            if (-not $q) { $mismatch += "$($p.Name): missing on disk"; continue }
            if ($q.Offset -ne $p.Offset -or $q.Size -ne $p.Size) { $mismatch += "$($p.Name): at $($q.Offset)/$($q.Size), base has $($p.Offset)/$($p.Size)" }
            if ($q.Type -ne $p.Type) { $mismatch += "$($p.Name): type $($q.Type), base has $($p.Type)" }
            if ($q.Unique -ne $p.Unique) { $mismatch += "$($p.Name): GUID $($q.Unique), base has $($p.Unique)" }
            if ($q.Attr -ne $p.Attr) { $notes += ("{0}: attributes 0x{1:x16} on disk, 0x{2:x16} in base" -f $p.Name, $q.Attr, $p.Attr) }
        }
        if ($gs.Parts.Count -ne $go.Parts.Count) { $mismatch += "disk has $($gs.Parts.Count) partitions, base has $($go.Parts.Count)" }
        if ($gs.Backup.Offset -ne $go.Backup.Offset) { $notes += "backup partition table is at $($gs.Backup.Offset) on disk, $($go.Backup.Offset) in base" }
        if ($notes.Count) { Write-Host "Differences that will be overwritten:"; $notes | ForEach-Object { Write-Host "  $_" } }
        if ($mismatch.Count) {
            $mismatch | ForEach-Object { Write-Host "  $_" }
            throw "Disk $DiskNumber does not hold the base image. Use a full flash, or pick the right -Base."
        }
    }

    Write-Host "Comparing $([IO.Path]::GetFileName($Base)) -> $([IO.Path]::GetFileName($Image)) ..."
    $plan = @()
    foreach ($r in @($gn.Primary) + $gn.Parts + @($gn.Backup)) {
        if (-not $IncludeUserdata -and $r.Name -like "userdata*") { continue }
        $hn = Get-RangeHash $new $r.Offset $r.Size
        $why = $null
        if ($r.Name -like "(*") { $why = "partition table, always rewritten" }
        elseif ($RuntimeWritten -contains $r.Name) { $why = "runtime partition, restored" }
        elseif ($hn -ne (Get-RangeHash $old $r.Offset $r.Size)) { $why = "changed" }
        if ($why) { $plan += [pscustomobject]@{ Name = $r.Name; Offset = $r.Offset; Size = $r.Size; Hash = $hn; Why = $why } }
    }
    $total = ($plan | Measure-Object -Property Size -Sum).Sum
    $plan | Format-Table Name, @{n = "MB"; e = { [math]::Round($_.Size / 1MB, 1) } }, Why -AutoSize | Out-String | Write-Host
    Write-Host ("{0} regions, {1:N0} MB to write instead of {2:N0} MB." -f $plan.Count, ($total / 1MB), ($imgLen / 1MB))
    if ($PlanOnly) { exit 0 }
    if (-not $Write) { Write-Host "Dry run. Add -Write to update disk $DiskNumber."; exit 0 }

    # Windows refuses raw writes to sectors of any volume it has, mounted or not, with or without a drive letter or
    # a \\?\Volume{} name (a partition with an unrecognised file system is still a RAW volume). As Rufus does: open
    # every partition's volume device by its kernel path, lock and dismount it, then lock the physical drive and
    # allow I/O past the volume ends. The locks are held until the writes are done; closing the handles releases them.
    # The type name carries a version so a PowerShell window that loaded an older copy still gets this one.
    Add-Type -ErrorAction Stop -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class GbDiskIo3 {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr inBuf, uint inSize, IntPtr outBuf, uint outSize, out uint returned, IntPtr overlapped);
    const uint FSCTL_LOCK_VOLUME = 0x00090018, FSCTL_DISMOUNT_VOLUME = 0x00090020, FSCTL_ALLOW_EXTENDED_DASD_IO = 0x00090083;
    const uint GENERIC_RW = 0xC0000000, SHARE_RW = 3, OPEN_EXISTING = 3, FILE_FLAG_WRITE_THROUGH = 0x80000000;
    static void Lock(SafeFileHandle h, string what) {
        uint n;
        for (int i = 0; ; i++) {
            if (DeviceIoControl(h, FSCTL_LOCK_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out n, IntPtr.Zero)) return;
            if (i == 40) { int e = Marshal.GetLastWin32Error(); throw new Win32Exception(e, "cannot lock " + what + " (close any window or program using the stick)"); }
            System.Threading.Thread.Sleep(250);
        }
    }
    // null when the partition has no volume device (nothing to lock)
    public static SafeFileHandle LockAndDismount(string path) {
        SafeFileHandle h = CreateFile(path, GENERIC_RW, SHARE_RW, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (h.IsInvalid) return null;
        try {
            Lock(h, path);
            uint n;
            if (!DeviceIoControl(h, FSCTL_DISMOUNT_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out n, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "cannot dismount " + path);
        } catch { h.Close(); throw; }
        return h;
    }
    public static SafeFileHandle OpenDrive(int disk) {
        string path = @"\\.\PhysicalDrive" + disk;
        SafeFileHandle h = CreateFile(path, GENERIC_RW, SHARE_RW, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_WRITE_THROUGH, IntPtr.Zero);
        if (h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "cannot open " + path);
        try {
            uint n;
            DeviceIoControl(h, FSCTL_ALLOW_EXTENDED_DASD_IO, IntPtr.Zero, 0, IntPtr.Zero, 0, out n, IntPtr.Zero);
            Lock(h, path);
        } catch { h.Close(); throw; }
        return h;
    }
}
"@
    $locks = @()
    try {
        $vols = @()
        foreach ($p in @(Get-Partition -DiskNumber $DiskNumber)) {
            $vols += "\\.\GLOBALROOT\Device\Harddisk$DiskNumber\Partition$($p.PartitionNumber)"
            $vols += @($p.AccessPaths | Where-Object { $_ -like "\\?\Volume*" } | ForEach-Object { $_.TrimEnd("\") })
        }
        $locked = 0
        foreach ($path in $vols) {
            $h = [GbDiskIo3]::LockAndDismount($path)
            if ($h) { $locks += $h; $locked++ }
        }
        Write-Host "locked and dismounted $locked volume handle(s) on disk $DiskNumber"
        try { Set-Disk -Number $DiskNumber -IsReadOnly $false } catch { }
        $dh = [GbDiskIo3]::OpenDrive($DiskNumber)
        $locks += $dh
        $dev = New-Object System.IO.FileStream($dh, [System.IO.FileAccess]::ReadWrite, 4096)
        try {
            $buf = New-Object byte[] (4MB)
            # partitions first, partition tables last (an interrupted run then still has the old, valid tables)
            $ordered = @($plan | Where-Object { $_.Name -notlike "(*" }) + @($plan | Where-Object { $_.Name -like "(*" })
            foreach ($r in $ordered) {
                Write-Host ("writing {0} ({1:N0} MB)" -f $r.Name, ($r.Size / 1MB))
                $new.Position = $r.Offset
                $dev.Position = $r.Offset
                $left = $r.Size
                while ($left -gt 0) {
                    $len = [int][math]::Min([long]$buf.Length, $left)
                    $got = 0
                    while ($got -lt $len) {
                        $n = $new.Read($buf, $got, $len - $got)
                        if ($n -le 0) { throw "short read from image" }
                        $got += $n
                    }
                    try { $dev.Write($buf, 0, $len) } catch {
                        $cfa = $null
                        try { $cfa = (Get-MpPreference).EnableControlledFolderAccess } catch { }
                        $hint = if ($cfa -eq 1) { " Defender Controlled Folder Access is on and blocks raw disk writes; allow powershell.exe in it or use Rufus." } else { "" }
                        throw ("write to {0} at byte {1:N0} failed: {2}{3}" -f $r.Name, $dev.Position, $_.Exception.InnerException.Message, $hint)
                    }
                    $left -= $len
                }
                $dev.Flush()
            }
            foreach ($r in $ordered) {
                if ((Get-RangeHash $dev $r.Offset $r.Size) -ne $r.Hash) { throw "verification failed for $($r.Name): reflash with Rufus" }
            }
            Write-Host "All regions written and verified."
        } finally { $dev.Close() }
    } finally {
        foreach ($h in $locks) { $h.Close() }
    }
} finally { $new.Close(); $old.Close() }
Write-Host "Done. Disk $DiskNumber now holds $([IO.Path]::GetFileName($Image)). Keep that file: it is the -Base for the next update."
