#!/bin/sh

# Settings
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/as.conf"
LISTS_DIR="/etc/nfqws2/lists"
[ -d /opt/etc/nfqws2/lists ] && LISTS_DIR="/opt/etc/nfqws2/lists"
DOWNLOAD_URL="https://sw.ext.io/asw/%s?v4"
#DOWNLOAD_URL="https://asn.web2core.workers.dev/%s?v4"
DOWNLOAD_URL_Z2K="https://raw.githubusercontent.com/necronicle/z2k/refs/heads/z2k-enhanced/files/lists/tcp16_nets.txt"

# Check installed utils
if command -v wget >/dev/null 2>&1; then
    FETCHER="wget -q -T 10 --timeout=30 -O -"
elif command -v uclient-fetch >/dev/null 2>&1; then
    FETCHER="uclient-fetch -q -T 10 -O -"
else
    echo "Error: please install wget or uclient-fetch" >&2
    exit 1
fi

# Colors
if [ -t 1 ]; then
  ESC=$(printf '\033')
  RED="${ESC}[0;31m"
  GREEN="${ESC}[0;32m"
  YELLOW="${ESC}[0;33m"
  BLUE="${ESC}[0;34m"
  CYAN="${ESC}[0;36m"
  MAGENTA="${ESC}[0;35m"
  DIM="${ESC}[2m"
  NC="${ESC}[0m"
  BOLD="${ESC}[1m"
else
  RED= GREEN= YELLOW= BLUE= CYAN= MAGENTA= DIM= NC= BOLD=
fi

# Script header
draw_header() {
    clear
    echo "=================================================="
    echo "            IPSet AS List Generator            "
    echo "=================================================="
    echo ""
}

# Make simple merge cidr after sorted
merge_cidrs() {
    awk '
    function ip2dec(ip,   a) {
        split(ip, a, ".")
        return (a[1] * 16777216) + (a[2] * 65536) + (a[3] * 256) + a[4]
    }
    function dec2ip(dec) {
        return int(dec / 16777216) "." int((dec % 16777216) / 65536) "." int((dec % 65536) / 256) "." (dec % 256)
    }
    {
        ip = $1; mask = 32
        if (index(ip, "/") > 0) {
            split(ip, a, "/")
            ip = a[1]; mask = int(a[2])
        }
        sz = int(2 ^ (32 - mask))
        s = int(ip2dec(ip) / sz) * sz
        e = s + sz - 1

        if (c == 0) { cs = s; ce = e; c = 1; next }

        if (s <= ce + 1) {
            if (e > ce) ce = e
        } else {
            out(cs, ce)
            cs = s; ce = e
        }
    }
    END { if (c > 0) out(cs, ce) }

    function out(s, e,   cur, m, sz) {
        cur = s
        while (cur <= e) {
            for (m = 0; m <= 32; m++) {
                sz = int(2 ^ (32 - m))
                if (cur % sz == 0 && cur + sz - 1 <= e) break
            }
            print dec2ip(cur) "/" m
            cur += int(2 ^ (32 - m))
        }
    }
    '
}

# Make mask big for optimize
mask_16() {
    awk '
    {
        split($1, a, "/")
        ip = a[1]
        mask = (a[2] != "") ? int(a[2]) : 32
        split(ip, oct, ".")
        if (mask > 16) {
            print oct[1] "." oct[2] ".0.0/16"
        } else {
            print $1
        }
    }
    '
}

get_providers() {
    cut -d':' -f1 "$CONF_FILE" | grep -v '^#' | sort -u
}

