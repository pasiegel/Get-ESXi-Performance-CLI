# ESXi Performance Data Collection Script

PowerCLI script that collects CPU, memory, disk I/O, disk latency, and network statistics for a specified ESXi host and all guest VMs running on it, exporting the results to two CSV files on your local machine. Metrics are selected to support root cause analysis of gradual slowness and resource spike patterns.

---

## Prerequisites

### VMware PowerCLI

Install the PowerCLI module if you haven't already (run PowerShell as Administrator):

```powershell
Install-Module VMware.PowerCLI -Scope CurrentUser
```

If your ESXi or vCenter uses a self-signed certificate, suppress the certificate warning:

```powershell
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
```

### Permissions

Your vCenter/ESXi account needs at minimum **Read-Only** access to the target host and its virtual machines.

### vCenter Statistics Level

Some metrics require a higher statistics collection level than the default (Level 1). Set the level under *vCenter > Host > Configure > Statistics*:

| Level | Unlocks |
|---|---|
| 1 (default) | `cpu.usage`, `mem.usage`, `disk.read/write`, `net.received/transmitted` |
| 2 | `cpu.ready`, `cpu.demand`, `cpu.latency`, `cpu.costop`, `mem.active`, `mem.balloon`, `mem.compressed`, `disk.numberRead/Write`, `disk.commandsAborted`, `disk.deviceLatency`, `net.dropped` |
| 3+ | `virtualDisk.totalReadLatency`, `virtualDisk.totalWriteLatency`, `disk.kernelLatency`, `disk.queueLatency`, `disk.busResets` |

> **Recommended:** Set to **Level 2** as a minimum. For the full set of latency metrics collected by this script, set to **Level 3**. Note that higher levels increase vCenter database storage usage.

---

## Configuration

Open `Get-ESXiPerformance.ps1` and edit the variables at the top of the file:

| Variable | Description | Example |
|---|---|---|
| `$vCenterServer` | FQDN or IP of your vCenter Server (or ESXi host directly if no vCenter) | `"vcenter.corp.local"` |
| `$esxiHostName` | Name of the target ESXi host exactly as it appears in vCenter | `"esxi01.corp.local"` |
| `$Credential` | Prompts for credentials at runtime by default | See note below |
| `$StartTime` | Start of the collection window — **defaults to 24 hours ago** | `(Get-Date).AddHours(-24)` |
| `$EndTime` | End of the collection window — defaults to now | `Get-Date` |
| `$IntervalSecs` | Stat rollup interval in seconds — defaults to `300` (5 min) | See interval guide below |
| `$OutputDir` | Local folder where CSVs are saved — defaults to your Desktop | `"C:\Reports"` |

### Credential options

**Option A — prompt at runtime (default, most secure):**
```powershell
$Credential = Get-Credential
```

**Option B — embed in script (less secure, useful for scheduled tasks):**
```powershell
$Credential = [PSCredential]::new("administrator@vsphere.local",
    (ConvertTo-SecureString "YourPassword" -AsPlainText -Force))
```

### Interval guide

| `$IntervalSecs` | Rollup | Max lookback |
|---|---|---|
| `"Realtime"` | 20 seconds | ~1 hour |
| `300` | 5 minutes | ~1 day |
| `1800` | 30 minutes | ~1 week |
| `7200` | 2 hours | ~1 month |
| `86400` | 1 day | ~1 year |

> **Note:** For the default 24-hour window, use `300` (5-min rollups). Realtime data is only retained for approximately one hour by vCenter.

---

## Running the Script

```powershell
cd C:\VMware_Scripts
.\Get-ESXiPerformance.ps1
```

You will be prompted for credentials unless you have embedded them. The script then:

1. Connects to your vCenter/ESXi server
2. Locates the specified ESXi host
3. Collects host-level stats for the defined time period (default: last 24 hours)
4. Discovers all guest VMs on that host
5. Collects guest-level stats for the same time period
6. Exports both datasets to CSV on your local machine
7. Disconnects cleanly

