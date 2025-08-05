#!/bin/bash

# Virtualizor LXC容器管理终极版 v3.4 (零依赖版)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 检查root权限
check_root() {
    [ "$(id -u)" -ne 0 ] && echo -e "${RED}错误：此脚本需要root权限${NC}" && exit 1
}

# 获取容器列表
get_containers() {
    if command -v lxc-ls &>/dev/null; then
        lxc-ls --fancy | awk 'NR>1'
    elif command -v virlist &>/dev/null; then
        virlist | grep -E '^[0-9]+'
    else
        echo -e "${RED}错误：未检测到容器管理命令${NC}" && exit 1
    fi
}

# 显示带编号的容器列表
show_containers() {
    echo -e "\n${YELLOW}容器列表：${NC}"
    echo -e "${CYAN}编号\t容器ID\t状态\tIP地址${NC}"
    local count=1
    while read -r line; do
        printf "${GREEN}%d)${NC}\t%s\n" "$count" "$(echo "$line" | awk '{print $1"\t"$2"\t"$3}')"
        ((count++))
    done < <(get_containers)
}

# 显示所有资源信息
show_all_stats() {
    local container_id=$1
    clear
    echo -e "${PURPLE}=== 容器 ${container_id} 完整资源报告 ===${NC}"
    
    # CPU信息
    echo -e "\n${GREEN}=== CPU使用情况 ===${NC}"
    lxc-attach -n "$container_id" -- /bin/sh -c "
        if [ -d /sys/devices/system/cpu ]; then
            cores=\$(find /sys/devices/system/cpu -maxdepth 1 -name 'cpu[0-9]*' | wc -l)
        elif [ -f /proc/cpuinfo ]; then
            cores=\$(awk '/^processor/{n++} END{print n+0}' /proc/cpuinfo 2>/dev/null || echo 1)
        else
            cores=1
        fi
        echo \"核心数: \$cores\"
        
        if [ -f /proc/loadavg ]; then
            read -r l1 l2 l3 _ < /proc/loadavg
            echo \"负载: \$l1 \$l2 \$l3 (1/5/15分钟)\"
        else
            echo '负载: 无法获取'
        fi
        
        if [ -f /proc/stat ]; then
            awk '/^cpu / {
                total=\$2+\$3+\$4+\$5+\$6+\$7+\$8;
                used=\$2+\$3+\$4;
                printf \"CPU使用率: %.1f%%\\n\", used*100/total
            }' /proc/stat
        else
            echo 'CPU使用率: 无法获取'
        fi"
    
    # 内存信息
    echo -e "\n${GREEN}=== 内存使用情况 ===${NC}"
    lxc-attach -n "$container_id" -- /bin/sh -c "
        if [ -f /proc/meminfo ]; then
            total=0; free=0; buffers=0; cached=0
            while read -r line; do
                case \"\$line\" in
                    MemTotal:*)
                        total=\${line#*:}
                        total=\${total%%kB*}
                        total=\$((total/1024))
                        ;;
                    MemFree:*)
                        free=\${line#*:}
                        free=\${free%%kB*}
                        free=\$((free/1024))
                        ;;
                    Buffers:*)
                        buffers=\${line#*:}
                        buffers=\${buffers%%kB*}
                        buffers=\$((buffers/1024))
                        ;;
                    Cached:*)
                        cached=\${line#*:}
                        cached=\${cached%%kB*}
                        cached=\$((cached/1024))
                        ;;
                esac
            done < /proc/meminfo
            
            used=\$((total - free - buffers - cached))
            echo \"内存: 总: \${total}M 已用: \${used}M 空闲: \${free}M 缓存: \${cached}M\"
            
            echo -e \"\n内存占用前5进程:\"
            if [ -d /proc ]; then
                for pid in /proc/[0-9]*; do
                    [ -f \"\$pid/statm\" ] && {
                        read -r size rss _ < \"\$pid/statm\"
                        cmdline=\"\"
                        if [ -f \"\$pid/cmdline\" ]; then
                            cmdline=\$(tr -d '\0' < \"\$pid/cmdline\" | head -c50)
                        fi
                        [ -z \"\$cmdline\" ] && [ -f \"\$pid/comm\" ] && cmdline=\$(cat \"\$pid/comm\")
                        printf \"%6d KB %s\\n\" \$((rss*4)) \"\$cmdline\"
                    }
                done 2>/dev/null | sort -rn | head -5
            fi
        else
            echo '无法获取内存信息'
        fi"
    
    # 交换空间
    echo -e "\n${GREEN}=== 交换空间使用 ===${NC}"
    lxc-attach -n "$container_id" -- /bin/sh -c "
        if [ -f /proc/swaps ]; then
            echo -e '设备\t\t类型\t大小\t已用\t优先级'
            while read -r filename type size used priority; do
                [ \"\$filename\" != \"Filename\" ] && \
                printf \"%-15s %-8s %-8s %-8s %-8s\\n\" \"\$filename\" \"\$type\" \"\$size\" \"\$used\" \"\$priority\"
            done < /proc/swaps
        elif [ -f /proc/meminfo ]; then
            swap_total=0; swap_free=0
            while read -r line; do
                case \"\$line\" in
                    SwapTotal:*)
                        swap_total=\${line#*:}
                        swap_total=\${swap_total%%kB*}
                        swap_total=\$((swap_total/1024))
                        ;;
                    SwapFree:*)
                        swap_free=\${line#*:}
                        swap_free=\${swap_free%%kB*}
                        swap_free=\$((swap_free/1024))
                        ;;
                esac
                done < /proc/meminfo
                [ \"\$swap_total\" -gt 0 ] && \
                    echo \"交换空间: 总: \${swap_total}M 已用: \$((swap_total-swap_free))M 空闲: \${swap_free}M\" || \
                    echo '未使用交换空间'
        else
            echo '无法获取交换空间信息'
        fi"
    
    # 硬盘
    echo -e "\n${GREEN}=== 硬盘使用情况 ===${NC}"
    lxc-attach -n "$container_id" -- /bin/sh -c "
        if [ -f /proc/mounts ]; then
            echo -e '挂载点\t\t总空间\t可用空间'
            while read -r dev mountpt fstype _; do
                case \"\$mountpt\" in
                    /proc|/sys|/dev|/run|/tmp|/var/run|/var/tmp) continue ;;
                esac
                
                if [ -d \"\$mountpt\" ]; then
                    stat_output=\"\"
                    if [ -f /usr/bin/stat ]; then
                        stat_output=\$(/usr/bin/stat -fc '%b %a %S' \"\$mountpt\" 2>/dev/null)
                    elif [ -f /bin/stat ]; then
                        stat_output=\$(/bin/stat -fc '%b %a %S' \"\$mountpt\" 2>/dev/null)
                    else
                        total_blocks=\$( (echo 'stat -fc %b \"\$mountpt\"' | sh) 2>/dev/null )
                        free_blocks=\$( (echo 'stat -fc %a \"\$mountpt\"' | sh) 2>/dev/null )
                        block_size=\$( (echo 'stat -fc %S \"\$mountpt\"' | sh) 2>/dev/null )
                        [ -n \"\$total_blocks\" ] && [ -n \"\$free_blocks\" ] && [ -n \"\$block_size\" ] && \
                            stat_output=\"\$total_blocks \$free_blocks \$block_size\"
                    fi
                    
                    if [ -n \"\$stat_output\" ]; then
                        total=\$(echo \"\$stat_output\" | awk '{print \$1*\$3/1024}')
                        avail=\$(echo \"\$stat_output\" | awk '{print \$2*\$3/1024}')
                        printf \"%-15s %.1fM\t%.1fM\\n\" \"\$mountpt\" \"\$total\" \"\$avail\"
                    fi
                fi
            done < /proc/mounts
        else
            echo '无法获取磁盘信息'
        fi
        
        echo -e \"\n${CYAN}磁盘IO统计：${NC}\"
        if [ -f /proc/diskstats ]; then
            echo \"设备       读次数       写次数       读数据KB       写数据KB\"
            echo \"--------------------------------------------------------\"
            awk '\$3 ~ /^(sd|vd|xvd|nvme)/ {
                printf \"%-8s %10d %10d %10.1f %10.1f\\n\", 
                       \$3, \$4, \$8, \$6/2, \$10/2
            }' /proc/diskstats 2>/dev/null || echo \"（未检测到活跃的磁盘设备）\"
        else
            echo \"无法获取详细IO统计（/proc/diskstats 不存在）\"
        fi"
    
    # 网络
    echo -e "\n${GREEN}=== 带宽流量统计 ===${NC}"
    lxc-attach -n "$container_id" -- /bin/sh -c '
        format_bytes() {
            bytes=$1
            if [ $bytes -ge $((1024*1024*1024)) ]; then
                echo "$((bytes/(1024*1024*1024))) GB"
            elif [ $bytes -ge $((1024*1024)) ]; then
                echo "$((bytes/(1024*1024))) MB"
            elif [ $bytes -ge 1024 ]; then
                echo "$((bytes/1024)) KB"
            else
                echo "${bytes} B"
            fi
        }

        if [ ! -f /proc/net/dev ]; then
            echo "无法获取网络流量信息 (/proc/net/dev 不存在)"
            exit 0
        fi

        echo "网络接口    接收流量      发送流量      总流量"
        echo "---------------------------------------------"

        total_recv=0
        total_sent=0
        count=0
        
        while read -r line; do
            case "$line" in
                *face*|*lo*|*Inter*|*Receive*) continue ;;
            esac
            
            interface=$(echo "$line" | awk "{print \$1}" | tr -d :)
            [ -z "$interface" ] && continue
            
            recv_bytes=$(echo "$line" | awk "{print \$2}")
            sent_bytes=$(echo "$line" | awk "{print \$10}")
            
            if ! [[ "$recv_bytes" =~ ^[0-9]+$ ]]; then
                continue
            fi
            
            total_recv=$((total_recv + recv_bytes))
            total_sent=$((total_sent + sent_bytes))
            count=$((count + 1))
            
            printf "%-8s %12s %12s %12s\n" \
                   "$interface" \
                   "$(format_bytes $recv_bytes)" \
                   "$(format_bytes $sent_bytes)" \
                   "$(format_bytes $((recv_bytes + sent_bytes)))"
        done < /proc/net/dev

        if [ $count -eq 0 ]; then
            echo "没有检测到活动的网络接口"
        else
            echo "---------------------------------------------"
            printf "总计: %12s %12s %12s\n" \
                   "$(format_bytes $total_recv)" \
                   "$(format_bytes $total_sent)" \
                   "$(format_bytes $((total_recv + total_sent)))"
        fi
    '
    
    # 运行时长
    echo -e "\n${GREEN}=== 系统运行信息 ===${NC}"
    lxc-attach -n "$container_id" -- /bin/sh -c '
        if [ -f /proc/uptime ]; then
            read uptime _ < /proc/uptime
            
            days=$(( ${uptime%.*}/86400 ))
            hours=$(( (${uptime%.*}%86400)/3600 ))
            mins=$(( (${uptime%.*}%3600)/60 ))
            
            if [ -f /proc/loadavg ]; then
                read l1 l2 l3 _ < /proc/loadavg
                echo "运行时间: ${days}天${hours}小时${mins}分钟  负载: ${l1} ${l2} ${l3}"
            else
                echo "运行时间: ${days}天${hours}小时${mins}分钟"
            fi
        else
            echo "无法获取系统运行信息"
        fi
    '
    
    # IO检测
    echo -e "\n${GREEN}=== IO滥用检测 ===${NC}"
    lxc-attach -n "$container_id" -- /bin/sh -c "
        if [ -f /proc/diskstats ]; then
            echo -e '${CYAN}磁盘活动统计：${NC}'
            while read -r major minor dev reads _ _ _ _ writes _ _ _ _; do
                case \"\$dev\" in
                    sd*|vd*|xvd*|nvme*)
                        echo \"设备 \$dev: 读操作 \$reads 次, 写操作 \$writes 次\"
                        ;;
                esac
            done < /proc/diskstats
            
            echo -e '\n${CYAN}可能的高IO进程：${NC}'
            if [ -d /proc ]; then
                for pid in /proc/[0-9]*; do
                    [ -f \"\$pid/io\" ] && {
                        rchar=\$( (grep '^rchar' \"\$pid/io\" | cut -d' ' -f2) 2>/dev/null )
                        [ -n \"\$rchar\" ] && [ \"\$rchar\" -gt 1000000 ] && {
                            cmdline=\"\"
                            if [ -f \"\$pid/cmdline\" ]; then
                                cmdline=\$(tr -d '\0' < \"\$pid/cmdline\" | head -c50)
                            fi
                            [ -z \"\$cmdline\" ] && [ -f \"\$pid/comm\" ] && cmdline=\$(cat \"\$pid/comm\")
                            echo \"PID \${pid#/proc/}: 读取 \${rchar} 字节 - \${cmdline}\"
                        }
                    } 2>/dev/null
                done | sort -rn | head -5
            fi
        else
            echo '无法获取IO统计信息'
        fi"
    
    read -rp "按回车键返回..."
}

# 检测IO滥用
check_io_abuse() {
    local container_id=$1
    echo -e "\n${RED}=== IO滥用检测 ===${NC}"
    
    lxc-attach -n "$container_id" -- /bin/sh -c "
        # 通过/proc/diskstats检测IO活动
        if [ -f /proc/diskstats ]; then
            echo -e '${CYAN}磁盘活动统计：${NC}'
            while read -r major minor dev reads _ _ _ _ writes _ _ _ _; do
                case \"\$dev\" in
                    sd*|vd*|xvd*|nvme*)
                        echo \"设备 \$dev: 读操作 \$reads 次, 写操作 \$writes 次\"
                        ;;
                esac
            done < /proc/diskstats
            
            echo -e '\n${CYAN}可能的高IO进程：${NC}'
            if [ -d /proc ]; then
                for pid in /proc/[0-9]*; do
                    [ -f \"\$pid/io\" ] && {
                        rchar=\$( (grep '^rchar' \"\$pid/io\" | cut -d' ' -f2) 2>/dev/null )
                        [ -n \"\$rchar\" ] && [ \"\$rchar\" -gt 1000000 ] && {
                            cmdline=\"\"
                            if [ -f \"\$pid/cmdline\" ]; then
                                cmdline=\$(tr -d '\0' < \"\$pid/cmdline\" | head -c50)
                            fi
                            [ -z \"\$cmdline\" ] && [ -f \"\$pid/comm\" ] && cmdline=\$(cat \"\$pid/comm\")
                            echo \"PID \${pid#/proc/}: 读取 \${rchar} 字节 - \${cmdline}\"
                        }
                    } 2>/dev/null
                done | sort -rn | head -5
            fi
        else
            echo '无法获取IO统计信息'
        fi"
    read -rp "按回车键继续..."
}

# 进入容器shell
enter_container_shell() {
    local container_id=$1
    echo -e "${GREEN}正在进入容器 ${container_id} 的shell...${NC}"
    echo -e "${YELLOW}输入 exit 或按 Ctrl+D 返回管理菜单${NC}"
    lxc-attach -n "$container_id" -- /bin/sh || echo -e "${RED}无法进入容器shell${NC}"
}

# 退出脚本
exit_script() {
    echo -e "${YELLOW}正在退出脚本...${NC}"
    exit 0
}

# 容器操作菜单
container_menu() {
    local container_id=$1
    while true; do
        clear
        echo -e "${YELLOW}容器 ${container_id} 管理${NC}"
        echo -e "${GREEN}1. 进入容器监控${NC}"
        echo -e "${GREEN}2. 进入容器shell${NC}"
        echo -e "${GREEN}3. 启动容器${NC}"
        echo -e "${GREEN}4. 停止容器${NC}"
        echo -e "${GREEN}5. 返回主菜单${NC}"
        echo -e "${GREEN}6. 退出脚本${NC}"
        echo -ne "${BLUE}请选择 [1-6]: ${NC}"
        
        read -r choice
        case $choice in
            1)
                if [ "$(lxc-info -n "$container_id" -s | awk '{print $2}')" != "RUNNING" ]; then
                    echo -e "${YELLOW}容器未运行，正在启动...${NC}"
                    lxc-start -n "$container_id" && sleep 2
                fi
                container_monitor "$container_id"
                ;;
            2)
                if [ "$(lxc-info -n "$container_id" -s | awk '{print $2}')" != "RUNNING" ]; then
                    echo -e "${YELLOW}容器未运行，正在启动...${NC}"
                    lxc-start -n "$container_id" && sleep 2
                fi
                enter_container_shell "$container_id"
                ;;
            3)
                echo -e "${YELLOW}正在启动容器...${NC}"
                lxc-start -n "$container_id" && sleep 2
                ;;
            4)
                echo -e "${YELLOW}正在停止容器...${NC}"
                lxc-stop -n "$container_id" && sleep 2
                ;;
            5)
                break
                ;;
            6)
                exit_script
                ;;
            *)
                echo -e "${RED}无效选择！${NC}"
                sleep 1
                ;;
        esac
    done
}

# 容器资源监控菜单
container_monitor() {
    local container_id=$1
    while true; do
        clear
        echo -e "${PURPLE}=== 容器 ${container_id} 资源监控 ===${NC}"
        echo -e "${YELLOW}1. CPU使用情况${NC}"
        echo -e "${YELLOW}2. 内存使用情况${NC}"
        echo -e "${YELLOW}3. 交换空间使用${NC}"
        echo -e "${YELLOW}4. 硬盘使用情况${NC}"
        echo -e "${YELLOW}5. 带宽流量统计${NC}"
        echo -e "${YELLOW}6. 运行时长和负载${NC}"
        echo -e "${YELLOW}7. IO滥用检测${NC}"
        echo -e "${YELLOW}8. 一键列出所有信息${NC}"
        echo -e "${YELLOW}9. 返回容器管理${NC}"
        echo -e "${YELLOW}10. 退出脚本${NC}"
        echo -ne "${BLUE}请选择 [1-10]: ${NC}"
        
        read -r choice
        case $choice in
            1) # CPU
                echo -e "\n${GREEN}=== CPU使用率 ===${NC}"
                lxc-attach -n "$container_id" -- /bin/sh -c "
                    if [ -d /sys/devices/system/cpu ]; then
                        cores=\$(find /sys/devices/system/cpu -maxdepth 1 -name 'cpu[0-9]*' | wc -l)
                    elif [ -f /proc/cpuinfo ]; then
                        cores=\$(awk '/^processor/{n++} END{print n+0}' /proc/cpuinfo 2>/dev/null || echo 1)
                    else
                        cores=1
                    fi
                    echo \"核心数: \$cores\"
                    
                    if [ -f /proc/loadavg ]; then
                        read -r l1 l2 l3 _ < /proc/loadavg
                        echo \"负载: \$l1 \$l2 \$l3 (1/5/15分钟)\"
                    else
                        echo '负载: 无法获取'
                    fi
                    
                    if [ -f /proc/stat ]; then
                        awk '/^cpu / {
                            total=\$2+\$3+\$4+\$5+\$6+\$7+\$8;
                            used=\$2+\$3+\$4;
                            printf \"CPU使用率: %.1f%%\\n\", used*100/total
                        }' /proc/stat
                    else
                        echo 'CPU使用率: 无法获取'
                    fi"
                read -rp "按回车键继续..."
                ;;
            2) # 内存
                echo -e "\n${GREEN}=== 内存使用 ===${NC}"
                lxc-attach -n "$container_id" -- /bin/sh -c "
                    if [ -f /proc/meminfo ]; then
                        total=0; free=0; buffers=0; cached=0
                        while read -r line; do
                            case \"\$line\" in
                                MemTotal:*)
                                    total=\${line#*:}
                                    total=\${total%%kB*}
                                    total=\$((total/1024))
                                    ;;
                                MemFree:*)
                                    free=\${line#*:}
                                    free=\${free%%kB*}
                                    free=\$((free/1024))
                                    ;;
                                Buffers:*)
                                    buffers=\${line#*:}
                                    buffers=\${buffers%%kB*}
                                    buffers=\$((buffers/1024))
                                    ;;
                                Cached:*)
                                    cached=\${line#*:}
                                    cached=\${cached%%kB*}
                                    cached=\$((cached/1024))
                                    ;;
                            esac
                        done < /proc/meminfo
                        
                        used=\$((total - free - buffers - cached))
                        echo \"内存: 总: \${total}M 已用: \${used}M 空闲: \${free}M 缓存: \${cached}M\"
                        
                        echo -e \"\n内存占用前5进程:\"
                        if [ -d /proc ]; then
                            for pid in /proc/[0-9]*; do
                                [ -f \"\$pid/statm\" ] && {
                                    read -r size rss _ < \"\$pid/statm\"
                                    cmdline=\"\"
                                    if [ -f \"\$pid/cmdline\" ]; then
                                        cmdline=\$(tr -d '\0' < \"\$pid/cmdline\" | head -c50)
                                    fi
                                    [ -z \"\$cmdline\" ] && [ -f \"\$pid/comm\" ] && cmdline=\$(cat \"\$pid/comm\")
                                    printf \"%6d KB %s\\n\" \$((rss*4)) \"\$cmdline\"
                                }
                            done 2>/dev/null | sort -rn | head -5
                            fi
                    else
                        echo '无法获取内存信息'
                    fi"
                read -rp "按回车键继续..."
                ;;
            3) # 交换空间
                echo -e "\n${GREEN}=== 交换空间 ===${NC}"
                lxc-attach -n "$container_id" -- /bin/sh -c "
                    if [ -f /proc/swaps ]; then
                        echo -e '设备\t\t类型\t大小\t已用\t优先级'
                        while read -r filename type size used priority; do
                            [ \"\$filename\" != \"Filename\" ] && \
                            printf \"%-15s %-8s %-8s %-8s %-8s\\n\" \"\$filename\" \"\$type\" \"\$size\" \"\$used\" \"\$priority\"
                        done < /proc/swaps
                    elif [ -f /proc/meminfo ]; then
                        swap_total=0; swap_free=0
                        while read -r line; do
                            case \"\$line\" in
                                SwapTotal:*)
                                    swap_total=\${line#*:}
                                    swap_total=\${swap_total%%kB*}
                                    swap_total=\$((swap_total/1024))
                                    ;;
                                SwapFree:*)
                                    swap_free=\${line#*:}
                                    swap_free=\${swap_free%%kB*}
                                    swap_free=\$((swap_free/1024))
                                    ;;
                            esac
                        done < /proc/meminfo
                        [ \"\$swap_total\" -gt 0 ] && \
                            echo \"交换空间: 总: \${swap_total}M 已用: \$((swap_total-swap_free))M 空闲: \${swap_free}M\" || \
                            echo '未使用交换空间'
                    else
                        echo '无法获取交换空间信息'
                    fi"
                read -rp "按回车键继续..."
                ;;
            4) # 硬盘
                echo -e "\n${GREEN}=== 磁盘使用 ===${NC}"
                lxc-attach -n "$container_id" -- /bin/sh -c "
                    if [ -f /proc/mounts ]; then
                        echo -e '挂载点\t\t总空间\t可用空间'
                        while read -r dev mountpt fstype _; do
                            case \"\$mountpt\" in
                                /proc|/sys|/dev|/run|/tmp|/var/run|/var/tmp) continue ;;
                            esac
                            
                            if [ -d \"\$mountpt\" ]; then
                                stat_output=\"\"
                                if [ -f /usr/bin/stat ]; then
                                    stat_output=\$(/usr/bin/stat -fc '%b %a %S' \"\$mountpt\" 2>/dev/null)
                                elif [ -f /bin/stat ]; then
                                    stat_output=\$(/bin/stat -fc '%b %a %S' \"\$mountpt\" 2>/dev/null)
                                else
                                    total_blocks=\$( (echo 'stat -fc %b \"\$mountpt\"' | sh) 2>/dev/null )
                                    free_blocks=\$( (echo 'stat -fc %a \"\$mountpt\"' | sh) 2>/dev/null )
                                    block_size=\$( (echo 'stat -fc %S \"\$mountpt\"' | sh) 2>/dev/null )
                                    [ -n \"\$total_blocks\" ] && [ -n \"\$free_blocks\" ] && [ -n \"\$block_size\" ] && \
                                        stat_output=\"\$total_blocks \$free_blocks \$block_size\"
                                fi
                                
                                if [ -n \"\$stat_output\" ]; then
                                    total=\$(echo \"\$stat_output\" | awk '{print \$1*\$3/1024}')
                                    avail=\$(echo \"\$stat_output\" | awk '{print \$2*\$3/1024}')
                                    printf \"%-15s %.1fM\t%.1fM\\n\" \"\$mountpt\" \"\$total\" \"\$avail\"
                                fi
                            fi
                        done < /proc/mounts
                    else
                        echo '无法获取磁盘信息'
                    fi
                    
                    echo -e \"\n${CYAN}磁盘IO统计：${NC}\"
                    if [ -f /proc/diskstats ]; then
                        echo \"设备       读次数       写次数       读数据KB       写数据KB\"
                        echo \"--------------------------------------------------------\"
                        awk '\$3 ~ /^(sd|vd|xvd|nvme)/ {
                            printf \"%-8s %10d %10d %10.1f %10.1f\\n\", 
                                   \$3, \$4, \$8, \$6/2, \$10/2
                        }' /proc/diskstats 2>/dev/null || echo \"（未检测到活跃的磁盘设备）\"
                    else
                        echo \"无法获取详细IO统计（/proc/diskstats 不存在）\"
                    fi"
                read -rp "按回车键继续..."
                ;;
            5) # 带宽
                echo -e "\n${GREEN}=== 网络流量统计 ===${NC}"
                lxc-attach -n "$container_id" -- /bin/sh -c '
                    format_bytes() {
                        bytes=$1
                        if [ $bytes -ge $((1024*1024*1024)) ]; then
                            echo "$((bytes/(1024*1024*1024))) GB"
                        elif [ $bytes -ge $((1024*1024)) ]; then
                            echo "$((bytes/(1024*1024))) MB"
                        elif [ $bytes -ge 1024 ]; then
                            echo "$((bytes/1024)) KB"
                        else
                            echo "${bytes} B"
                        fi
                    }

                    if [ ! -f /proc/net/dev ]; then
                        echo "无法获取网络流量信息 (/proc/net/dev 不存在)"
                        exit 0
                    fi

                    echo "网络接口    接收流量      发送流量      总流量"
                    echo "---------------------------------------------"

                    total_recv=0
                    total_sent=0
                    count=0
                    
                    while read -r line; do
                        case "$line" in
                            *face*|*lo*|*Inter*|*Receive*) continue ;;
                        esac
                        
                        interface=$(echo "$line" | awk "{print \$1}" | tr -d :)
                        [ -z "$interface" ] && continue
                        
                        recv_bytes=$(echo "$line" | awk "{print \$2}")
                        sent_bytes=$(echo "$line" | awk "{print \$10}")
                        
                        if ! [[ "$recv_bytes" =~ ^[0-9]+$ ]]; then
                            continue
                        fi
                        
                        total_recv=$((total_recv + recv_bytes))
                        total_sent=$((total_sent + sent_bytes))
                        count=$((count + 1))
                        
                        printf "%-8s %12s %12s %12s\n" \
                               "$interface" \
                               "$(format_bytes $recv_bytes)" \
                               "$(format_bytes $sent_bytes)" \
                               "$(format_bytes $((recv_bytes + sent_bytes)))"
                    done < /proc/net/dev

                    if [ $count -eq 0 ]; then
                        echo "没有检测到活动的网络接口"
                    else
                        echo "---------------------------------------------"
                        printf "总计: %12s %12s %12s\n" \
                               "$(format_bytes $total_recv)" \
                               "$(format_bytes $total_sent)" \
                               "$(format_bytes $((total_recv + total_sent)))"
                    fi
                '
                read -rp "按回车键继续..."
                ;;
            6) # 运行时长
                echo -e "\n${GREEN}=== 系统运行信息 ===${NC}"
                lxc-attach -n "$container_id" -- /bin/sh -c '
                    if [ -f /proc/uptime ]; then
                        read uptime _ < /proc/uptime
                        
                        days=$(( ${uptime%.*}/86400 ))
                        hours=$(( (${uptime%.*}%86400)/3600 ))
                        mins=$(( (${uptime%.*}%3600)/60 ))
                        
                        if [ -f /proc/loadavg ]; then
                            read l1 l2 l3 _ < /proc/loadavg
                            echo "运行时间: ${days}天${hours}小时${mins}分钟  负载: ${l1} ${l2} ${l3}"
                        else
                            echo "运行时间: ${days}天${hours}小时${mins}分钟"
                        fi
                    else
                        echo "无法获取系统运行信息"
                    fi
                '
                read -rp "按回车键继续..."
                ;;
            7) # IO滥用检测
                check_io_abuse "$container_id"
                ;;
            8) # 一键列出所有信息
                show_all_stats "$container_id"
                ;;
            9)
                break
                ;;
            10)
                exit_script
                ;;
            *)
                echo -e "${RED}无效选择！${NC}"
                sleep 1
                ;;
        esac
    done
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "${PURPLE}=== Virtualizor LXC容器管理 ===${NC}"
        echo -e "${GREEN}1. 查看所有容器${NC}"
        echo -e "${GREEN}2. 直接进入容器${NC}"
        echo -e "${GREEN}3. 退出脚本${NC}"
        echo -ne "${BLUE}请选择 [1-3]: ${NC}"
        
        read -r choice
        case $choice in
            1)
                show_containers
                echo -ne "${YELLOW}输入容器编号（回车返回）: ${NC}"
                read -r num
                if [[ "$num" =~ ^[0-9]+$ ]]; then
                    container_id=$(get_containers | sed -n "${num}p" | awk '{print $1}')
                    [ -n "$container_id" ] && container_menu "$container_id"
                fi
                ;;
            2)
                echo -ne "${YELLOW}输入容器ID: ${NC}"
                read -r container_id
                [ -n "$container_id" ] && container_menu "$container_id"
                ;;
            3)
                exit_script
                ;;
            *)
                echo -e "${RED}无效选择！${NC}"
                sleep 1
                ;;
        esac
    done
}

# 启动脚本
check_root
main_menu