menu_detail_as() {
    target_prov="$1"

    while true; do
        draw_header
        echo " Edit AS: $target_prov"
        echo " --------------------------------------------------"

        i=1
        rm -f /tmp/sub_as_index.tmp

        while IFS=':=' read -r prov as_name status || [ -n "$prov" ]; do
            [ "$prov" != "$target_prov" ] && continue

            mark="[ ]"
            [ "$status" = "1" ] && mark="[*]"

            printf " %2d) %s %s\n" "$i" "$mark" "$as_name"
            echo "${i}:${as_name}:${status}" >> /tmp/sub_as_index.tmp
            i=$((i + 1))
        done < "$CONF_FILE"

        echo " --------------------------------------------------"
        echo "$GREEN""  A) Enable all"$NC"    "$RED"D) Disable all""$NC"
        echo "  0) Back"
        echo ""
        printf " Enter number AS for On/Off "
        read -r choice

        case "$choice" in
            0) rm -f /tmp/sub_as_index.tmp; break ;;
            [aA])
                sed -i "s/^${target_prov}:\(.*\)=0$/${target_prov}:\1=1/" "$CONF_FILE"
                ;;
            [dD])
                sed -i "s/^${target_prov}:\(.*\)=1$/${target_prov}:\1=0/" "$CONF_FILE"
                ;;
            *)
                target=$(grep "^${choice}:" /tmp/sub_as_index.tmp 2>/dev/null)
                if [ -n "$target" ]; then
                    as_name=$(echo "$target" | cut -d':' -f2)
                    curr_st=$(echo "$target" | cut -d':' -f3)

                    if [ "$curr_st" = "1" ]; then
                        new_st="0"
                    else
                        new_st="1"
                    fi

                    sed -i "s/^${target_prov}:${as_name}=${curr_st}$/${target_prov}:${as_name}=${new_st}/" "$CONF_FILE"
                fi
                ;;
        esac
    done
}

menu_providers() {
    while true; do
        draw_header
        echo " AS:"
        echo " --------------------------------------------------"

        i=1
        rm -f /tmp/prov_index.tmp

        for p in $(get_providers); do
            has_enabled=0
            has_disabled=0

            while IFS=':=' read -r prov as_name status || [ -n "$prov" ]; do
                [ "$prov" != "$p" ] && continue
                [ "$status" = "1" ] && has_enabled=1
                [ "$status" = "0" ] && has_disabled=1
            done < "$CONF_FILE"

            if [ "$has_enabled" -eq 1 ] && [ "$has_disabled" -eq 1 ]; then
                mark="[-]"
                st_code="mix"
            elif [ "$has_enabled" -eq 1 ]; then
                mark="[*]"
                st_code="on"
            else
                mark="[ ]"
                st_code="off"
            fi

            printf " %2d) %s %s\n" "$i" "$mark" "$p"
            echo "${i}:${p}:${st_code}" >> /tmp/prov_index.tmp
            i=$((i + 1))
        done

        echo " --------------------------------------------------"
        echo "$GREEN""  A) Enable all"$NC"    "$RED"D) Disable all""$NC"
        echo "  0) Menu"
        echo ""
        printf " Enter AS (<number> — Edit, t<number> — On/Off): "
        read -r choice

        case "$choice" in
            0) rm -f /tmp/prov_index.tmp; break ;;
            [aA])
                sed -i 's/=\(0\|1\)$/=1/' "$CONF_FILE"
                ;;
            [dD])
                sed -i 's/=\(0\|1\)$/=0/' "$CONF_FILE"
                ;;
            t*)
                num=$(echo "$choice" | sed 's/^t//')
                target=$(grep "^${num}:" /tmp/prov_index.tmp 2>/dev/null)
                if [ -n "$target" ]; then
                    p_name=$(echo "$target" | cut -d':' -f2)
                    st_code=$(echo "$target" | cut -d':' -f3)

                    if [ "$st_code" = "on" ]; then
                        sed -i "s/^${p_name}:\(.*\)=1$/${p_name}:\1=0/" "$CONF_FILE"
                    else
                        sed -i "s/^${p_name}:\(.*\)=0$/${p_name}:\1=1/" "$CONF_FILE"
                    fi
                fi
                ;;
            *)

                target=$(grep "^${choice}:" /tmp/prov_index.tmp 2>/dev/null)
                if [ -n "$target" ]; then
                    p_name=$(echo "$target" | cut -d':' -f2)
                    menu_detail_as "$p_name"
                fi
                ;;
        esac
    done
}

