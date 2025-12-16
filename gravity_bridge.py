#!/usr/bin/env python3
import platform
import subprocess
import sys
import os
import re

def is_wsl():
    """Detects if we are running in WSL 1 or 2."""
    try:
        release = platform.release().lower()
        return "microsoft" in release or "wsl" in release
    except Exception:
        return False

def run_command(cmd_list, debug=False):
    """Runs a subprocess command and returns decoded output."""
    try:
        if debug:
            print(f"DEBUG: Running command: {cmd_list}", file=sys.stderr)
        output = subprocess.check_output(cmd_list, stderr=subprocess.PIPE if not debug else None)
        decoded = output.decode('utf-8').strip()
        if debug:
            print(f"DEBUG: Output: {decoded}", file=sys.stderr)
        return decoded
    except subprocess.CalledProcessError as e:
        if debug:
            print(f"DEBUG: Command failed: {e}", file=sys.stderr)
            if e.stderr:
                print(f"DEBUG: Stderr: {e.stderr.decode('utf-8')}", file=sys.stderr)
        return None
    except Exception as e:
        if debug:
            print(f"DEBUG: Execution error: {e}", file=sys.stderr)
        return None

def get_windows_temp(debug=False, is_wsl_mode=False):
    """
    Fetches temperature on Windows (Native or via WSL Breakout).
    Uses WMI/CIM via PowerShell.
    """
    
    # Resolve powershell.exe path
    ps_exe = "powershell.exe"
    
    # If in WSL, we might need full path if not in PATH
    if is_wsl_mode:
        # Common WSL mount points for Windows System32
        candidates = [
            "powershell.exe",
            "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe",
            "/mnt/c/Windows/System32/powershell.exe"
        ]
        
        # Simple check to see if we can find a better path
        for c in candidates:
            if c.startswith("/"):
                if os.path.exists(c):
                    ps_exe = c
                    break
            else:
                # Check if in PATH
                try:
                    if subprocess.call(["which", c], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0:
                         ps_exe = c
                         break
                except:
                    pass
    
    commands = [
        # Method 1: Get-WmiObject (Classic MSAcpi)
        (
            f"Get-WmiObject MSAcpi_ThermalZoneTemperature -Namespace 'root/wmi' "
            "| Select-Object -ExpandProperty CurrentTemperature "
            "| Select-Object -First 1"
        ),
        # Method 2: Get-CimInstance (Modern MSAcpi)
        (
            f"Get-CimInstance -Namespace 'root/wmi' -ClassName MSAcpi_ThermalZoneTemperature "
            "| Select-Object -ExpandProperty CurrentTemperature "
            "| Select-Object -First 1"
        ),
        # Method 3: Win32_PerfFormattedData_Counters_ThermalZoneInformation (Standard CIMv2)
        (
            f"Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ThermalZoneInformation "
            "| Select-Object -ExpandProperty Temperature "
            "| Select-Object -First 1"
        ),
        # Method 4: OHM via WMI (if installed)
        (
            f"Get-WmiObject -Namespace 'root/OpenHardwareMonitor' -Class Sensor "
            "| Where-Object { $_.SensorType -eq 'Temperature' -and $_.Name -like '*CPU*' } "
            "| Select-Object -ExpandProperty Value "
            "| Select-Object -First 1"
        )
    ]

    for i, ps_cmd in enumerate(commands):
        if debug:
            print(f"DEBUG: (Win/WSL) Attempting Strategy {i+1} with {ps_exe}...", file=sys.stderr)
            
        try:
            # Note: PowerShell -Command expects the command string to be properly quoted if complex
            # We pass it as a single argument to -Command.
            raw = run_command([ps_exe, "-NoProfile", "-NonInteractive", "-Command", ps_cmd], debug)
            
            if raw:
                # OHM returns Celsius specific value often directly
                if "OpenHardwareMonitor" in ps_cmd and raw.replace('.', '', 1).isdigit():
                     return float(raw)

                if raw.isdigit():
                    val = float(raw)
                    
                    # Win32_PerfFormattedData_Counters_ThermalZoneInformation often returns Kelvin (not deci-kelvin) OR Celsius directly?
                    # MSAcpi returns Deci-Kelvin (K * 10).
                    # Let's use heuristics.
                    
                    # If value is > 2000, it's likely Deci-Kelvin (273.15 * 10 = 2731.5)
                    if 2500 < val < 4000:
                        celsius = (val / 10.0) - 273.15
                        if debug:
                            print(f"DEBUG: Success with Strategy {i+1} (Deci-Kelvin). Result: {celsius}", file=sys.stderr)
                        return celsius
                        
                    # If value is > 200 and < 400, it's likely Kelvin (273.15 = 0C)
                    elif 200 < val < 400:
                        celsius = val - 273.15
                        if debug:
                            # 310K -> 36.85C
                            print(f"DEBUG: Success with Strategy {i+1} (Raw Kelvin). Result: {celsius}", file=sys.stderr)
                        return celsius
                        
                    # If value is < 150, it's likely Celsius
                    elif 0 < val < 150:
                        if debug:
                            print(f"DEBUG: Success with Strategy {i+1} (Celsius). Result: {val}", file=sys.stderr)
                        return val

                    elif debug:
                        print(f"DEBUG: Value {val} out of reasonable range.", file=sys.stderr)
        except Exception as e:
            if debug:
                print(f"DEBUG: Strategy {i+1} Exception: {e}", file=sys.stderr)
            pass
    
    # Fallback to wmic.exe
    if debug:
        print("DEBUG: Attempting WMIC specific fallback...", file=sys.stderr)
    try:
        wmic_cmd = "wmic.exe"
        if is_wsl_mode and os.path.exists("/mnt/c/Windows/System32/wbem/wmic.exe"):
            wmic_cmd = "/mnt/c/Windows/System32/wbem/wmic.exe"
            
        raw_wmic = run_command([wmic_cmd, "/namespace:\\\\root\\wmi", "PATH", "MSAcpi_ThermalZoneTemperature", "get", "CurrentTemperature"], debug)
        if raw_wmic:
            matches = re.findall(r'(\d{4,})', raw_wmic)
            if matches:
                kelvin_deci = float(matches[0])
                if 2500 < kelvin_deci < 4000:
                    celsius = (kelvin_deci / 10.0) - 273.15
                    return celsius
    except Exception:
        pass

    return None

def get_linux_native_temp():
    """
    Reads from /sys/class/thermal using standard Linux logic.
    Returns float in Celsius or None.
    """
    base_path = "/sys/class/thermal"
    if not os.path.exists(base_path):
        return None

    # Priority 1: Search for a zone explicitly named x86_pkg_temp or coretemp
    try:
        zones = [f for f in os.listdir(base_path) if f.startswith("thermal_zone")]
        candidate = None
        
        for zone in zones:
            z_path = os.path.join(base_path, zone)
            t_path = os.path.join(z_path, "type")
            temp_path = os.path.join(z_path, "temp")
            
            if os.path.exists(t_path) and os.path.exists(temp_path):
                with open(t_path, 'r') as f:
                    z_type = f.read().strip()
                
                # Check for preferred types
                if "x86_pkg_temp" in z_type or "coretemp" in z_type:
                    # Found a good candidate
                    with open(temp_path, 'r') as f:
                        t_str = f.read().strip()
                    if t_str.isdigit():
                         return float(t_str) / 1000.0
                
                # Keep first valid zone as fallback
                if candidate is None:
                    with open(temp_path, 'r') as f:
                        t_str = f.read().strip()
                    if t_str.isdigit():
                        val = float(t_str)
                        if val > 0:
                            candidate = val / 1000.0
                            
        if candidate is not None:
             return candidate

    except Exception:
        pass
    
    # Fallback: /sys/class/hwmon
    try:
        hwmon_base = "/sys/class/hwmon"
        if os.path.exists(hwmon_base):
             for hw in os.listdir(hwmon_base):
                 # Look for temp*_input files
                 h_path = os.path.join(hwmon_base, hw)
                 for f in os.listdir(h_path):
                     if f.startswith("temp") and f.endswith("_input"):
                         with open(os.path.join(h_path, f), 'r') as file:
                             t_str = file.read().strip()
                             if t_str.isdigit():
                                 val = float(t_str)
                                 # Sanity check: between 10C and 150C
                                 temp_c = val / 1000.0
                                 if 10 < temp_c < 150:
                                     return temp_c
    except Exception:
        pass

    return None

def get_macos_temp():
    """
    Attempt to read temperature on macOS.
    """
    cmd_out = run_command(["osx-cpu-temp"])
    if cmd_out:
        matches = re.findall(r"([0-9\.]+)", cmd_out)
        if matches:
            return float(matches[0])
            
    return None

def main():
    debug = "--debug" in sys.argv
    detected_os = platform.system()
    
    if debug:
        print(f"DEBUG: Detected OS: {detected_os}", file=sys.stderr)
        if is_wsl():
            print("DEBUG: WSL Environment Detected", file=sys.stderr)
        else:
            print("DEBUG: WSL NOT Detected (Are you running this inside WSL?)", file=sys.stderr)
    
    temp = None
    
    if is_wsl():
        temp = get_windows_temp(debug, is_wsl_mode=True)
    elif detected_os == "Windows":
        temp = get_windows_temp(debug, is_wsl_mode=False)
    elif detected_os == "Linux":
        temp = get_linux_native_temp()
    elif detected_os == "Darwin":
        temp = get_macos_temp()
        
    if temp is not None:
        print(f"{temp:.1f}")
    else:
        if debug:
            print("DEBUG: No valid temperature found.", file=sys.stderr)
        print("N/A")

if __name__ == "__main__":
    main()