### Custom time range example

To query a specific historical window, edit `$StartTime` and `$EndTime` before running:

```powershell
$StartTime = [datetime]"2026-04-07 08:00:00"
$EndTime   = [datetime]"2026-04-07 10:00:00"
```

---

## Output Files

Both files are written to `$OutputDir` (default: Desktop) with a timestamp in the filename:

| File | Contents |
|---|---|
| `ESXi_Host_Stats_YYYYMMDD_HHmm.csv` | Host-level metrics including network throughput |
| `ESXi_Guest_Stats_YYYYMMDD_HHmm.csv` | Per-VM metrics, one row per VM per sample interval |

### CSV columns

**CPU**

| Column | Unit | Applies to | Notes |
|---|---|---|---|
| `cpu.usage.average` | % | Both | Current utilization |
| `cpu.demand.average` | MHz | Both | What the VM/host *wants* — demand exceeding capacity is a spike trigger |
| `cpu.ready.summation` | ms | Both | Time waiting for a physical CPU — >5% of interval warrants investigation |
| `cpu.latency.average` | % | Both | All scheduling wait states combined — broadest contention indicator |
| `cpu.costop.summation` | ms | Both | Multi-vCPU co-scheduling stalls — common hidden cause of spikes on VMs with many vCPUs |

**Memory**

| Column | Unit | Applies to | Notes |
|---|---|---|---|
| `mem.usage.average` | % | Both | |
| `mem.consumed.average` | KB | Both | |
| `mem.active.average` | KB | Both | Actual working set — distinguishes real pressure from just allocated |
| `mem.balloon.average` | KB | Both | Balloon driver inflation — host is actively reclaiming memory from guests |
| `mem.compressed.average` | KB | Both | Memory compression — occurs after ballooning, serious pressure indicator |
| `mem.swapped.average` / `mem.swapused.average` | KB | Both | Swapped to disk — worst-case memory pressure, major performance impact |

**Disk**

| Column | Unit | Applies to | Notes |
|---|---|---|---|
| `disk.read.average` | KB/s | Both | Read throughput |
| `disk.write.average` | KB/s | Both | Write throughput |
| `disk.numberRead.summation` | count | Both | Read IOPS proxy |
| `disk.numberWrite.summation` | count | Both | Write IOPS proxy |
| `disk.commandsAborted.summation` | count | Both | Aborted SCSI commands — any non-zero value indicates storage faults |
| `disk.busResets.summation` | count | Host | SCSI bus resets — serious storage problem |
| `disk.deviceReadLatency.average` | ms | Host | Physical device read latency |
| `disk.deviceWriteLatency.average` | ms | Host | Physical device write latency |
| `disk.kernelReadLatency.average` | ms | Host | VMkernel read latency |
| `disk.kernelWriteLatency.average` | ms | Host | VMkernel write latency |
| `disk.queueReadLatency.average` | ms | Host | Queue latency — high values mean storage is congested |
| `disk.queueWriteLatency.average` | ms | Host | |
| `virtualDisk.totalReadLatency.average` | ms | Guest | End-to-end read latency — >20ms worth investigating |
| `virtualDisk.totalWriteLatency.average` | ms | Guest | End-to-end write latency |

**Network**

| Column | Unit | Applies to | Notes |
|---|---|---|---|
| `net.received.average` | KBps | Both | Receive throughput |
| `net.transmitted.average` | KBps | Both | Transmit throughput |
| `net.droppedRx.summation` | count | Both | Dropped receive packets — NIC or switch saturation |
| `net.droppedTx.summation` | count | Both | Dropped transmit packets |

---

## Troubleshooting

**Empty CSVs / no stats returned**
- The requested `$IntervalSecs` rollup may not exist for that time range — try a larger interval (e.g. `1800` instead of `300`).
- Check your vCenter statistics level (see Prerequisites above). Missing columns are the most common sign of an insufficient level.

