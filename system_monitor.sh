#!/bin/bash

################################################################################
# Unified System Monitoring Script
# Works on Linux and Windows (via WSL)
# Requires: Bash 4.0+
#
# Features:
# - Auto-detects WSL vs Native Linux
# - Native Hardware Monitoring (/sys/class/thermal, /proc)
# - Unified Network & Disk Logic
################################################################################

# Ensure Bash 4.0+ for Associative Arrays
if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "Error: Bash 4.0 or higher is required."
    exit 1
fi

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
REPORT_DIR="${SCRIPT_DIR}/reports"
DATA_DIR="${SCRIPT_DIR}/data"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/system_monitor.log"
CSV_FILE="${DATA_DIR}/metrics.csv"
HTML_REPORT="${REPORT_DIR}/report.html"

# Global metric storage
declare -A METRICS

# State storage for deltas
PREV_CPU_TOTAL=0
PREV_CPU_IDLE=0
PREV_NET_TIME=0
declare -A PREV_NET_RX
declare -A PREV_NET_TX

################################################################################
# Utilities & Logging
################################################################################

log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" >> "$LOG_FILE"
}

log_info() { log_message "INFO: $1"; }

is_wsl() {
    if [ -f /proc/version ]; then
        grep -qEi "(Microsoft|WSL)" /proc/version
        return $?
    fi
    return 1
}

log_warn() { log_message "WARNING: $1"; }
log_error() { log_message "ERROR: $1"; }

setup_directories() {
    mkdir -p "$LOG_DIR" "$REPORT_DIR" "$DATA_DIR"
}

display_header() {
    log_info "Starting system monitoring..."
}

################################################################################
# Metric Collection
################################################################################

