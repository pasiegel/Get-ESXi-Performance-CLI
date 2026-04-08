#Requires -Modules VMware.PowerCLI
<#
.SYNOPSIS
    Collects CPU, Memory, and Disk I/O performance stats for a specified ESXi host
    and all its guest VMs, then exports each to a CSV file.

.NOTES
    Requires VMware PowerCLI: Install-Module VMware.PowerCLI -Scope CurrentUser
#>

# ─── CONFIGURATION ────────────────────────────────────────────────────────────
$vCenterServer = "vcenter.example.com"   # vCenter FQDN/IP (or ESXi host directly)
$esxiHostName  = "esxi01.example.com"    # Target ESXi host name as known to vCenter
$Credential    = Get-Credential           # Prompts for login; or hardcode with:
                                          # [PSCredential]::new("user", (ConvertTo-SecureString "pass" -AsPlainText -Force))

# Time range for stats collection — default is last 24 hours
$StartTime = (Get-Date).AddHours(-24)    # Last 24 hours; adjust as needed
$EndTime   = Get-Date

# Output directory (local machine)
$OutputDir = "$env:USERPROFILE\Desktop"

# Stat interval — "Realtime" (20s, only available ~1hr back) or a seconds integer
# For longer windows use: 300 (5-min), 1800 (30-min), 7200 (2-hr), 86400 (daily)
$IntervalSecs = 300

# Output file paths
$GuestCsvPath = Join-Path $OutputDir "ESXi_Guest_Stats_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
$HostCsvPath  = Join-Path $OutputDir "ESXi_Host_Stats_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
# ──────────────────────────────────────────────────────────────────────────────

# ─── METRICS TO COLLECT ───────────────────────────────────────────────────────
$GuestMetrics = @(
    # CPU — usage, demand, and all scheduling wait states
    "cpu.usage.average",                        # CPU usage %
    "cpu.demand.average",                       # What the VM wants regardless of limit (MHz) — demand > capacity = contention
    "cpu.ready.summation",                      # Time waiting for a physical CPU (ms) — >5% of interval is significant
    "cpu.latency.average",                      # All scheduling latency combined % — broadest contention signal
    "cpu.costop.summation",                     # Multi-vCPU co-scheduling stalls (ms) — common spike cause on VMs with many vCPUs

    # Memory — usage, working set, and pressure indicators
    "mem.usage.average",                        # Memory usage %
    "mem.consumed.average",                     # Memory consumed (KB)
    "mem.active.average",                       # Actual working set (KB) — distinguishes real use from just allocated
    "mem.balloon.average",                      # Balloon driver inflation (KB) — host reclaiming memory under pressure
    "mem.compressed.average",                   # Compressed memory (KB) — stage after ballooning, serious pressure
    "mem.swapped.average",                      # Swapped to disk (KB) — worst case memory pressure

    # Disk throughput and IOPS
    "disk.read.average",                        # Read throughput (KB/s)
    "disk.write.average",                       # Write throughput (KB/s)
    "disk.numberRead.summation",                # Read IOPS proxy
    "disk.numberWrite.summation",               # Write IOPS proxy
    "disk.commandsAborted.summation",           # Aborted SCSI commands — sign of storage faults

    # Virtual disk latency — requires vCenter stats Level 2+
    "virtualDisk.totalReadLatency.average",     # End-to-end read latency (ms) — >20ms worth investigating
    "virtualDisk.totalWriteLatency.average",    # End-to-end write latency (ms)

    # Network — missing entirely from original, saturation can cause CPU wait spikes
    "net.received.average",                     # Receive throughput (KBps)
    "net.transmitted.average",                  # Transmit throughput (KBps)
    "net.droppedRx.summation",                  # Dropped receive packets — NIC/switch saturation
    "net.droppedTx.summation"                   # Dropped transmit packets
)

