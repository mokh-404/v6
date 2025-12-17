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
    # Strategy 3: /sys/class/hwmon [Fallback]
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
    local current_time=$(date +%s.%N)
    
    # --------------------------------------------------------------------------
    # 0. Formatting Helper (Moved up for shared use)
    # --------------------------------------------------------------------------
    format_speed() {
        local bytes=$1
        echo "$bytes" | awk '{
            if ($1 < 1024) { printf "%.0f B/s", $1 } 
            else if ($1 < 1048576) { printf "%.2f KB/s", $1/1024 } 
            else { printf "%.2f MB/s", $1/1048576 }
        }'
    }

    # 1. TCP Connections (Always reliable)
    # --------------------------------------------------------------------------
    local tcp_conns=0
    if [ -r /proc/net/tcp ]; then
        local raw=$(cat /proc/net/tcp | wc -l)
        tcp_conns=$((raw - 1))
        [ $tcp_conns -lt 0 ] && tcp_conns=0
    fi
    
    # --------------------------------------------------------------------------
    # STRATEGY D: Windows Native (typeperf.exe) - The "Fix" for Frozen WSL1
    # --------------------------------------------------------------------------
    # Use this if available (WSL environ) as it bypasses broken Linux counters entirely.
    if command -v typeperf.exe >/dev/null 2>&1; then
        # Run typeperf for 1 snapshot (instant rate).
        local raw_win=$(typeperf.exe "\Network Interface(*)\Bytes Received/sec" "\Network Interface(*)\Bytes Sent/sec" -sc 1 2>/dev/null)
        
        if [ -n "$raw_win" ]; then
            # Use awk to parse the CSV safely
            read l_rx l_tx w_rx w_tx <<< $(echo "$raw_win" | awk -F '","' '
            NR==2 {
                # Header Parsing
                for(i=2; i<=NF; i++) {
                    if($i ~ /Wi-Fi|Wireless|WLAN|802\.11/) type="wifi"
                    else type="lan"
                    
                    if($i ~ /Received/) dir="rx"
                    else if($i ~ /Sent/) dir="tx"
                    else dir="ignore"
                    
                    map[i] = type "_" dir
                }
            }
            NR==3 {
                # Data Parsing
                lr=0; lt=0; wr=0; wt=0;
                for(i=2; i<=NF; i++) {
                     val=$i
                     gsub(/"/, "", val) 
                     if(map[i] == "lan_rx") lr += val
                     if(map[i] == "lan_tx") lt += val
                     if(map[i] == "wifi_rx") wr += val
                     if(map[i] == "wifi_tx") wt += val
                }
                printf "%.0f %.0f %.0f %.0f", lr, lt, wr, wt
            }
            ')
            
            # If we got any numbers (even 0 is valid return from successful parse)
            # We assume this source is authoritative for WSL.
            if [ -n "$l_rx" ]; then
                 local d_lrx=$(format_speed $l_rx)
                 local d_ltx=$(format_speed $l_tx)
                 local d_wrx=$(format_speed $w_rx)
                 local d_wtx=$(format_speed $w_tx)
                 
                 METRICS[NET_DATA]="  LAN: ↓ ${d_lrx} ↑ ${d_ltx} | WiFi: ↓ ${d_wrx} ↑ ${d_wtx} | TCP: ${tcp_conns}"
                 return
            fi
        fi
    fi

    # --------------------------------------------------------------------------
    # STRATEGY E: MacOS Native (Darwin)
    # --------------------------------------------------------------------------
    if [ "$(uname -s)" = "Darwin" ] && command -v netstat >/dev/null 2>&1; then
          # netstat -ib: 
          # Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
          # 1    2   3       4       5     6     7      8     9     10     11
          local content=$(netstat -ib -n 2>/dev/null)
          
          local lan_rx=0; local lan_tx=0; local wifi_rx=0; local wifi_tx=0;
          local active=0
          
          # Calc Delta
          local time_delta=0
          local valid_delta=0
          if [ "$PREV_NET_TIME" != "0" ]; then
             time_delta=$(echo "$current_time $PREV_NET_TIME" | awk '{print $1 - $2}')
             if [ $(echo "$time_delta" | awk '{if ($1 > 0.1) print 1; else print 0}') -eq 1 ]; then valid_delta=1; fi
          fi

          # Parse
          while read -r line; do
             # Filter Header
             [[ "$line" =~ ^Name ]] && continue
             
             # Filter only Link Layer (Lines containing <Link#...>)
             if [[ "$line" =~ "<Link#" ]]; then
                 # awk default split by whitespace
                 local name=$(echo "$line" | awk '{print $1}')
                 local rx=$(echo "$line" | awk '{print $7}')
                 local tx=$(echo "$line" | awk '{print $10}')
                 
                 # On Mac, en0, en1 are physical. en0 usually WiFi on laptops, Ethernet on Mac Mini.
                 # Hardware Port checking is complex. We assume 'en' is LAN/WiFi. 
                 # Often en0=WiFi. bridge0=Bridge.
                 # Simple heuristic: en* = WiFi (MacBooks) or LAN. 
                 # Let's aggregate 'en' as we don't know enabling.
                 # Actually, usually en0 is WiFi. en1 is Thunderbolt?
                 
                 # Better: just check 'en'. 
                 if [[ "$name" =~ ^en ]]; then
                     # Accumulate
                     if [ "$valid_delta" -eq 1 ] && [ -n "${PREV_NET_RX[$name]}" ]; then
                         local rd=$((rx - PREV_NET_RX[$name]))
                         local td=$((tx - PREV_NET_TX[$name]))
                         [ "$rd" -lt 0 ] && rd=0; [ "$td" -lt 0 ] && td=0;
                         local rr=$(echo "$rd $time_delta" | awk '{printf "%.0f", $1 / $2}')
                         local tr=$(echo "$td $time_delta" | awk '{printf "%.0f", $1 / $2}')
                         
                         # On Mac, separating LAN/WiFi is tricky without 'networksetup'.
                         # We'll enable a naive split: en0 is usually primary.
                         # If we see 'en0' we call it WiFi (Macbook default).
                         # If name has 'bridge', skip?
                         # Let's map ALL 'en' traffic to "Net".
                         # Or better, user wants Split.
                         # We can try using system_profiler in background? Too slow.
                         # We'll just Aggregate all 'en' to LAN for now, or Split en0/en1?
                         # Let's dump all to "Net".
                         lan_rx=$((lan_rx+rr))
                         lan_tx=$((lan_tx+tr))
                     fi
                     PREV_NET_RX[$name]=$rx; PREV_NET_TX[$name]=$tx;
                 fi
             fi
          done <<< "$content"
          
          if [ $((lan_rx+lan_tx)) -gt 0 ]; then active=1; fi
          
          METRICS[NET_DATA]="  Net(Mac): ↓ $(format_speed $lan_rx) ↑ $(format_speed $lan_tx) | TCP: ${tcp_conns}"
          if [ "$active" -eq 1 ]; then
             PREV_NET_TIME="$current_time"
             return
          fi
    fi

    # --------------------------------------------------------------------------
    # STRATEGY A/B/C: Linux Native Fallbacks (Native Linux / Broken WSL)
    # --------------------------------------------------------------------------
    
    local time_delta=0
    local valid_delta=0
    if [ "$PREV_NET_TIME" != "0" ]; then
         time_delta=$(echo "$current_time $PREV_NET_TIME" | awk '{print $1 - $2}')
         if [ $(echo "$time_delta" | awk '{if ($1 > 0.1) print 1; else print 0}') -eq 1 ]; then
             valid_delta=1
         fi
    fi

    # --- Source A: SNMP (Global) ---
    local snmp_rx=0; local snmp_tx=0; local snmp_active=0;
    if [ -r /proc/net/snmp ]; then
         read snmp_rx snmp_tx <<< $(awk '/^Ip:/{i++; if(i==2) print $3, $10}' /proc/net/snmp)
         if [ -n "$snmp_rx" ] && [ "$valid_delta" -eq 1 ] && [ -n "${PREV_NET_RX[TOTAL_SNMP]}" ]; then
             local rd=$((snmp_rx - PREV_NET_RX[TOTAL_SNMP])); local td=$((snmp_tx - PREV_NET_TX[TOTAL_SNMP]));
             [ "$rd" -lt 0 ] && rd=0; [ "$td" -lt 0 ] && td=0;
             local rr=$(echo "$rd $time_delta" | awk '{printf "%.0f", $1 / $2}'); local tr=$(echo "$td $time_delta" | awk '{printf "%.0f", $1 / $2}');
             snmp_rx=$((rr * 1024)); snmp_tx=$((tr * 1024));
             [ $((snmp_rx+snmp_tx)) -gt 0 ] && snmp_active=1;
         fi
         if [ -n "$snmp_rx" ]; then PREV_NET_RX[TOTAL_SNMP]=$snmp_rx; PREV_NET_TX[TOTAL_SNMP]=$snmp_tx; fi
    fi

    # --- Source B: Interface Counters ---
    local iface_file=""; local iface_mode="";
    if [ -r /proc/net/dev ]; then iface_file="/proc/net/dev"; iface_mode="std";
    elif [ -r /proc/net/xt_qtaguid/iface_stat_fmt ]; then iface_file="/proc/net/xt_qtaguid/iface_stat_fmt"; iface_mode="legacy"; fi
    
    local lan_rx=0; local lan_tx=0; local wifi_rx=0; local wifi_tx=0; local iface_active=0; local iface_found=0;
    
    if [ -n "$iface_file" ]; then
        iface_found=1
        local content=$(cat "$iface_file")
        [ "$iface_mode" = "std" ] && content=$(echo "$content" | tail -n +3)
        while read -r line; do
             line=$(echo "$line" | sed 's/^[ \t]*//')
             [ -z "$line" ] && continue
             local name rx tx
             if [ "$iface_mode" = "std" ]; then name=$(echo "$line"|cut -d: -f1); local s=$(echo "$line"|cut -d: -f2); rx=$(echo "$s"|awk '{print $1}'); tx=$(echo "$s"|awk '{print $9}');
             else name=$(echo "$line"|awk '{print $1}'); [ "$name" = "ifname" ] && continue; rx=$(echo "$line"|awk '{print $2}'); tx=$(echo "$line"|awk '{print $4}'); fi
             [ "$name" = "lo" ] && continue; [ -z "$rx" ] && continue
             
             if [ "$valid_delta" -eq 1 ] && [ -n "${PREV_NET_RX[$name]}" ]; then
                 local rd=$((rx - PREV_NET_RX[$name])); local td=$((tx - PREV_NET_TX[$name]));
                 [ "$rd" -lt 0 ] && rd=0; [ "$td" -lt 0 ] && td=0;
                 local rr=$(echo "$rd $time_delta" | awk '{printf "%.0f", $1 / $2}'); local tr=$(echo "$td $time_delta" | awk '{printf "%.0f", $1 / $2}');
                 if [[ "$name" =~ ^w|^wifi ]]; then wifi_rx=$((wifi_rx+rr)); wifi_tx=$((wifi_tx+tr));
                 else lan_rx=$((lan_rx+rr)); lan_tx=$((lan_tx+tr)); fi
             fi
             PREV_NET_RX[$name]=$rx; PREV_NET_TX[$name]=$tx;
        done <<< "$content"
        if [ $((lan_rx+lan_tx+wifi_rx+wifi_tx)) -gt 0 ]; then iface_active=1; fi
    fi

    PREV_NET_TIME="$current_time"
    
    # Selection Logic
    if [ "$iface_active" -eq 1 ]; then
        local label=""; [ "$iface_mode" = "legacy" ] && label="(L)"
        METRICS[NET_DATA]="  LAN${label}: ↓ $(format_speed $lan_rx) ↑ $(format_speed $lan_tx) | WiFi: ↓ $(format_speed $wifi_rx) ↑ $(format_speed $wifi_tx) | TCP: ${tcp_conns}"
    elif [ "$snmp_active" -eq 1 ]; then
        METRICS[NET_DATA]="  Net(Global): ↓ $(format_speed $snmp_rx)  ↑ $(format_speed $snmp_tx) | TCP: ${tcp_conns}"
    else
        # Default Zero
        if [ "$iface_found" -eq 1 ]; then
            local label=""; [ "$iface_mode" = "legacy" ] && label="(L)"
            METRICS[NET_DATA]="  LAN${label}: ↓ 0 B/s ↑ 0 B/s | WiFi: ↓ 0 B/s ↑ 0 B/s | TCP: ${tcp_conns}"
        else
            METRICS[NET_DATA]="  Net: Initializing... | TCP: ${tcp_conns}"
        fi
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

# [8/10] ROM/BIOS Metrics
collect_rom_metrics() {
    log_info "[4/9] Collecting ROM/BIOS Info..."
    
    local vendor="N/A"
    local version="N/A"
    local date="N/A"
    local serial="N/A"
    local secure_boot="N/A"
    
    # Strategy A: WSL/Windows (wmic)
    if command -v wmic.exe >/dev/null 2>&1; then
        # Parse wmic output (format:list)
        local raw=$(wmic.exe bios get /format:list 2>/dev/null | tr -d '\r')
        if [ -n "$raw" ]; then
             vendor=$(echo "$raw" | grep "^Manufacturer=" | cut -d= -f2)
             version=$(echo "$raw" | grep "^SMBIOSBIOSVersion=" | cut -d= -f2)
             local d_raw=$(echo "$raw" | grep "^ReleaseDate=" | cut -d= -f2)
             serial=$(echo "$raw" | grep "^SerialNumber=" | cut -d= -f2)
             
             # Date format: 20241203000000.000000+000 -> 2024-12-03
             if [ -n "$d_raw" ]; then
                 date="${d_raw:0:4}-${d_raw:4:2}-${d_raw:6:2}"
             fi
        fi
        
        # Check Secure Boot (Powershell)
        if command -v powershell.exe >/dev/null 2>&1; then
             local sb_status=$(powershell.exe -Command "Confirm-SecureBootUEFI" 2>/dev/null | tr -d '\r')
             if [[ "$sb_status" == "True" ]]; then secure_boot="Enabled"; 
             elif [[ "$sb_status" == "False" ]]; then secure_boot="Disabled"; 
             else secure_boot="Unknown"; fi
        fi
        
    # Strategy B: Linux Native (sysfs)
    elif [ -r /sys/class/dmi/id/bios_vendor ]; then
        vendor=$(cat /sys/class/dmi/id/bios_vendor 2>/dev/null)
        version=$(cat /sys/class/dmi/id/bios_version 2>/dev/null)
        date=$(cat /sys/class/dmi/id/bios_date 2>/dev/null)
        serial=$(cat /sys/class/dmi/id/product_serial 2>/dev/null)
        # Secure Boot on Linux usually requires 'mokutil' or root access to efivars
        if command -v mokutil >/dev/null 2>&1; then
            if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then secure_boot="Enabled"; else secure_boot="Disabled"; fi
        fi
        
    # Strategy C: MacOS (system_profiler)
    elif [ "$(uname -s)" = "Darwin" ]; then
        local raw=$(system_profiler SPHardwareDataType 2>/dev/null)
        version=$(echo "$raw" | grep "System Firmware Version:" | cut -d: -f2 | xargs)
        serial=$(echo "$raw" | grep "Serial Number (system):" | cut -d: -f2 | xargs)
        vendor="Apple"
        if echo "$raw" | grep -q "Apple Security Chip"; then secure_boot="Enabled"; fi
    fi
    # Clean up empty
    [ -z "$vendor" ] && vendor="N/A"
    [ -z "$version" ] && version="N/A"
    [ -z "$date" ] && date="N/A"
    [ -z "$serial" ] && serial="N/A"
    
    METRICS[ROM_INFO]="${vendor} | Ver: ${version} | Date: ${date} | Serial: ${serial} | SB: ${secure_boot}"
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
    # Clear screen (ANSI)
    printf "\033[H\033[J"
    
    # Ensure ROM has a value if empty
    [ -z "${METRICS[ROM_INFO]}" ] && METRICS[ROM_INFO]="Loading ROM Data..."

    echo "================================================================================"
    echo "  System Summary [${TIMESTAMP}]"
    echo "================================================================================"
    echo "  CPU: ${METRICS[CPU_MODEL]} | Cores: ${METRICS[CPU_CORES]} | Usage: ${METRICS[CPU_USAGE]} | Load: ${METRICS[LOAD_AVG]} | Temp: ${METRICS[TEMP]} | Mem: ${METRICS[MEM_USED]}/${METRICS[MEM_TOTAL]} GB (${METRICS[MEM_PERCENT]}) | Free: ${METRICS[MEM_FREE]} GB"
    echo "  ------------------------------------------------------------------------------"
    echo "  GPU: ${METRICS[GPU_NAME]} | Mem: ${METRICS[GPU_MEM]} | Util: ${METRICS[GPU_UTIL]} | Temp: ${METRICS[GPU_TEMP]} | Disks: ${METRICS[DISK_DISPLAY]}"
    echo "  ------------------------------------------------------------------------------"
    echo "  System: Uptime: ${METRICS[UPTIME]} | Procs: ${METRICS[PROC_COUNT]} | SMART: ${METRICS[SMART_STATUS]}"
    echo "  ROM: ${METRICS[ROM_INFO]}"
    echo "  ${METRICS[NET_DATA]}"
    echo ""
}

################################################################################
# Main
################################################################################

# Async Helpers
run_async() {
    local func_name=$1
    local out_file=$2
    local lock_file="${out_file}.lock"
    
    # Check if lock exists and process is still running
    if [ -f "$lock_file" ]; then
        local pid=$(cat "$lock_file")
        if kill -0 "$pid" 2>/dev/null; then
            return # Still running, skip
        fi
    fi
    
    # Start background job
    (
        echo $$ > "$lock_file"
        $func_name > "$out_file.tmp"
        mv "$out_file.tmp" "$out_file"
        rm -f "$lock_file"
    ) &
}

load_async_metric() {
    local file=$1
    local metric_key=$2
    if [ -f "$file" ]; then
        METRICS[$metric_key]=$(cat "$file")
    else
        METRICS[$metric_key]="Loading..."
    fi
}

# Refactored Heavy Functions (Output to stdout)
get_smart_output() {
    collect_smart_status_logic
    echo "${METRICS[SMART_STATUS]}|${METRICS[SMART_HEALTH]}"
}

get_disk_output() {
    collect_disk_metrics_logic
    echo "${METRICS[DISK_DISPLAY]}"
}

get_gpu_output() {
    collect_gpu_metrics_logic
    echo "${METRICS[GPU_NAME]}|${METRICS[GPU_MEM]}|${METRICS[GPU_TEMP]}|${METRICS[GPU_UTIL]}"
}

# Wrapper to keep original logic but redirect output appropriately
wrapper_smart() {
    collect_smart_status
    echo "${METRICS[SMART_HEALTH]}" 
}
wrapper_disk() {
    collect_disk_metrics
    echo "${METRICS[DISK_PERCENT]}"
    echo "${METRICS[DISK_DISPLAY]}"
}
wrapper_gpu() {
    collect_gpu_metrics
    echo "${METRICS[GPU_NAME]}|${METRICS[GPU_MEM]}|${METRICS[GPU_TEMP]}|${METRICS[GPU_UTIL]}"
}

main() {
    setup_directories
    display_header
    
    local tick=0
    
    # Initial Collections (Static Data)
    collect_rom_metrics         # [NEW] ROM/BIOS
    
    # Define temp files
    local smart_file="/tmp/sysmon_smart.data"
    local disk_file="/tmp/sysmon_disk.data"
    local gpu_file="/tmp/sysmon_gpu.data"
    
    while true; do
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        
        # --- FAST METRICS ---
        collect_cpu_metrics
        collect_memory_metrics
        collect_network_metrics
        collect_load_metrics    
        collect_top_processes
        
        # --- ASYNC SCHEDULING ---
        # Trigger background jobs
        
        # GPU (Every 5s) - Using wrapper to dump data to file
        if [ $((tick % 5)) -eq 0 ]; then
             run_async "wrapper_gpu" "$gpu_file"
        fi
        
        # Disk (Every 10s)
        if [ $((tick % 10)) -eq 0 ]; then
             run_async "wrapper_disk" "$disk_file"
        fi
        
        # SMART (Every 30s)
        if [ $((tick % 30)) -eq 0 ]; then
             run_async "wrapper_smart" "$smart_file"
        fi

        # Alerts (Every 5s - Fast enough to run sync?)
        
        # Simplification: READ the async files and populate METRICS
        
        if [ -f "$gpu_file" ]; then
             IFS='|' read -r name mem temp util < "$gpu_file"
             METRICS[GPU_NAME]="$name"
             METRICS[GPU_MEM]="$mem"
             METRICS[GPU_TEMP]="$temp"
             METRICS[GPU_UTIL]="$util"
        else
             METRICS[GPU_NAME]="Loading..."
        fi
        
        if [ -f "$disk_file" ]; then
             # Read multiple lines: 1st=Percent, 2nd=Display
             {
                 read -r d_pct
                 read -r d_disp
             } < "$disk_file"
             METRICS[DISK_PERCENT]="$d_pct"
             METRICS[DISK_DISPLAY]="$d_disp"
        else
             METRICS[DISK_DISPLAY]="Loading..."
        fi
        
        if [ -f "$smart_file" ]; then
             METRICS[SMART_HEALTH]=$(cat "$smart_file")
        else
             METRICS[SMART_HEALTH]="Loading..."
        fi
        
        # Alerts (Sync) - using whatever data we have
        if [ $((tick % 5)) -eq 0 ]; then
            check_alerts
        fi
        
        export_csv
        generate_html
        
        display_summary
        
        sleep 1
        ((tick++))
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
```