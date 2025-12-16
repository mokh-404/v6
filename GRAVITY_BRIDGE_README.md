# Gravity Bridge: WSL 1 Hardware Monitoring Solution

## 1. Problem Statement
WSL 1 (Windows Subsystem for Linux) uses a translation layer to run Linux binaries. Unlike a true VM or native kernel:
- It **isolates** the guest Linux from physical hardware sensors.
- Standard paths like `/sys/class/thermal` are often virtualized, static, or missing.
- Accessing Windows hardware drivers directly from the Linux shell is not natively supported.

**result**: `system_monitor.sh` returned "Temp: N/A" on WSL environments.

## 2. The Solution: Gravity Bridge
We implemented a **Python-based Bridge** (`gravity_bridge.py`) that acts as a conduit between the isolated Linux environment and the Windows Host.

### Architecture
1. **Detection**: The script checks `platform.release()` for "Microsoft".
2. **Breakout**: If WSL is detected, it spawns a subprocess to call the Windows Host's `powershell.exe`.
3. **Query**: It executes specific WMI (Windows Management Instrumentation) queries to fetch hardware data.
4. **Return**: The floating-point temperature is returned to standard output for the Bash script to consume.

## 3. Technical Implementation Details

### Gravity Bridge (`gravity_bridge.py`)
The script employs a **Multi-Strategy Approach** to ensure reliability across different hardware configurations:

1. **Strategy A: Classic ACPI (`MSAcpi_ThermalZoneTemperature`)**
   - **Target**: Standard Intel/OEM motherboards.
   - **Unit**: Deci-Kelvin ($0.1K$).
   - **Challenge**: Often requires Administrator privileges.

2. **Strategy B: Performance Counters (`Win32_PerfFormattedData_Counters_ThermalZoneInformation`)**
   - **Target**: Modern Systems, Ryzen (often).
   - **Unit**: Kelvin ($K$).
   - **Advantage**: **Works without Admin privileges** on many systems. This was the key fix for the Ryzen setup.

3. **Strategy C: OpenHardwareMonitor (`root/OpenHardwareMonitor`)**
   - **Target**: Custom gaming rigs, erratic UEFI implementations.
   - **Unit**: Celsius.
   - **Requirement**: User must install OpenHardwareMonitor and run it.

### Bash Integration (`system_monitor.sh`)
The `collect_cpu_metrics` function was refactored:
- **Priority**: Attempts to run `gravity_bridge.py` first.
- **Validation**: Checks if output is a valid float/integer.
- **Fallback**: Reverts to standard `lm-sensors` if the bridge fails (e.g., on native Linux).

## 4. Challenges & Troubleshooting

### Challenge 1: "Access Denied"
- **Issue**: WMI classes usually require high privileges.
- **Fix**: Implemented Strategy B (`Win32_PerfFormattedData...`) which is exposed to standard users, unlike the sensitive ACPI layer.

### Challenge 2: Ryzen/AMD Support
- **Issue**: AMD drivers often don't expose standard ACPI thermal zones to Windows WMI.
- **Fix**: Verified that `Win32_PerfFormattedData` exposes the "THRM" (Thermal Zone) generic sensor from the motherboard, providing a valid (though sometimes averaged) reading.

### Challenge 3: Path Resolution
- **Issue**: In secure/restricted WSL setups, `powershell.exe` is not always in the `$PATH`.
- **Fix**: Added explicit path resolution to check standard mount points:
  - `/mnt/c/Windows/System32/powershell.exe`
  - `/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe`

### Challenge 4: Unit Confusion
- **Issue**: Different WMI classes return Celsius, Kelvin, or Deci-Kelvin.
- **Fix**: Implemented heuristic range checking:
  - $> 2000$: Treated as Deci-Kelvin.
  - $200 - 400$: Treated as Kelvin.
  - $< 150$: Treated as Celsius.

## 5. Usage

### Standard Run
```bash
./system_monitor.sh
```
The script automatically detects the environment and loads the bridge if needed.

### Debugging
If temperature shows N/A, run the bridge in debug mode to see exactly which strategies failed:
```bash
python3 gravity_bridge.py --debug
```

## 6. Files Created
- `gravity_bridge.py`: The cross-platform sensor reader.
- `system_monitor.sh`: The main dashboard (modified).
