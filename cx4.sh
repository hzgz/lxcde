#!/bin/bash

# Virtualizor LXC容器管理终极版 v3.7 (零依赖版)

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

# 保存iptables规则
save_iptables_rules() {
    echo -e "${YELLOW}正在保存iptables规则...${NC}"
    if command -v iptables-save &>/dev/null; then
        if [ -d /etc/sysconfig ]; then
            iptables-save > /etc/sysconfig/iptables
            echo -e "${GREEN}规则已保存到/etc/sysconfig/iptables${NC}"
        elif [ -d /etc/iptables ]; then
            iptables-save > /etc/iptables/rules.v4
            echo -e "${GREEN}规则已保存到/etc/iptables/rules.v4${NC}"
        else
            echo -e "${YELLOW}无法确定iptables规则保存位置，请手动保存${NC}"
            echo -e "${YELLOW}可以使用: iptables-save > /path/to/iptables.rules${NC}"
            return 1
        fi
    else
        echo -e "${RED}未找到iptables-save命令${NC}"
        return 1
    fi
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

# 获取容器状态
get_container_status() {
    local container_id=$1
    if command -v lxc-info &>/dev/null; then
        lxc-info -n "$container_id" -s | awk '{print $2}'
    else
        virlist | awk -v id="$container_id" '$1 == id {print $2}'
    fi
}

# 显示容器资源使用情况
show_container_usage() {
    local container_id=$1
    echo -e "\n${PURPLE}=== 容器 ${container_id} 资源使用情况 ===${NC}"
    
    # 检查容器是否运行
    local status
    status=$(get_container_status "$container_id")
    if [ "$status" != "RUNNING" ]; then
        echo -e "${YELLOW}容器未运行，无法获取资源信息${NC}"
        return 1
    fi
    
    # CPU使用情况
    echo -e "\n${GREEN}=== CPU使用情况 ===${NC}"
    lxc-attach -n "$container_id" -- /bin/sh -c "
        if [ -f /proc/stat ]; then
            awk '/^cpu / {
                total=\$2+\$3+\$4+\$5+\$6+\$7+\$8;
                used=\$2+\$3+\$4;
                printf \"CPU使用率: %.1f%%\\n\", used*100/total
            }' /proc/stat
        else
            echo '无法获取CPU信息'
        fi
        
        if [ -f /proc/loadavg ]; then
            read -r l1 l2 l3 _ < /proc/loadavg
            echo \"负载: \$l1 \$l2 \$l3 (1/5/15分钟)\"
        fi"
    
    # 内存使用情况
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
            echo \"内存: 总: \${total}M 已用: \${used}M 空闲: \${free}M\"
        else
            echo '无法获取内存信息'
        fi"
    
    # 磁盘使用情况
    echo -e "\n${GREEN}=== 磁盘使用情况 ===${NC}"
    lxc-attach -n "$container_id" -- /bin/sh -c "
        if [ -f /proc/mounts ]; then
            echo -e '挂载点\t\t已用空间\t可用空间'
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
                        used=\$(echo \"\$stat_output\" | awk '{print (\$1-\$2)*\$3/1024}')
                        avail=\$(echo \"\$stat_output\" | awk '{print \$2*\$3/1024}')
                        printf \"%-15s %.1fM\t%.1fM\\n\" \"\$mountpt\" \"\$used\" \"\$avail\"
                    fi
                fi
            done < /proc/mounts
        else
            echo '无法获取磁盘信息'
        fi"
    
    # 网络流量
    echo -e "\n${GREEN}=== 网络流量 ===${NC}"
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

        if [ -f /proc/net/dev ]; then
            echo "网络接口    接收流量      发送流量"
            echo "----------------------------------"
            while read -r line; do
                case "$line" in
                    *face*|*lo*|*Inter*|*Receive*) continue ;;
                esac
                
                interface=$(echo "$line" | awk "{print \$1}" | tr -d :)
                [ -z "$interface" ] && continue
                
                recv_bytes=$(echo "$line" | awk "{print \$2}")
                sent_bytes=$(echo "$line" | awk "{print \$10}")
                
                printf "%-8s %12s %12s\n" \
                       "$interface" \
                       "$(format_bytes $recv_bytes)" \
                       "$(format_bytes $sent_bytes)"
            done < /proc/net/dev
        else
            echo "无法获取网络流量信息"
        fi
    '
}

# 显示所有容器资源占用
show_all_containers_usage() {
    clear
    echo -e "${PURPLE}=== 所有容器资源占用情况 ===${NC}"
    
    # 获取容器列表
    local containers
    containers=$(get_containers | awk '{print $1}')
    if [ -z "$containers" ]; then
        echo -e "${YELLOW}没有找到任何容器${NC}"
        read -rp "按回车键返回..."
        return
    fi
    
    # 显示容器选择菜单
    show_containers
    echo -e "\n${YELLOW}请输入要查看的容器编号(支持多个编号，用空格分隔，如:1 3 5):${NC}"
    read -r -a selected
    
    if [ ${#selected[@]} -eq 0 ]; then
        return
    fi
    
    clear
    echo -e "${PURPLE}=== 所选容器资源占用情况 ===${NC}"
    
    # 获取所有容器ID数组
    local container_ids=()
    while read -r line; do
        container_ids+=("$(echo "$line" | awk '{print $1}')")
    done < <(get_containers)
    
    # 显示每个选中的容器资源使用情况
    for index in "${selected[@]}"; do
        if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#container_ids[@]} ]; then
            local container_id="${container_ids[$((index-1))]}"
            show_container_usage "$container_id"
            echo -e "${BLUE}----------------------------------${NC}"
        else
            echo -e "${RED}无效编号: $index${NC}"
        fi
    done
    
    read -rp "按回车键返回..."
}

# 母鸡滥用规则管理
abuse_rules_menu() {
    while true; do
        clear
        echo -e "${PURPLE}=== 母鸡滥用规则管理 ===${NC}"
        echo -e "${GREEN}1. 屏蔽BT/PT下载${NC}"
        echo -e "${GREEN}2. 屏蔽挖矿程序${NC}"
        echo -e "${GREEN}3. 屏蔽测速网站${NC}"
        echo -e "${GREEN}4. 查看当前规则${NC}"
        echo -e "${GREEN}5. 清除所有规则${NC}"
        echo -e "${GREEN}6. 保存规则到配置文件${NC}"
        echo -e "${GREEN}7. 返回主菜单${NC}"
        echo -ne "${BLUE}请选择 [1-7]: ${NC}"
        
        read -r choice
        case $choice in
            1) # 屏蔽BT/PT下载
                echo -e "\n${YELLOW}正在添加BT/PT屏蔽规则...${NC}"
                iptables -A OUTPUT -m string --string "torrent" --algo bm -j DROP
                iptables -A OUTPUT -m string --string ".torrent" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "peer_id=" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "announce" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "info_hash" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "get_peers" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "find_node" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "BitTorrent" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "announce_peer" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "BitTorrent protocol" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "announce.php?passkey=" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "magnet:" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "xunlei" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "sandai" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "Thunder" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "XLLiveUD" --algo bm -j DROP
                echo -e "${GREEN}BT/PT屏蔽规则已添加${NC}"
                save_iptables_rules
                read -rp "按回车键继续..."
                ;;
            2) # 屏蔽挖矿程序
                echo -e "\n${YELLOW}正在添加挖矿程序屏蔽规则...${NC}"
                iptables -A OUTPUT -m string --string "ethermine.com" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "antpool.one" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "antpool.com" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "pool.bar" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "get_peers" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "announce_peer" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "find_node" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "seed_hash" --algo bm -j DROP
                echo -e "${GREEN}挖矿程序屏蔽规则已添加${NC}"
                save_iptables_rules
                read -rp "按回车键继续..."
                ;;
            3) # 屏蔽测速网站
                echo -e "\n${YELLOW}正在添加测速网站屏蔽规则...${NC}"
                iptables -A OUTPUT -m string --string ".speed" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "speed." --algo bm -j DROP
                iptables -A OUTPUT -m string --string ".speed." --algo bm -j DROP
                iptables -A OUTPUT -m string --string "fast.com" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "speedtest.net" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "speedtest.com" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "speedtest.cn" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "test.ustc.edu.cn" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "10000.gd.cn" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "db.laomoe.com" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "jiyou.cloud" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "ovo.speedtestcustom.com" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "speed.cloudflare.com" --algo bm -j DROP
                iptables -A OUTPUT -m string --string "speedtest" --algo bm -j DROP
                echo -e "${GREEN}测速网站屏蔽规则已添加${NC}"
                save_iptables_rules
                read -rp "按回车键继续..."
                ;;
            4) # 查看当前规则
                echo -e "\n${YELLOW}当前iptables规则:${NC}"
                iptables -L OUTPUT -n --line-numbers | grep -i "string"
                read -rp "按回车键继续..."
                ;;
            5) # 清除所有规则
                echo -e "\n${YELLOW}正在清除所有字符串匹配规则...${NC}"
                local line_num
                while line_num=$(iptables -L OUTPUT -n --line-numbers | grep -i "string" | head -1 | awk '{print $1}'); do
                    [ -n "$line_num" ] && iptables -D OUTPUT "$line_num"
                done
                echo -e "${GREEN}所有字符串匹配规则已清除${NC}"
                save_iptables_rules
                read -rp "按回车键继续..."
                ;;
            6) # 保存规则
                save_iptables_rules
                read -rp "按回车键继续..."
                ;;
            7)
                break
                ;;
            *)
                echo -e "${RED}无效选择！${NC}"
                sleep 1
                ;;
        esac
    done
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
                   "$(format_bytes $sent_bytes)" \
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
                if [ "$(get_container_status "$container_id")" != "RUNNING" ]; then
                    echo -e "${YELLOW}容器未运行，正在启动...${NC}"
                    lxc-start -n "$container_id" && sleep 2
                fi
                container_monitor "$container_id"
                ;;
            2)
                if [ "$(get_container_status "$container_id")" != "RUNNING" ]; then
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
                               "$(format_bytes $sent_bytes)" \
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
        echo -e "${GREEN}3. 查看所有容器占用${NC}"
        echo -e "${GREEN}4. 母鸡滥用规则管理${NC}"
        echo -e "${GREEN}5. 退出脚本${NC}"
        echo -ne "${BLUE}请选择 [1-5]: ${NC}"
        
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
                show_all_containers_usage
                ;;
            4)
                abuse_rules_menu
                ;;
            5)
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