**`virtualDisk.totalReadLatency` / `virtualDisk.totalWriteLatency` columns empty**
- These require vCenter statistics **Level 3** or higher. Go to *vCenter > Host > Configure > Statistics* and raise the level. Changes take effect at the next collection interval.

**`cpu.demand`, `cpu.latency`, `mem.balloon`, `net.dropped` columns empty**
- These require vCenter statistics **Level 2** or higher — the most likely cause if you are on the default Level 1 configuration.

**Network drop columns empty on guests**
- `net.droppedRx/Tx` require Level 2+. If the host shows drops but guests do not, the drops are occurring at the vSwitch or uplink layer rather than within the guest NIC.

**"Could not find VMs" error**
- Verify `$esxiHostName` matches exactly what vCenter shows — including case and domain suffix.
- VMs must be powered on during the collection window to have stats.

**Certificate errors**
```powershell
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
```

**Connecting directly to ESXi (no vCenter)**
- Set `$vCenterServer` to the ESXi host IP/FQDN.
- Historical stat rollups beyond ~1 hour are typically unavailable without vCenter — use `"Realtime"` for recent data only.

---

## Diagnosing Gradual Slowness Leading to Resource Spikes

This script is specifically suited to the pattern of general sluggishness building into CPU/resource spikes. Work through the layers below using the CSV data.

### 1. CPU contention (check first)

| Metric | Threshold | Meaning |
|---|---|---|
| `cpu.ready.summation` | >5% of interval | VMs queued waiting for a physical CPU — host is overcommitted |
| `cpu.demand.average` | Approaching host capacity | VMs want more than the host can give — spike is imminent |
| `cpu.latency.average` | Rising trend before spike | Leading indicator — often climbs before `cpu.usage` does |
| `cpu.costop.summation` | Any sustained value | Multi-vCPU VMs stalling each other — reduce vCPU count if possible |

### 2. Memory pressure (second most common cause)

Pressure cascades: allocation → balloon → compression → swap. Each stage is slower than the last.

| Metric | What to look for |
|---|---|
| `mem.active.average` | If much lower than `mem.consumed`, VMs have over-allocated RAM — reclaim it |
| `mem.balloon.average` | Non-zero and rising = host is reclaiming guest memory, causing guest slowness |
| `mem.compressed.average` | Non-zero = past ballooning, host is CPU-burning to compress memory pages |
| `mem.swapped.average` (guest) | Any value = guest RAM is on disk — severe performance impact |

### 3. Storage latency (often confused with CPU issues)

High disk latency causes guest I/O threads to block, which can appear as CPU wait spikes.

| Metric | Threshold | Meaning |
|---|---|---|
| `virtualDisk.totalReadLatency.average` | >20ms | Guest experiencing storage latency — check datastore/SAN |
| `virtualDisk.totalWriteLatency.average` | >20ms | Same for writes |
| `disk.queueReadLatency.average` (host) | Rising | Storage backend congested — queue building up |
| `disk.commandsAborted.summation` | Any non-zero | Storage faults — check HBA, array, and network path |
| `disk.busResets.summation` | Any non-zero | Serious — investigate storage fabric immediately |

### 4. Network saturation

| Metric | What to look for |
|---|---|
| `net.droppedRx/Tx.summation` | Any drops = NIC or uplink saturation |
| `net.received/transmitted.average` | Compare guests summed vs host total — find the heavy talker |

### Recommended investigation order

```
cpu.latency.average rising?
  └─ YES → cpu.ready high?
              YES → host CPU overcommit → check cpu.demand.average vs host MHz
              NO  → cpu.costop high? → reduce vCPU count on affected VMs
  └─ NO  → virtualDisk latency high?
              YES → storage problem → check disk.queueLatency + commandsAborted
              NO  → mem.balloon non-zero?
                      YES → memory pressure → check host mem.swapused
                      NO  → net.dropped non-zero? → network saturation
```