# Get ipset as list from z2k
run_download_z2k() {
    draw_header
    mkdir -p "$LISTS_DIR"
    output_file="${LISTS_DIR}/ipset_as.list"

    echo " Download from Z2K..."
    echo " ------------------------------------------------"

    $FETCHER "$DOWNLOAD_URL_Z2K" | awk '!/^#/ && !/:/ && NF>=2 {print $2}' | sort -u > "$output_file"

    if [ -s "$output_file" ]; then
        ip_count=$(wc -l < "$output_file")
        echo "$GREEN"" [✓] Done! Full file: $(basename "$output_file") ($ip_count cidr)""$NC"
    else
        echo "$RED"" [X] Error: Downloaded file is empty!""$NC"
    fi

    echo " ------------------------------------------------"
    printf " Press Enter for Menu..."
    read -r _
}

# Download all as
run_download_all_as() {
    draw_header
    mkdir -p "$LISTS_DIR"
    output_file="${LISTS_DIR}/ipset_as.list"
    temp_file="${output_file}.tmp"
    > "$temp_file"

    echo " Download all AS..."
    echo " ------------------------------------------------"

# Select all providers
    all_as_list=$(cut -d'=' -f1 "$CONF_FILE" | grep -v '^#' | cut -d':' -f2 | sort -u)

    for as in $all_as_list; do
        echo " Download - $as..."
        $FETCHER "$(printf "$DOWNLOAD_URL" "$as")" 2>/dev/null >> "$temp_file"
        echo "" >> "$temp_file"
    done

    echo ""
    echo " Optimize ipset list..."
    if [ -s "$temp_file" ]; then
        grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' "$temp_file" \
            | mask_16 \
            | sort -t . -k 1,1n -k 2,2n -k 3,3n -k 4,4n -u \
            | merge_cidrs > "$output_file"

        ip_count=$(wc -l < "$output_file")
        echo "$GREEN"" [✓] Done! Full file: $(basename "$output_file") ($ip_count cidr)""$NC"
    else
        echo "$RED"" [X] Error: Downloaded file is empty!""$NC"
        > "$output_file"
    fi

    rm -f "$temp_file"
    echo " ------------------------------------------------"
    printf " Press Enter for Menu..."
    read -r _
}

# Download selected as
run_download_providers() {
    draw_header
    mkdir -p "$LISTS_DIR"
    echo " Download selected AS..."
    echo " --------------------------------------------------"

    active_providers=$(grep '=1$' "$CONF_FILE" | cut -d':' -f1 | sort -u)

    if [ -z "$active_providers" ]; then
        echo "$YELLOW"" [!] Warning: AS not selected!""$NC"
    else
        for prov in $active_providers; do
            output_file="${LISTS_DIR}/ipset_as_${prov}.list"
            temp_file="${output_file}.tmp"
            > "$temp_file"

            as_list=$(grep "^${prov}:" "$CONF_FILE" | grep '=1$' | cut -d':' -f2 | cut -d'=' -f1)

            echo " Download: $prov"
            for as in $as_list; do
                echo " Download $as..."
                $FETCHER "$(printf "$DOWNLOAD_URL" "$as")" 2>/dev/null >> "$temp_file"
            done

            if [ -s "$temp_file" ]; then
                grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' "$temp_file" \
                    | mask_16 \
                    | sort -t . -k 1,1n -k 2,2n -k 3,3n -k 4,4n -u \
                    | merge_cidrs > "$output_file"

                ip_count=$(wc -l < "$output_file")
                echo "$GREEN"" [✓] Done! File: $(basename "$output_file") ($ip_count cidr).""$NC"
            else
                echo "$RED"" [X] Error: No data!""$NC"
                rm -f "$output_file"
            fi

            rm -f "$temp_file"
            echo ""
        done
    fi

    echo " --------------------------------------------------"
    printf " Press Enter for Menu..."
    read -r _
}

# Main menu
while true; do
    draw_header
    echo " 1) Download all AS Z2K ipset_as.list"
    echo " 2) Download all AS ipset_as.list"
    echo " 3) Download ipset_as_<provider>.list"
    echo " 4) Select AS"
    echo " 0) Exit"
    echo ""
    printf " Enter: "
    read -r main_choice

    case "$main_choice" in
        1) run_download_z2k ;;
        2) run_download_all_as ;;
        3) run_download_providers ;;
        4) menu_providers ;;
        0) clear; exit 0 ;;
    esac
done