# [1/10] CPU Metrics
collect_cpu_metrics() {
    log_info "[1/9] Collecting CPU Metrics..."


    local model="Unknown"
    local cores=1
    local usage=0
    local load="0.00"

    # -- Model & Cores --
    if command -v sysctl >/dev/null 2>&1; then
        local m=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
        [ -n "$m" ] && model="$m"
        local c=$(sysctl -n hw.logicalcpu 2>/dev/null)
        [ -n "$c" ] && cores="$c"
    fi
    if [ -r /proc/cpuinfo ]; then
        local m=$(grep "^model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^[ \t]*//')
        [ -n "$m" ] && model="$m"
        local c=$(grep -c "^processor" /proc/cpuinfo)
        [ -n "$c" ] && [ "$c" -gt 0 ] && cores="$c"
    fi

    # -- Usage --
    if [ "$(uname)" = "Darwin" ]; then
        local cpu_str=$(top -l 1 | grep "CPU usage" | head -1)
        local user=$(echo "$cpu_str" | awk '{print $3}' | sed 's/%//')
        local sys=$(echo "$cpu_str" | awk '{print $5}' | sed 's/%//')
        if [ -n "$user" ] && [ -n "$sys" ]; then
             usage=$(echo "$user $sys" | awk '{print $1 + $2}')
        fi
    fi
    if [ -r /proc/stat ]; then
        local cpu_line=$(grep "^cpu " /proc/stat)
        read -r _ u n s i _ <<< "$cpu_line"
        
        local current_total=$((u + n + s + i))
        local current_idle=$i
        
        if [ "$PREV_CPU_TOTAL" -gt 0 ]; then
            local delta_total=$((current_total - PREV_CPU_TOTAL))
            local delta_idle=$((current_idle - PREV_CPU_IDLE))
            
            if [ "$delta_total" -gt 0 ]; then
                 local delta_used=$((delta_total - delta_idle))
                 usage=$(echo "$delta_used $delta_total" | awk '{printf "%.2f", ($1 * 100) / $2}')
            fi
        fi
        
        # Save state
        PREV_CPU_TOTAL=$current_total
        PREV_CPU_IDLE=$current_idle
    fi

    # -- Load Average --
    if command -v sysctl >/dev/null 2>&1; then
         local l=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
         [ -n "$l" ] && load="$l"
    fi
    if [ -r /proc/loadavg ]; then
         load=$(awk '{print $1}' /proc/loadavg)
    fi

    # -- CPU Temperature --

    local temp="N/A"
<<<<<<< HEAD

    # Strategy 0: "Anti-Gravity" Python Bridge (WSL Breakout / Unified)
    # Check for script existence in the same directory
    if command -v python3 >/dev/null 2>&1 && [ -f "${SCRIPT_DIR}/gravity_bridge.py" ]; then
        local py_temp=$(python3 "${SCRIPT_DIR}/gravity_bridge.py")
        # Check if output is a valid number (integer or float)
        if [[ "$py_temp" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
             temp="${py_temp}°C"
        fi
    fi
    
    # Strategy 1: sensors (lm-sensors) [Fallback]
    if [ "$temp" == "N/A" ] && command -v sensors >/dev/null 2>&1; then
        local t=$(sensors | grep -E "Package id 0:|Core 0:" | head -1 | awk '{print $3}' | grep -o "[0-9.]*")
        [ -n "$t" ] && temp="${t}°C"
    fi
    # Strategy 2: /sys/class/thermal [Fallback]
=======
    
    # Strategy 1: sensors (lm-sensors)
    if command -v sensors >/dev/null 2>&1; then
        local t=$(sensors | grep -E "Package id 0:|Core 0:" | head -1 | awk '{print $3}' | grep -o "[0-9.]*")
        [ -n "$t" ] && temp="${t}°C"
    fi
    # Strategy 2: /sys/class/thermal
>>>>>>> fa9881ae04ef4b0fb17f94636f7c6f8a712acbbe
    if [ "$temp" == "N/A" ] && ls /sys/class/thermal/thermal_zone*/temp >/dev/null 2>&1; then
         # Try finding a zone with type "x86_pkg_temp" or similar positive value
         for zone in /sys/class/thermal/thermal_zone*; do
             [ -e "$zone/temp" ] || continue
             local t_milli=$(cat "$zone/temp" 2>/dev/null)
             if [ -n "$t_milli" ] && [ "$t_milli" -gt 0 ]; then
                 local t_c=$(echo "$t_milli" | awk '{printf "%.1f", $1/1000}')
                 temp="${t_c}°C"
                 break
             fi
         done
    fi
<<<<<<< HEAD
    # Strategy 3: /sys/class/hwmon [Fallback]
=======
    # Strategy 3: /sys/class/hwmon
>>>>>>> fa9881ae04ef4b0fb17f94636f7c6f8a712acbbe
    if [ "$temp" == "N/A" ]; then
        for input in /sys/class/hwmon/hwmon*/temp*_input; do
            [ -f "$input" ] || continue
            local t_milli=$(cat "$input" 2>/dev/null)
            if [ -n "$t_milli" ] && [ "$t_milli" -gt 0 ]; then
                local t_c=$(echo "$t_milli" | awk '{printf "%.1f", $1/1000}')
                temp="${t_c}°C"
                break
            fi
        done
    fi

    METRICS[CPU_MODEL]="$model"
    METRICS[CPU_CORES]="$cores"
    METRICS[CPU_USAGE]="$usage"
    METRICS[LOAD_AVG]="$load"
    METRICS[TEMP]="$temp"
    
    METRICS[TEMP]="$temp"
    
    # Echo removed for decoupled display
}

# [2/10] Memory Metrics
collect_memory_metrics() {
    log_info "[2/9] Collecting Memory Metrics..."


    local total_gb=0
    local free_gb=0
    local used_gb=0
    local perm=0

    # macOS
    if command -v vm_stat >/dev/null 2>&1 && command -v sysctl >/dev/null 2>&1; then
        local page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
        local total_bytes=$(sysctl -n hw.memsize 2>/dev/null)
        
        local pages_free=$(vm_stat | grep "Pages free" | awk '{print $3}' | sed 's/\.//')
        local pages_speculative=$(vm_stat | grep "Pages speculative" | awk '{print $3}' | sed 's/\.//' || echo 0)
        
        local free_bytes=$(( (pages_free + pages_speculative) * page_size ))
        
        total_gb=$(echo "$total_bytes" | awk '{printf "%.2f", $1/1024/1024/1024}')
        free_gb=$(echo "$free_bytes" | awk '{printf "%.2f", $1/1024/1024/1024}')
    fi

    # Linux/WSL
    if [ -r /proc/meminfo ]; then
        local t_kb=$(grep "^MemTotal:" /proc/meminfo | awk '{print $2}')
        local f_kb=$(grep "^MemAvailable:" /proc/meminfo | awk '{print $2}') || $(grep "^MemFree:" /proc/meminfo | awk '{print $2}')
        [ -z "$f_kb" ] && f_kb=$(grep "^MemFree:" /proc/meminfo | awk '{print $2}')
        
        if [ -n "$t_kb" ]; then
            total_gb=$(echo "$t_kb" | awk '{printf "%.2f", $1/1024/1024}')
            free_gb=$(echo "$f_kb" | awk '{printf "%.2f", $1/1024/1024}')
        fi
    fi

    used_gb=$(awk -v t="$total_gb" -v f="$free_gb" 'BEGIN {printf "%.2f", t - f}')
    if [ $(awk -v t="$total_gb" 'BEGIN {if (t > 0) print 1; else print 0}') -eq 1 ]; then
        perm=$(awk -v u="$used_gb" -v t="$total_gb" 'BEGIN {printf "%.2f", (u * 100) / t}')
    fi

    METRICS[MEM_TOTAL]="$total_gb"
    METRICS[MEM_USED]="$used_gb"
    METRICS[MEM_FREE]="$free_gb"
    METRICS[MEM_PERCENT]="$perm"

    METRICS[MEM_PERCENT]="$perm"

    METRICS[MEM_PERCENT]="$perm"

    # Echo removed for decoupled display
}

# [3/10] Disk Metrics
collect_disk_metrics() {
    log_info "[4/9] Collecting Disk Metrics..."


    local disk_info=""

    # Unified approach: Parse df output for all physical/real filesystems
    # Excludes: tmpfs, devtmpfs, overlay, squashfs, cdrom, AND specific system paths to reduce clutter
    
    # We will use an Associative Array (or string simulation) to dedup by size+used signature
    # because WSL often mounts the same physical drive at multiple locations (/ and /mnt/c)
    local seen_sizes=""

    while read -r line; do
        local fs=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $2}')
        local used=$(echo "$line" | awk '{print $3}')
        local pcent=$(echo "$line" | awk '{print $5}' | sed 's/%//')
        local path=$(echo "$line" | awk '{print $6}')
        
        # Deduplication 1: Skip if we've seen this exact size+used combination before
        # This handles / vs /mnt/c vs /dev overlap in WSL
        local sig="|${size}|${used}|"
        if [[ "$seen_sizes" == *"$sig"* ]]; then
             continue
        fi
        
        # Determine if this is a "real" path we care about
        # Verify it's not a hidden system path that slipped through grep
        if [[ "$path" == "/run"* || "$path" == "/sys"* || "$path" == "/dev"* || "$path" == "/proc"* || "$path" == "/snap"* ]]; then
             continue
        fi

        # Add to list
        disk_info="${disk_info}${path} ${used}/${size} (${pcent}%);"
        seen_sizes="${seen_sizes}${sig}"

    done < <(df -hP | grep -vE '^Filesystem|tmpfs|cdrom|devtmpfs|udev|overlay|squashfs|iso9660|docker|overlay|none|rootfs')

    METRICS[DISK_INFO]="$disk_info"
    # Backward compatibility
    METRICS[DISK_USED]=$(echo "$disk_info" | cut -d';' -f1 | awk '{print $2}')
    METRICS[DISK_PERCENT]=$(echo "$disk_info" | cut -d';' -f1 | awk '{print $3}' | sed 's/[()%]//g')
    
    # Compact Output using echo -n or accumulation
    local display_str="Disks:"
    IFS=';' read -ra DISKS <<< "$disk_info"
    for disk in "${DISKS[@]}"; do
        [ -z "$disk" ] && continue
        # disk string: "/mnt/c 285G/476G (60%)"
        display_str="${display_str} [${disk}] |"
    done
    # Remove trailing pipe
    display_str=${display_str%|}
    
    METRICS[DISK_DISPLAY]="$display_str"
    # Echo removed for decoupled display
}

# [4/10] SMART Status
collect_smart_status() {
    log_info "[5/9] Collecting SMART Status..."

    
    local status="N/A"
    local health="N/A"

    if command -v smartctl >/dev/null 2>&1; then
        local drive="/dev/sda"
        [ -e /dev/nvme0n1 ] && drive="/dev/nvme0n1"
        [ -e /dev/disk0 ] && drive="/dev/disk0"
        
        if [ "$EUID" -eq 0 ]; then
             local out=$(smartctl -H "$drive" 2>/dev/null)
             if echo "$out" | grep -q "result: PASSED"; then
                 status="Available"
                 health="PASSED"
             elif echo "$out" | grep -q "result: FAILED"; then
                 status="Available"
                 health="FAILED"
             else
                 status="Available"
                 health="Unknown"
             fi
        else
            status="Permission Denied (Root req)"
        fi
    # Fallback to WMIC for Windows/WSL
    elif command -v wmic.exe >/dev/null 2>&1 || [ -f "/mnt/c/Windows/System32/wbem/wmic.exe" ]; then
         local wmic_cmd="wmic.exe"
         [ -f "/mnt/c/Windows/System32/wbem/wmic.exe" ] && wmic_cmd="/mnt/c/Windows/System32/wbem/wmic.exe"
         
         # wmic diskdrive get status
         local wmic_status=$($wmic_cmd diskdrive get status 2>/dev/null | grep -v "Status" | tr -d '\r' | xargs)
         if [ -n "$wmic_status" ]; then
             status="Available (via wmic)"
             health="$wmic_status"
             # Simplify if multiple OKs
             if [[ "$health" == *"OK"* ]]; then
                  health="OK"
             fi
         else
             status="wmic failed"
         fi
    else
        status="smartctl/wmic not found"
    fi

    METRICS[SMART_STATUS]="$status"
    METRICS[SMART_HEALTH]="$health"
    METRICS[SMART_STATUS]="$status"
    METRICS[SMART_HEALTH]="$health"
    
    # Echo removed
}

# [5/10] Network Metrics
collect_network_metrics() {
    log_info "[6/9] Collecting Network Metrics (Speed)..."


    local net_info=""
    local found=0
    
    # Aggregators (Bytes/s)
    local lan_rx_total=0
    local lan_tx_total=0
    local wifi_rx_total=0
    local wifi_tx_total=0

    local current_time=$(date +%s.%N)
    
    # Process Linux/WSL (/proc/net/dev)
    if [ -r /proc/net/dev ]; then
        local raw=$(cat /proc/net/dev | tail -n +3)
        
        # Calculate time delta if we have a previous time
        local time_delta=0
        if [ "$PREV_NET_TIME" != "0" ]; then
             time_delta=$(echo "$current_time $PREV_NET_TIME" | awk '{print $1 - $2}')
        fi
        
        while read -r line; do
             # Trim
             line=$(echo "$line" | sed 's/^[ \t]*//')
             [ -z "$line" ] && continue
             
             local name=$(echo "$line" | cut -d: -f1)
             [ "$name" = "lo" ] && continue
             
             local stats=$(echo "$line" | cut -d: -f2)
             local rx=$(echo "$stats" | awk '{print $1}')
             local tx=$(echo "$stats" | awk '{print $9}')
             
             # If we have previous data for this interface AND valid time delta
             if [ -n "${PREV_NET_RX[$name]}" ] && [ $(echo "$time_delta" | awk '{if ($1 > 0.1) print 1; else print 0}') -eq 1 ]; then
                 local rx_delta=$((rx - PREV_NET_RX[$name]))
                 local tx_delta=$((tx - PREV_NET_TX[$name]))
                 
                 # Handle counter wrap (optional, but good practice) or negative? 
                 # Usually unnecessary for simple monitor, but let's just ensure positive.
                 [ "$rx_delta" -lt 0 ] && rx_delta=0
                 [ "$tx_delta" -lt 0 ] && tx_delta=0
                 
                 local rx_rate=$(echo "$rx_delta $time_delta" | awk '{printf "%.0f", $1 / $2}')
                 local tx_rate=$(echo "$tx_delta $time_delta" | awk '{printf "%.0f", $1 / $2}')

                 if [[ "$name" =~ ^w|^wifi ]]; then
                     wifi_rx_total=$(echo "$wifi_rx_total $rx_rate" | awk '{print $1 + $2}')
                     wifi_tx_total=$(echo "$wifi_tx_total $tx_rate" | awk '{print $1 + $2}')
                 else
                     lan_rx_total=$(echo "$lan_rx_total $rx_rate" | awk '{print $1 + $2}')
                     lan_tx_total=$(echo "$lan_tx_total $tx_rate" | awk '{print $1 + $2}')
                 fi
                 found=1 # We found and calculated for at least one interface
             else
                 # First run or new interface: just mark found=1 so we don't show "Not found" error
                 # but rates remain 0
                 found=1
             fi
             
             # Update state
             PREV_NET_RX[$name]=$rx
             PREV_NET_TX[$name]=$tx
             
        done <<< "$raw"
    fi
    # Wait, the get_bytes function is now unused, I should assume I can remove it or inline it?
    # I replaced the usage logic above.
    
    # Save state time
    PREV_NET_TIME="$current_time"
    
    # Formatting Helper
    format_speed() {
        local bytes=$1
        # Use awk for comparison and formatting in one go to handle all logic safely
        echo "$bytes" | awk '{
            if ($1 < 1024) {
                printf "%.0f B/s", $1
            } else if ($1 < 1048576) {
                printf "%.2f KB/s", $1/1024
            } else {
                printf "%.2f MB/s", $1/1048576
            }
        }'
    }

    if [ $found -eq 1 ]; then
        local lan_rx_disp=$(format_speed $lan_rx_total)
        local lan_tx_disp=$(format_speed $lan_tx_total)
        local wifi_rx_disp=$(format_speed $wifi_rx_total)
        local wifi_tx_disp=$(format_speed $wifi_tx_total)
        
        local output_str=""
        
        # In WSL, physical WiFi usually appears as 'eth0' alongside Ethernet.
        # It's indistinguishable. So we should simplify the label to avoid "WiFi: 0 B/s" confusion.
        if is_wsl; then
             local total_rx=$((lan_rx_total + wifi_rx_total))
             local total_tx=$((lan_tx_total + wifi_tx_total))
             local disp_rx=$(format_speed $total_rx)
             local disp_tx=$(format_speed $total_tx)
             output_str="  Network (WSL): ↓ ${disp_rx}  ↑ ${disp_tx}"
        else
             # Standard Linux separate display
             output_str="  LAN: ↓ ${lan_rx_disp}  ↑ ${lan_tx_disp}"
             # Only show WiFi if it actually exists/has been detected or non-zero? 
             # User prompt showed "wifi: 0 B/s".
             # Let's keep showing it but if it's 0 and we are not in WSL, maybe keep it 0.
             output_str="${output_str} | wifi: ↓ ${wifi_rx_disp}  ↑ ${wifi_tx_disp}"
        fi
        
        # Echo removed
        METRICS[NET_DATA]="$output_str"
    else
        METRICS[NET_DATA]="No network interfaces found"
    fi
}

# [6/10] Load Metrics
collect_load_metrics() {
    log_info "[7/9] Collecting System Info..."


    local up_str=""
    if [ -r /proc/uptime ]; then
        local sec=$(awk '{print $1}' /proc/uptime | cut -d. -f1)
        local d=$((sec / 86400))
        local h=$(((sec % 86400) / 3600))
        local m=$(((sec % 3600) / 60))
        up_str="${d}d ${h}h ${m}m"
    else
        up_str=$(uptime | tr -d ',')
    fi

    local proc_cnt=$(ps -e | wc -l)
    
    METRICS[UPTIME]="$up_str"
    METRICS[PROC_COUNT]="$proc_cnt"
    
    # Echo removed
}

# [7/10] GPU Metrics
collect_gpu_metrics() {
    log_info "[3/9] Collecting GPU Metrics..."

    
    local gpu_name="N/A"
    local gpu_mem="N/A"
    local gpu_temp="N/A"
    local gpu_util="N/A"
    
    # Check for nvidia-smi (Linux) or nvidia-smi.exe (Windows/WSL)
    local nvidia_cmd=""
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia_cmd="nvidia-smi"
    elif command -v nvidia-smi.exe >/dev/null 2>&1; then
        nvidia_cmd="nvidia-smi.exe"
    elif [ -f "/mnt/c/Windows/System32/nvidia-smi.exe" ]; then
        nvidia_cmd="/mnt/c/Windows/System32/nvidia-smi.exe"
    fi
    
    if [ -n "$nvidia_cmd" ]; then
        # Query Name, Mem Total, Temp, Utilization
        # Fix: Strip carriage return '\r' which breaks output formatting in WSL
        local out=$("$nvidia_cmd" --query-gpu=name,memory.total,temperature.gpu,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d '\r')
        if [ $? -eq 0 ] && [ -n "$out" ]; then
            gpu_name=$(echo "$out" | cut -d, -f1 | xargs)
            gpu_mem=$(echo "$out" | cut -d, -f2 | xargs)
            gpu_temp=$(echo "$out" | cut -d, -f3 | xargs)
            gpu_util=$(echo "$out" | cut -d, -f4 | xargs)
            
            [ -n "$gpu_mem" ] && gpu_mem="${gpu_mem} MB"
            [ -n "$gpu_temp" ] && gpu_temp="${gpu_temp}°C"
            [ -n "$gpu_util" ] && gpu_util="${gpu_util}%"
        fi
    fi

    # Fallback: Mac
    if [ "$gpu_name" = "N/A" ] && command -v system_profiler >/dev/null 2>&1; then
        local gfx=$(system_profiler SPDisplaysDataType 2>/dev/null)
        local name=$(echo "$gfx" | grep "Chipset Model:" | head -1 | cut -d: -f2 | xargs)
        [ -n "$name" ] && gpu_name="$name"
        local mem=$(echo "$gfx" | grep "VRAM" | head -1 | cut -d: -f2 | xargs)
        [ -n "$mem" ] && gpu_mem="$mem"
    fi
    
    METRICS[GPU_NAME]="$gpu_name"
    METRICS[GPU_MEM]="$gpu_mem"
    METRICS[GPU_TEMP]="$gpu_temp"
    METRICS[GPU_UTIL]="$gpu_util"
    
    METRICS[GPU_UTIL]="$gpu_util"
    
    METRICS[GPU_UTIL]="$gpu_util"
    
    # Echo removed
}

# [8/10] Temperature Metrics
collect_temperature_metrics() {
    log_info "[8/10] Collecting Temperature Metrics..."
    
    local temp="N/A"

    # Strategy 1: sensors (lm-sensors)
    if command -v sensors >/dev/null 2>&1; then
        local t=$(sensors | grep -E "Package id 0:|Core 0:" | head -1 | awk '{print $3}' | grep -o "[0-9.]*")
        [ -n "$t" ] && temp="${t}°C"
    fi

    # Strategy 2: /sys/class/thermal
    if [ "$temp" = "N/A" ] && ls /sys/class/thermal/thermal_zone*/temp >/dev/null 2>&1; then
         for zone in /sys/class/thermal/thermal_zone*; do
             [ -e "$zone/temp" ] || continue
             local t_milli=$(cat "$zone/temp" 2>/dev/null)
             if [ -n "$t_milli" ] && [ "$t_milli" -gt 0 ]; then
                 local t_c=$(echo "$t_milli" | awk '{printf "%.1f", $1/1000}')
                 temp="${t_c}°C"
                 break
             fi
         done
    fi
    
    # Strategy 3: /sys/class/hwmon
    if [ "$temp" == "N/A" ]; then
        for input in /sys/class/hwmon/hwmon*/temp*_input; do
            [ -f "$input" ] || continue
            local t_milli=$(cat "$input" 2>/dev/null)
            if [ -n "$t_milli" ] && [ "$t_milli" -gt 0 ]; then
                local t_c=$(echo "$t_milli" | awk '{printf "%.1f", $1/1000}')
                temp="${t_c}°C"
                break
            fi
        done
    fi
    
    # Fallback message
    [ "$temp" = "N/A" ] && temp="N/A"

    METRICS[TEMP]="$temp"
}

# [9/10] Top Processes
collect_top_processes() {
    log_info "[8/9] Collecting Top Processes..."


    local output=""
    local ps_cmd="ps aux -m"
    if ps aux --sort=-%mem >/dev/null 2>&1; then
        ps_cmd="ps aux --sort=-%mem"
    fi

    # Read into file to avoid subshell scope handling or variable loss
    $ps_cmd | head -6 | tail -5 > /tmp/top_procs.tmp

    # Re-read formatted output to variable
    while read -r line; do
         local pid=$(echo "$line" | awk '{print $2}')
         local usr=$(echo "$line" | awk '{print $1}')
         local mem=$(echo "$line" | awk '{print $4}')
         local cmd=$(echo "$line" | awk '{print $11}')
         # Append to temporary string using semicolon separator
         output="${output}${pid} ${usr} ${mem}% ${cmd};"
    done < /tmp/top_procs.tmp
    
    METRICS[TOP_PROCS]="$output"
}

# [10/10] Check Alerts
check_alerts() {
    log_info "[9/9] Checking Alerts..."

    
    local count=0
    local mem_usage=${METRICS[MEM_PERCENT]%.*}
    if [ -n "$mem_usage" ] && [ "$mem_usage" -gt 90 ]; then
        METRICS[ALERTS]="High Memory Usage: ${mem_usage}%"
        log_warn "High Memory Usage: ${mem_usage}%"
        ((count++))
    fi
    
    local disk_usage=${METRICS[DISK_PERCENT]%.*}
    if [ -n "$disk_usage" ] && [ "$disk_usage" -gt 90 ]; then
        local alert="High Disk Usage: ${disk_usage}%"
        if [ -n "${METRICS[ALERTS]}" ]; then
             METRICS[ALERTS]="${METRICS[ALERTS]}; $alert"
        else
             METRICS[ALERTS]="$alert"
        fi
        log_warn "High Disk Usage: ${disk_usage}%"
        ((count++))
    fi
    
    [ $count -eq 0 ] && METRICS[ALERTS]="No alerts."
}

################################################################################
# Reporting
################################################################################

export_csv() {
    if [ ! -f "$CSV_FILE" ]; then
        echo "Timestamp,CPU_Model,CPU_Cores,CPU_Usage,Mem_Total,Mem_Used,Mem_Percent,Disk_Percent,Temp,GPU_Name" > "$CSV_FILE"
    fi
    echo "${TIMESTAMP},${METRICS[CPU_MODEL]},${METRICS[CPU_CORES]},${METRICS[CPU_USAGE]},${METRICS[MEM_TOTAL]},${METRICS[MEM_USED]},${METRICS[MEM_PERCENT]},${METRICS[DISK_PERCENT]},${METRICS[TEMP]},${METRICS[GPU_NAME]}" >> "$CSV_FILE"
}

generate_html() {
    cat > "$HTML_REPORT" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>System Report - $TIMESTAMP</title>
    <style>
        body { font-family: sans-serif; margin: 20px; background: #f0f2f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #333; border-bottom: 2px solid #eee; padding-bottom: 10px; }
        .metric { margin-bottom: 15px; padding: 10px; background: #f9f9f9; border-radius: 4px; }
        .label { font-weight: bold; color: #555; }
        .value { color: #000; font-family: monospace; }
        .alert { color: red; font-weight: bold; }
    </style>
</head>
<body>
    <div class="container">
        <h1>System Monitoring Report</h1>
        <p>Generated: $(date)</p>
        
        <div class="metric"><span class="label">CPU Model:</span> <span class="value">${METRICS[CPU_MODEL]}</span></div>
        <div class="metric"><span class="label">CPU Cores:</span> <span class="value">${METRICS[CPU_CORES]}</span></div>
        <div class="metric"><span class="label">CPU Usage:</span> <span class="value">${METRICS[CPU_USAGE]}%</span></div>
        
        <div class="metric"><span class="label">Memory:</span> <span class="value">${METRICS[MEM_USED]} / ${METRICS[MEM_TOTAL]} GB (${METRICS[MEM_PERCENT]}%)</span></div>
        
        <div class="metric"><span class="label">Disk:</span> <span class="value">${METRICS[DISK_USED]} used (${METRICS[DISK_PERCENT]}%)</span></div>
        
        <div class="metric"><span class="label">GPU:</span> <span class="value">${METRICS[GPU_NAME]} (${METRICS[GPU_MEM]}) - ${METRICS[GPU_TEMP]}</span></div>
        
        <div class="metric"><span class="label">Temperature:</span> <span class="value">${METRICS[TEMP]}</span></div>
        
        <h3>Top Processes</h3>
        <pre>${METRICS[TOP_PROCS]//;/
}</pre>
    </div>
</body>
</html>
EOF
    log_info "Generated HTML report: $HTML_REPORT"
}

display_summary() {
    echo ""
    echo "================================================================================"
    echo "  System Summary [$TIMESTAMP]"
    echo "================================================================================"
    
    # Line A: Alerts (if any)
    if [ -n "${METRICS[ALERTS]}" ] && [ "${METRICS[ALERTS]}" != "No alerts." ]; then
        echo "  [!] ALERTS: ${METRICS[ALERTS]}"
        echo "  ------------------------------------------------------------------------------"
    fi
    
    # Line 1: CPU | Memory
    local cpu_str="CPU: ${METRICS[CPU_MODEL]} | Cores: ${METRICS[CPU_CORES]} | Usage: ${METRICS[CPU_USAGE]}% | Load: ${METRICS[LOAD_AVG]} | Temp: ${METRICS[TEMP]}"
    local mem_str="Mem: ${METRICS[MEM_USED]}/${METRICS[MEM_TOTAL]} GB (${METRICS[MEM_PERCENT]}%) | Free: ${METRICS[MEM_FREE]} GB"
    echo "  $cpu_str | $mem_str"
    echo "  ------------------------------------------------------------------------------"

    # Line 2: GPU | Disk
    local gpu_str="GPU: ${METRICS[GPU_NAME]} | Mem: ${METRICS[GPU_MEM]} | Util: ${METRICS[GPU_UTIL]} | Temp: ${METRICS[GPU_TEMP]}"
    local disk_str="${METRICS[DISK_DISPLAY]}" # Already format "Disks: [..] | ..."
    # Remove leading spaces from disk string if any
    disk_str=$(echo "$disk_str" | sed 's/^[ \t]*//')
    echo "  $gpu_str | $disk_str"
    echo "  ------------------------------------------------------------------------------"
    
    # Line 3: System | Network
    # Network string usually starts with "  LAN:..."
    local net_str="${METRICS[NET_DATA]}"
    net_str=$(echo "$net_str" | sed 's/^[ \t]*//')
    
    local sys_str="System: Uptime: ${METRICS[UPTIME]} | Procs: ${METRICS[PROC_COUNT]} | SMART: ${METRICS[SMART_HEALTH]}"
    
    echo "  $sys_str | $net_str"
    echo ""
    
    # Top Processes
    if [ -n "${METRICS[TOP_PROCS]}" ]; then
        echo "  Top Processes:"
        echo "  PID    USER     MEM%   COMMAND"
        # Since we stored a raw string with semicolons earlier for internal use,
        # we might need to reconstruct the nice table or just use the variable we formatted (?)
        # Wait, collect_top_processes does NOT store the pretty table in METRICS[TOP_PROCS], 
        # it stores "pid user mem cmd;" list. 
        # But it WAS echoing the table. I must check if I removed the table echoes.
        # I did not modify collect_top_processes in the previous multi_replace.
        # I should probably let collect_top_processes print itself OR output it here.
        # Let's adjust collect_top_processes to NOT print and do it here.
        
        IFS=';' read -ra PROCS <<< "${METRICS[TOP_PROCS]}"
        for proc in "${PROCS[@]}"; do
             [ -z "$proc" ] && continue
             # proc: "pid user mem% cmd"
             local p=$(echo "$proc" | awk '{print $1}')
             local u=$(echo "$proc" | awk '{print $2}')
             local m=$(echo "$proc" | awk '{print $3}')
             local c=$(echo "$proc" | cut -d' ' -f4-)
             printf "  %-6s %-8s %-6s %s\n" "$p" "$u" "$m" "$c"
        done
        echo ""
    fi
}

################################################################################
# Main
################################################################################

main() {
    setup_directories
    display_header
    
    while true; do
        # Update timestamp for each iteration so logs/reports are accurate
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        
        collect_cpu_metrics
        collect_memory_metrics
        collect_gpu_metrics
        collect_disk_metrics
        collect_smart_status    # Grouped next to Disk
        collect_network_metrics
        collect_load_metrics    
        
        collect_top_processes
        check_alerts
        
        export_csv
        generate_html
        
        display_summary
        
        sleep 5
    done
}

main