$HostMetrics = @(
    # CPU
    "cpu.usage.average",
    "cpu.demand.average",                       # Aggregate VM demand vs host capacity
    "cpu.ready.summation",
    "cpu.latency.average",
    "cpu.costop.summation",

    # Memory
    "mem.usage.average",
    "mem.consumed.average",
    "mem.active.average",                       # Total active working set across all VMs
    "mem.balloon.average",                      # Total ballooning across all VMs
    "mem.compressed.average",
    "mem.swapused.average",

    # Disk throughput, IOPS, and latency
    "disk.read.average",
    "disk.write.average",
    "disk.numberRead.summation",
    "disk.numberWrite.summation",
    "disk.commandsAborted.summation",           # Aborted SCSI commands — storage fault indicator
    "disk.busResets.summation",                 # SCSI bus resets — serious storage problem
    "disk.deviceReadLatency.average",           # Physical device read latency (ms)
    "disk.deviceWriteLatency.average",          # Physical device write latency (ms)
    "disk.kernelReadLatency.average",           # VMkernel read latency (ms)
    "disk.kernelWriteLatency.average",          # VMkernel write latency (ms)
    "disk.queueReadLatency.average",            # Queue read latency — high = storage congestion
    "disk.queueWriteLatency.average",           # Queue write latency

    # Network
    "net.received.average",
    "net.transmitted.average",
    "net.droppedRx.summation",
    "net.droppedTx.summation"
)
# ──────────────────────────────────────────────────────────────────────────────

function Format-StatRows {
    <#
        Pivots Get-Stat output (one row per metric per sample) into
        one row per entity per timestamp, with each metric as a column.
    #>
    param([array]$Stats, [string]$EntityType)

    # Group by entity name + timestamp
    $grouped = $Stats | Group-Object { "$($_.Entity.Name)|$($_.Timestamp)" }

    $rows = foreach ($g in $grouped) {
        $parts  = $g.Name -split '\|'
        $entity = $parts[0]
        $ts     = $parts[1]

        $row = [ordered]@{
            EntityType = $EntityType
            Entity     = $entity
            Timestamp  = $ts
        }

        foreach ($stat in $g.Group) {
            # Use MetricId.Instance if present, else MetricId
            $colName = if ($stat.MetricId) { $stat.MetricId } else { $stat.StatType }
            $row[$colName] = [math]::Round($stat.Value, 3)
        }

        [PSCustomObject]$row
    }

    # Return sorted by entity then time
    $rows | Sort-Object Entity, Timestamp
}

# ─── CONNECT ──────────────────────────────────────────────────────────────────
Write-Host "Connecting to $vCenterServer ..." -ForegroundColor Cyan
Connect-VIServer -Server $vCenterServer -Credential $Credential -ErrorAction Stop | Out-Null

try {
    # ─── GET HOST ─────────────────────────────────────────────────────────────
    Write-Host "Fetching host: $esxiHostName" -ForegroundColor Cyan
    $vmHost = Get-VMHost -Name $esxiHostName -ErrorAction Stop

    # ─── COLLECT HOST STATS ───────────────────────────────────────────────────
    Write-Host "Collecting host stats ($StartTime  ->  $EndTime) ..." -ForegroundColor Yellow
    $hostStats = Get-Stat -Entity $vmHost `
                          -Stat $HostMetrics `
                          -Start $StartTime `
                          -Finish $EndTime `
                          -IntervalSecs $IntervalSecs `
                          -ErrorAction SilentlyContinue

    if ($hostStats) {
        $hostRows = Format-StatRows -Stats $hostStats -EntityType "ESXi Host"
        $hostRows | Export-Csv -Path $HostCsvPath -NoTypeInformation -Encoding UTF8
        Write-Host "  Host CSV saved -> $HostCsvPath  ($($hostRows.Count) rows)" -ForegroundColor Green
    } else {
        Write-Warning "No host stats returned. Check interval/time range."
    }

    # ─── GET GUEST VMs ────────────────────────────────────────────────────────
    Write-Host "Fetching VMs on $esxiHostName ..." -ForegroundColor Cyan
    $vms = Get-VM -Location $vmHost -ErrorAction Stop
    Write-Host "  Found $($vms.Count) VMs: $($vms.Name -join ', ')"

    # ─── COLLECT GUEST STATS ──────────────────────────────────────────────────
    Write-Host "Collecting guest stats ..." -ForegroundColor Yellow
    $guestStats = Get-Stat -Entity $vms `
                           -Stat $GuestMetrics `
                           -Start $StartTime `
                           -Finish $EndTime `
                           -IntervalSecs $IntervalSecs `
                           -ErrorAction SilentlyContinue

    if ($guestStats) {
        $guestRows = Format-StatRows -Stats $guestStats -EntityType "Guest VM"
        $guestRows | Export-Csv -Path $GuestCsvPath -NoTypeInformation -Encoding UTF8
        Write-Host "  Guest CSV saved -> $GuestCsvPath  ($($guestRows.Count) rows)" -ForegroundColor Green
    } else {
        Write-Warning "No guest stats returned. Check interval/time range or VM power state."
    }

} finally {
    Disconnect-VIServer -Server $vCenterServer -Confirm:$false
    Write-Host "Disconnected." -ForegroundColor Cyan
}
