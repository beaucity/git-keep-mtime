#!/bin/sh
#
# ============================================================================
#
#  Git Keep MTime
#
#  File:
#      git_kmt.sh
#
#  Purpose:
#      Git client wrapper. designed to preserve and track file modification time (`mtime`)
#      information during Git operations.
#
#  How it works:
#      The wrapper is intentionally implemented as POSIX sh.  It keeps the
#      original Git executable behind .git_kmt/git and forwards all commands that
#      are not handled by KMT to that executable.
#
#  Version:
#      0.2.9
#
#  Storage model:
#      git notes --ref=kmt/mtime <commit>
#
#  Note format:
#      <STX>path<ETX>unix_mtime<ETX>birth_time
#
# ============================================================================

APP='git'
APP_KMT='git_kmt'
KMT_FULL_NAME='Git Keep MTime'
KMT_VERSION='0.2.9'

META_NAME="time-notes"

NOTE_REF="kmt/mtime"

STX=$(printf '\x02')
ETX=$(printf '\x03')
EOT=$(printf '\x04')


CUR_DIR=$(pwd -P)
REPO_ROOT=
GIT_DIR=
SUB_DIR=
IS_LOOK_INSTALLED=0


##############################################################################
# Utility
##############################################################################

PLATFORM=""

#FF=$(printf '\x0C')
SO=$(printf '\x0E')
ELF="$SO"
LF="
"

KMT_DEBUG_LOG_FILE=
ENABLE_OID_VERIFY=0

TZ_SECONDS=

last_log_ts=
logging=

log()
{
    log_ret=$?

    [ -z "$KMT_DEBUG_LOG_FILE" ] && return 0

    [ "$logging" = "1" ] && return $log_ret

    logging=1

    if [ -n "$last_log_ts" ]; then
        tsd=$(float_diff "$(date +%s.%N)" "$last_log_ts")
    else
        tsd=$(format_timestamp "$(date +%s)")
    fi

    case "$KMT_DEBUG_LOG_FILE" in
        "&1")
            printf "%s\n" "[ $$ + $tsd] $*"
            ;;
        "&2")
            printf "%s\n" "[ $$ + $tsd] $*" >&2
            ;;
        *)
            printf "%s\n" "[ $$ + $tsd] $*" >> "$KMT_DEBUG_LOG_FILE"
            ;;
    esac

    last_log_ts=$(date +%s.%N)

    logging=0

#    return $log_ret
    return 0
}

set_debug_log()
{
    KMT_DEBUG_LOG_FILE=${1:-"&2"}
    return 0
}

fix_len()
{
    str=$1
    len=$2
    printf "% ${len}s" "$str"
}

full_path_name()
{
    dir=${1:-.}

    str="$(realpath "$(dirname "$dir")")/$(basename "$dir")"

#    str="$(cd "$(dirname "$dir")" && realpath)/$(basename "$dir")" || return 1

    printf "%s\n" "$str"

    return 0
}

float_diff() {
    a="$1" b="$2"

    case "$a" in
        *.*) ia="${a%%.*}"; fa=$(printf "%s" "${a#*.}000000" | cut -c 1-6 | sed 's/^0*//') ;;
        *) ia=$a; fa="0" ;;
    esac

    case "$b" in
        *.*) ib="${b%%.*}"; fb=$(printf "%s" "${b#*.}000000" | cut -c 1-6 | sed 's/^0*//') ;;
        *) ib=$b; fb="0" ;;
    esac

    [ "$(echo "$ia" | cut -c 1-1)" = "-" ] && sa='-1' && ia=$(echo "$ia" | cut -c 2-) || sa='1'
    [ "$(echo "$ib" | cut -c 1-1)" = "-" ] && sb='-1' && ib=$(echo "$ib" | cut -c 2-) || sb='1'

#    log "$a, $b, $ia, $fa, $ib, $fb"
    ! diff=$(( (sa)*(ia * 1000000 + fa) - (sb)*(ib * 1000000 + fb) )) && echo "exp failed: $a $b $ia $fa $ib $fb" && return 1
    sign=""; [ "$diff" -lt 0 ] && sign="-" && diff=$(( -diff ))
    printf "%s%d.%06d" "$sign" $((diff / 1000000)) $((diff % 1000000))
    return 0
}

REPLACE_RESULT=
fast_replace()
{
    str=$1
    old=$2
    new=$3

    while true
    do
        r_p2="${str#*"$old"}"
        [ "$r_p2" = "$str" ] && break

        r_p1="${str%%"$old"*}"
        str="$r_p1$new$r_p2"
    done
    REPLACE_RESULT="$str"
    return 0
}

DECODE_RESULT=
decode_from_inline()
{
    fast_replace "$1" "$ELF" "$LF"
    DECODE_RESULT="$REPLACE_RESULT"
}

ENCODE_RESULT=
encode_into_inline()
{
    fast_replace "$1" "$LF" "${2:-"$ELF"}"
    ENCODE_RESULT="$REPLACE_RESULT"
}

##############################################################################
# Platform
##############################################################################

detect_platform()
{
    case "$(uname -s)" in

        Linux*)
            PLATFORM="linux"
            ;;

        Darwin*)
            PLATFORM="macos"
            ;;

        *)
            echo "Unsupported platform"
            return 1
            ;;

    esac
}

get_url_timestamp() {
    url="$1"
    ! str=$(curl --connect-timeout 2 --max-time 3 -s -I "$url" 2>/dev/null) && return 1

    date_str=$(echo "$str" | grep -i "^Date:" | head -1 | sed 's/^[Dd][Aa][Tt][Ee]: //' | tr -d '\r\n')

    [ -z "$date_str" ] && echo "Request failed. $url" && return 1

    if [ "$PLATFORM" = "macos" ]; then
        clean=$(echo "$date_str" | sed 's/,//')
        ! LC_TIME=C date -j -f "%a %d %b %Y %H:%M:%S %Z" "$clean" +%s 2>/dev/null && return 1
    else
        ! LC_TIME=C date -d "$date_str" +%s 2>/dev/null && return 1
    fi

    return 0
}

detect_time_offset()
{
    max_offset=60

    dirs=$(select_dirs "$@")
    url=
    while IFS= read -r dir
    do
        [ -z "$dir" ] && dir='.'

        decode_from_inline "$dir"; dir="$DECODE_RESULT"

        [ ! -e "$dir" ] && continue

        ! url=$(app_get_remote_url "$dir") && break

        [ -n "$url" ] && break
    done<<EOF
$dirs
EOF

    for web_server in "$url" "https://www.baidu.com" "http://www.google.com";
    do
        [ -z "$web_server" ] && continue

        ! server_ts=$(get_url_timestamp "$web_server") && echo "request timestamp failed $web_server" && continue

        [ -z "$server_ts" ] && echo "Invalid timestamp $server_ts" && continue

        now_ts=$(date +%s)
        diff=$((now_ts-server_ts))
        sign=$(echo "$diff" | cut -c 1-1 )
        diff=${diff#*-}

        if [ "$diff" -gt "$max_offset" ]; then
            echo "Local machine system time seems incorrect $diff, $now_ts, $server_ts,
are you sure to continue? (y/N)"
            read -r key
            [ "$key" != "y" ] && return 1
        fi

        break
    done

    return 0
}

detect_time_zone()
{
    ! offset_str=$(date +%z) && echo "Get timezone failed." && return 1

    sign=$(echo "$offset_str" | cut -c 1-1)
    hh=$(echo "$offset_str" | cut -c 2-3 | sed 's/^0//' )

    mm=$(echo "$offset_str" | cut -c 4-5 | sed 's/^0//' )

    TZ_SECONDS=$((hh*3600 + mm*60))
    [ "$sign" = "-" ] && TZ_SECONDS=$((-TZ_SECONDS))

    return 0
}

find_command()
{
    #find by command and which, sometimes, command output the removed path

    path=$(command -v "${1}" 2>/dev/null) && [ -x "$path" ] && printf "%s\n" "$path" && return 0

    path=$(which "${1}" 2>/dev/null) && [ -x "$path" ] && printf "%s\n" "$path" && return 0

    return 1
}

##############################################################################
# Time Functions
##############################################################################

is_timestamp()
{
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
#    echo "$1" | grep -Eq '^[0-9]+$'
}

format_timestamp()
{
    fast_format_timestamp "$@"
    echo "$FORMAT_RESULT"
}

fast_format_timestamp() {
    FORMAT_RESULT=
    __ts=$1
    [ -z "$1" ] && return 1

    tz=${2:-"$TZ_SECONDS"}

    __ts=$((__ts + tz))

    mode=$3

    days=$((__ts / 86400))
    sod=$((__ts % 86400))

    if [ "$sod" -lt 0 ]; then
        sod=$((sod + 86400))
        days=$((days - 1))
    fi

    hour=$((sod / 3600))
    sod=$((sod % 3600))
    minute=$((sod / 60))
    second=$((sod % 60))

    # Gregorian calendar calculation
    z=$((days + 719468))

    if [ "$z" -ge 0 ]; then
        era=$((z / 146097))
    else
        era=$(((z - 146096) / 146097))
    fi

    doe=$((z - era * 146097))

    yoe=$(((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365))

    year=$((yoe + era * 400))

    doy=$((doe - (365 * yoe + yoe / 4 - yoe / 100)))

    mp=$(((5 * doy + 2) / 153))

    day=$((doy - (153 * mp + 2) / 5 + 1))
    month=$((mp + 3))

    if [ "$month" -gt 12 ]; then
        month=$((month - 12))
        year=$((year + 1))
    fi

    [ $month -lt 10 ] && month="0$month"
    [ $day -lt 10 ] && day="0$day"
    [ $hour -lt 10 ] && hour="0$hour"
    [ $minute -lt 10 ] && minute="0$minute"
    [ $second -lt 10 ] && second="0$second"

    [ "$mode" = "1" ] && FORMAT_RESULT="${year}${month}${day}${hour}${minute}.${second}" ||
    FORMAT_RESULT="${year}-${month}-${day} ${hour}:${minute}:${second}"
}

format_timestamp_by_date()
{
    date -r "$1" "+%Y-%m-%d %H:%M:%S"
}

format_timestamp_old() {
#    log "ts: $1, tz: $TZ_SECONDS"
    [ -z "$1" ] && return 1
#    echo "$1"
#    return 0
#    date -r "$1" "+%Y-%m-%d %H:%M:%S" && return 0

    ! is_timestamp "$1" && return 1


    ts=$(($1 + ${2:-"$TZ_SECONDS"}))
    d=$((ts / 86400 + 1))
    s=$((ts % 86400))
    [ "$s" -lt 0 ] && s=$((s + 86400)) && d=$((d - 1))

    y=1970
    while true; do
        leap=0
        [ $((y % 4)) -eq 0 ] && { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; } && leap=1
        days=365; [ "$leap" -eq 1 ] && days=366
        [ "$d" -gt "$days" ] || break
        d=$((d - days)); y=$((y + 1))
    done

    m=1
    while true; do
        leap=0
        [ $((y % 4)) -eq 0 ] && { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; } && leap=1
        case "$m" in
            1|3|5|7|8|10|12) dm=31 ;;
            4|6|9|11) dm=30 ;;
            2) dm=$((leap ? 29 : 28)) ;;
        esac
        [ "$d" -gt "$dm" ] || break
        d=$((d - dm)); m=$((m + 1))
    done

    printf "%04d-%02d-%02d %02d:%02d:%02d" "$y" "$m" "$d" $((s/3600)) $(((s%3600)/60)) $((s%60))
}

get_file_mtime()
{
    file="$1"

    case "$PLATFORM" in

        linux)

            if ! stat -c %Y "$file"; then
                printf "%s\n" "get_file_mtime failed: '$file'"
                return 1
            fi
            ;;


        macos)

            if ! stat -f %m "$file"; then
                printf "%s\n" "get_file_mtime failed: '$file'"
                return 1
            fi
            ;;

        *)

            return 1
            ;;

    esac

    return 0
}

set_file_mtime()
{
    file_to_set="$1"
    timestamp="$2"

    [ ! -e "$file_to_set" ] && echo "File not exists: $file_to_set" && return 1

    ! is_timestamp "$timestamp" && echo "invalid timestamp: $timestamp, '$file_to_set'" && return 1

    case "$PLATFORM" in

        linux)
            touch -m -d "@$timestamp" "$file_to_set" || return 1
            ;;

        macos)
            fast_format_timestamp "$timestamp" "" "1"
#            touch -m -t "$(date -r "$timestamp" "+%Y%m%d%H%M.%S")" "$file_to_set" || return 1
            touch -m -t "$FORMAT_RESULT" "$file_to_set" || return 1
            ;;

        *)
            return 1
            ;;
    esac

    return 0
}

get_timestamp()
{
    dt=$1

    [ -z "$dt" ] && return 0

    case "$PLATFORM" in
        linux)
            date -u -d "$dt" +%s
            ;;
        macos)
            dt="${dt%%.*}Z"
            date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$dt" +%s
            ;;
    esac
}

python_touch()
{
    cmd=$(find_command "python3") || cmd=$(find_command "python")

    "$cmd" -c '
import os, sys
buf = getattr(sys.stdin, "buffer", sys.stdin)
e = 0
for line in buf:
    if isinstance(line, bytes):
        line = line.rstrip(b"\n").rstrip(b"\r")
        etx = b"\x03"
    else:
        line = line.rstrip("\n").rstrip("\r")
        etx = "\x03"
    if not line:
        continue
    name, sep, ts = line.partition(etx)

    if not sep:
        sys.stderr.write("skip: %r\n" % (line,))
        e += 1
        continue
    try:
        p = name if isinstance(name, str) else os.fsdecode(name)
        p=p.replace("\x0E", "\n")
        os.utime(p, (int(ts), int(ts)))
    except Exception as x:
        sys.stderr.write("%r: %s\n" % (name, x))
        e += 1
sys.exit(1 if e else 0)
'
}

pre_batch_touch()
{
    while IFS="$ETX" read -r fn ts _
    do
        if [ "$PLATFORM" = 'linux' ]; then
            printf "%s\0" "$ts"
            printf "%s\0" "$fn"
        else
            fast_format_timestamp "$ts" "" "1"
            printf "%s\0" "$FORMAT_RESULT"
            printf "%s\0" "$fn"
        fi
    done
}

batch_touch()
{
    if [ "$SCAN_BACKEND" = 'python' ]; then
        python_touch
    else
        if [ "$PLATFORM" = 'linux' ]; then
            pre_batch_touch | xargs -0 -P 4 -n 2 sh -c 'touch -m -d "@$1" "$2"'
        else
            pre_batch_touch | xargs -0 -P 4 -n 2 touch -m -t
        fi
    fi
}

grep_arg()
{
    key=$1
    shift
    for p in "$@";
    do
        printf "%s\n" "$p" | grep -E "$key" && return 0
    done
    return 1
}

exclude_opt_args_from()
{
    return 0
}

str_a_has_word_b()
{
    a="$1"
    b="$2"
    for it in $a;
    do
        [ "$it" = "$b" ] && return 0
    done

    return 1
}

skip_opt_args_from()
{
    from="$1"
    kv_keys="$2"
    shift
    shift

    skip_next_value=0
    [ -z "$from" ] && start=1 || start=0
    for arg in "$@"
    do
        if [ "$start" = 0 ]; then
            [ "$from" = "$arg" ] && start=1
            continue
        fi

        case "$arg" in
            --*)
              opt_name=${arg#*--}
              str_a_has_word_b "$kv_keys" "$opt_name" && skip_next_value=1 || skip_next_value=0
              ;;
            -*)
              opt_name=${arg#*-}
              str_a_has_word_b "$kv_keys" "$opt_name" && skip_next_value=1 || skip_next_value=0
              ;;
            *)
              [ "$skip_next_value" = "1" ] && skip_next_value=0 && continue
              printf "%s\n" "$arg"
#              log "arg: $arg"
              return 0
              ;;
        esac
    done

    [ "$start" = 1 ] && return 0

    return 1
}

skip_opt_args()
{
    skip_opt_args_from "" "$@"
}

_select_from_args()
{
    select_one_only=$1
    inline=$2
    key=$3

    shift
    shift
    shift

    opt_key=

    for p in "$@";
    do
        case "$p" in
            "$key"=*)
                value="${p#*"$key"=}"

                [ "$inline" = "1" ] && encode_into_inline "$value" && value="$ENCODE_RESULT"

                printf "%s\n" "$value"

                return 0
            ;;
            "$key")
                opt_key=$p && continue
            ;;
            *)
                if [ -n "$opt_key" ]; then
                    value="$p"

                    [ "$inline" = "1" ] && encode_into_inline "$value" && value="$ENCODE_RESULT"

                    printf "%s\n" "$value"
                    [ "$select_one_only" = 1 ] && return 0
                fi
            ;;
        esac
    done

    [ -n "$opt_key" ] && return 0

    return 1
}

select_arg()
{
    key=$1
    shift
    _select_from_args 1 0 "$key" "$@"
}

select_any()
{
    keys="$1"
    shift

    for p in $keys
    do
        select_arg "$p" "$@" && return 0
    done
    return 1
}

print_n()
{
    [ -n "$1" ] && printf "%s\n" "$1"
    return 0
}

select_arg_pos()
{
    key=$1
    shift
    pos=0
    for p in "$@";
    do
        [ "$p" = "$key" ] && echo "$pos" && return 0
        pos=$(( pos+1 ))
    done
    return 1
}

select_args()
{
    key=$1
    shift
    _select_from_args 0 0 "$key" "$@"
}

select_args_inline()
{
    key=$1
    shift
    _select_from_args 0 1 "$key" "$@"
}

select_dirs()
{
    for p in "$@";
    do
        if [ -n "$start_item" ]; then
            [ "$p" = "$start_item" ] && start_item=
            continue
        fi

        case "$p" in
            -*)
                opt_key=$p
                #Skip option key
                continue
            ;;

            *)
                if [ "$opt_key" = '-m' ]; then
                  #Skip comment content
                  opt_key=
                  continue
                else
                    if [ -n "$opt_key" ] && [ ! -e "$p" ]; then
                        #It is mostly a option value, skip it
                        opt_key=
                        continue
                    fi
                    opt_key=
                fi
            ;;
        esac

        value="$p" && encode_into_inline "$value" && value="$ENCODE_RESULT"

        printf "%s\n" "$value"
    done

    return 0
}

insert_after() {
    _pos=$1
    _count=$2
    shift 2

    _news=
    _k=0
    while [ "$_k" -lt "$_count" ]; do
        _e=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
        _news="$_news '$_e'"
        shift
        _k=$((_k + 1))
    done

    _out=
    _i=1
    _done=0
    for _a in "$@"; do
        _e=$(printf '%s' "$_a" | sed "s/'/'\\\\''/g")
        _out="$_out '$_e'"
        if [ "$_i" -eq "$_pos" ] && [ "$_done" -eq 0 ]; then
            _out="$_out$_news"
            _done=1
        fi
        _i=$((_i + 1))
    done

    if [ "$_done" -eq 0 ]; then
        _out="$_out$_news"
    fi

    printf 'set --%s\n' "$_out"
}


ORIGIN_APP=

##############################################################################
# Version
##############################################################################

show_version()
{
    echo "$KMT_FULL_NAME. Version: ${KMT_VERSION}"
}

##############################################################################
# Installation API
##############################################################################

kmt_is_installed()
{
    app_entry_path=$(find_command "$APP") || return 1
    install_dir=$(dirname "$app_entry_path")
    kmt_path="$install_dir/$APP_KMT"

    orig_caller_path="$install_dir/.$APP_KMT/$APP"

    if  [ -L "$app_entry_path" ] &&
        [ "$(readlink "$app_entry_path")" = "$kmt_path" ] &&
        [ -x "$kmt_path" ] &&

        [ -x "$orig_caller_path" ]; then
            if [ -L "$orig_caller_path" ]; then
                [ "$(basename "$(readlink "$orig_caller_path")")" = "$APP" ] && return 0
            else
                return 0
            fi
    fi

    return 1
}

kmt_has_been_uninstalled()
{
    app_entry_path=$(find_command "$APP") || return 1
    install_dir=$(dirname "$app_entry_path")
    kmt_path="$install_dir/$APP_KMT"
    kmt_sub_dir="$install_dir/.$APP_KMT"
    orig_caller_path="$kmt_sub_dir/$APP"

    if [ -L "$app_entry_path" ] && [ "$(readlink "$app_entry_path")" = "$kmt_path" ]; then
        log "Linked with $app_entry_path -> $kmt_path not removed completely"
        return 1
    fi

    if [ -f "$kmt_path" ]; then
        log "$APP_KMT not removed completely"
        return 1
    fi

    if [ -e "$install_dir/.$APP_KMT" ]; then
        log "$install_dir/.$APP_KMT not removed completely"
        return 1
    fi

    return 0
}

detect_original_app()
{
    if ! app_entry_path=$(find_command "$APP"); then
        echo "Original $APP executable not found."
        return 1
    fi

    if kmt_is_installed; then
        ORIGIN_APP="$(dirname "$app_entry_path")/.$APP_KMT/$APP"

    else
        [ -L "$app_entry_path" ] && [ "$(basename "$(readlink "$app_entry_path")")" = "$APP_KMT" ] && echo "Malform link $app_entry_path -> $(readlink "$app_entry_path")" && return 1
        ORIGIN_APP="$app_entry_path"
    fi

    return 0
}

find_install_dir()
{
    original_dir=$1

    old_ifs=$IFS
    IFS=:
    for dir in $PATH; do
        [ "$original_dir" = "$dir" ] && break

        [ -d "$dir" ] || continue
        [ -w "$dir" ] || continue

        echo "$dir"
        break
    done

    IFS=$old_ifs
    return 0
}

is_relative_link()
{
    [ ! -L "$1" ] && echo "not link: $1" && return 1

    path=$(readlink "$1")
#    echo "path: $path"
    case $path in
        \.*)
#        echo "is relative path: $path"
        return 0
        ;;
    esac

    return 1
}

check_executable_when_moved()
{
    [ -z "$APP" ] && echo "invalid app" && return 1

    orig_app_path="$1"
    [ -z "$orig_app_path" ] && echo "invalid orig_app_path" && return 1

    dir=$(dirname "$orig_app_path")

    kmt_sub_dir="$dir/.$APP_KMT"
    mv_to="$kmt_sub_dir/$APP"

    [ -e "$kmt_sub_dir" ] && echo "$kmt_sub_dir already exists." && return 1

    ! mkdir -p "$kmt_sub_dir" && echo "mkdir $kmt_sub_dir failed." && return 1

    ! mv "$orig_app_path" "$mv_to" && return 1

    if [ -x "$mv_to" ]; then
        echo "$mv_to executable"
        mv "$mv_to" "$orig_app_path" && rm -r "$kmt_sub_dir" && return 0
#        rm -f "$mv_to"
    fi

#    rm -f "$mv_to"
    echo "$mv_to un-executable"
    mv "$mv_to" "$orig_app_path" && rm -r "$kmt_sub_dir" && return 1
}

kmt_install()
{
    str=$("$APP" kmt-version 2>/dev/null) && echo "$str is already installed." && return 1

    ! orig_app_path=$(find_command "$APP") && echo "find $APP failed" &&  return 1

    original_dir=$(dirname "$orig_app_path")

    #DOT move the link app, when it is link to a relative path
    if [ -w "$original_dir" ] && check_executable_when_moved "$orig_app_path" ; then
        install_dir=$original_dir
        concealed_method='move'
    else
        install_dir=$(find_install_dir "$original_dir") || {
            log "cannot find a writable PATH directory before original git"
            return 1
        }
        concealed_method='cover'
    fi

    app_entry_path="$install_dir/$APP"
    kmt_path="$install_dir/$APP_KMT"
    kmt_sub_dir="$install_dir/.$APP_KMT"
    orig_caller_path="$kmt_sub_dir/$APP"

    ! cp_from=$(full_path_name "$0") && echo "Invalid installation script file" && return 1

    if [ ! -f "$kmt_path" ]; then
        if [ "$1" = "--link" ]; then
            if ! ln -s "$cp_from" "$kmt_path"; then    #link mode
                echo "Link $kmt_path -> $cp_from failed!"
                return 1
            else
                echo "Linked $kmt_path -> $cp_from successfully."
            fi
        else
            if ! cp "$cp_from" "$kmt_path"; then
                echo "Copy $cp_from to $kmt_path failed!"
                return 1
            else
                echo "Copied $cp_from to $kmt_path successfully."
            fi

            if ! chmod +x "$kmt_path"; then
                echo "Add executable permission to $kmt_path failed!"
                rm -f "$kmt_path" || echo "Rollback: remove $kmt_path failed."
                return 1
            else
                echo "Added executable permission to $kmt_path successfully."
            fi
        fi
    fi

    mkdir -p "$kmt_sub_dir" || return 1

    if [ "$concealed_method" = 'move' ]; then
        if ! mv "$orig_app_path" "$orig_caller_path"; then
            echo "Move $orig_app_path to $orig_caller_path failed!"
            rm -rf "$kmt_sub_dir" || echo "Rollback: remove $kmt_sub_dir failed."
            rm -f "$kmt_path" || echo "Rollback: remove $kmt_path failed."
            return 1
        else
            echo "$orig_app_path" > "$kmt_sub_dir/${APP}_restore_path"
            echo "Moved $orig_app_path to $orig_caller_path successfully."
            if [ ! -x "$orig_caller_path" ]; then
                echo "$orig_caller_path become un-executable! rollback..."
                ! mv "$orig_caller_path" "$orig_app_path" && echo "Rollback: restore $orig_caller_path->$orig_app_path failed."
                rm -rf "$kmt_sub_dir" || echo "Rollback: remove $kmt_sub_dir failed."
                rm -f "$kmt_path" || echo "Rollback: remove $kmt_path failed."
                return 1
            fi
        fi
    else
        if ! ln -s "$orig_app_path" "$orig_caller_path"; then
            echo "Link $orig_caller_path -> $orig_app_path failed!"
            rm -rf "$kmt_sub_dir" || echo "Rollback: remove $kmt_sub_dir failed."
            rm -f "$kmt_path" || echo "Rollback: remove $kmt_path failed."
            return 1
        else
            echo "" > "$kmt_sub_dir/${APP}_restore_path"
            echo "Linked $orig_caller_path -> $orig_app_path successfully."
        fi
    fi

    if ! ln -s "$kmt_path" "$app_entry_path"; then
        echo "Link $app_entry_path -> $kmt_path failed!"
        if [ "$concealed_method" = 'move' ]; then
            ! mv "$orig_caller_path" "$orig_app_path" && echo "Rollback: restore $orig_caller_path->$orig_app_path failed."
        else
            ! rm -f "$orig_caller_path" && echo "Rollback: remove $orig_caller_path failed."
        fi

        rm -rf "$kmt_sub_dir" || echo "Rollback: remove $kmt_sub_dir failed."
        rm -f "$kmt_path" || echo "Rollback: remove $kmt_path failed."
        return 1
    else
        echo "Added symlink $app_entry_path -> $kmt_path successfully."
    fi

    echo "$KMT_FULL_NAME has been installed successfully."
    echo "  install directory: $install_dir"
    echo "  install mode: $([ "$1" = '--link' ] && echo "link->$cp_from" || echo "entity" )"
    echo "  original git: $orig_caller_path$([ "$concealed_method" = 'cover' ] && echo " -> $orig_app_path")"
#    echo "  origin concealed method: $concealed_method"

    return 0
}

kmt_uninstall()
{
    ! kmt_is_installed && echo "$KMT_FULL_NAME is not installed yet." && return 1

    app_entry_path=$(find_command "$APP") || return 1
    install_dir=$(dirname "$app_entry_path")
    kmt_path="$install_dir/$APP_KMT"
    kmt_sub_dir="$install_dir/.$APP_KMT"
    orig_caller_path="$kmt_sub_dir/$APP"

    [ -z "$app_entry_path" ] && echo "$APP not found" && return 1

    ! rm -f "$app_entry_path" && echo "Remove $app_entry_path failed!" && return 1
    echo "Removed $app_entry_path successfully."

    ! rm -f "$kmt_path" && echo "Remove $kmt_path failed." && return 1
    echo "Removed $kmt_path successfully."

    if orig_restore_path=$(cat "$kmt_sub_dir/${APP}_restore_path") && [ -n "$orig_restore_path" ]; then
        ! mv "$orig_caller_path" "$orig_restore_path" && echo "Move $orig_caller_path to $orig_restore_path failed." && return 1
        echo "Moved $orig_caller_path to $orig_restore_path successfully."
    else
        if [ -L "$orig_caller_path" ]; then
            ! rm -f "$orig_caller_path" && echo "Remove $orig_app_path failed." && return 1
            echo "Removed $orig_caller_path successfully."
        else
            echo "orig_restore_path is empty but $orig_caller_path is not a symlink"
            return 1
        fi
    fi

    ! rm -rf "$kmt_sub_dir" && echo "Remove $kmt_sub_dir failed." && return 1

    echo "Removed $kmt_sub_dir successfully."

    echo "$KMT_FULL_NAME has been uninstalled successfully."

    return 0
}

kmt_upgrade()
{
    [ -z "$APP" ] && echo "invalid app" && return 1

    if str=$("$APP" kmt-version 2>/dev/null); then
        echo "$str is already installed, uninstall it ..."

        if ! "$APP" kmt-uninstall; then
            echo "Uninstall failed."
            return 1
        fi

        which "$APP"

        command -v "$APP"

        ! orig_app_path=$(find_command "$APP") && echo "Original $APP executable not found. $orig_app_path" && return 1

        ! kmt_install "$@" && echo "Upgrade failed." && return 1

        echo "$KMT_FULL_NAME has been upgraded successfully."

        return 0

    else
        echo "$KMT_FULL_NAME is not installed, installing now."
        kmt_install "$@" && return 0 || return 1
    fi
}


##############################################################################
# KMT-UI
##############################################################################

SEP=$(printf '\x03')

auto_set_kmt_scan_backend()
{
    if str=$(find_command 'python3') || str=$(find_command 'python') || str=$(find_command 'python2'); then
        SCAN_BACKEND='python'
    elif [ -n "$(find_command 'join')" ] && [ -n "$(find_command 'awk')" ]; then
        SCAN_BACKEND='join'
    else
        SCAN_BACKEND='posix'
    fi
    return 0
}

detect_conf()
{
    if ! app_entry_path=$(find_command "$APP"); then
        echo "Original $APP executable not found."
        return 1
    fi

    app_kmt_conf="$(dirname "$app_entry_path")/$APP_KMT.conf"

    find_in_conf()
    {
        key="$1"
        file="$2"
        grep -o "^${key}:\s*.*" "$file" | sed "s/${key}: *//"
    }

    if [ -f "$app_kmt_conf" ]; then
        [ -z "$KMT_DEBUG_LOG_FILE" ] && KMT_DEBUG_LOG_FILE=$(find_in_conf "kmt_debug_log" "$app_kmt_conf")
        ENABLE_OID_VERIFY=$(find_in_conf "enable_oid_verify" "$app_kmt_conf")
    fi

    return 0
}

set_kmt_scan_backend()
{
    p=$1
    SCAN_BACKEND="${p#*=}"
    [ -z "$SCAN_BACKEND" ] && ! auto_set_kmt_scan_backend && return 1

    case "$SCAN_BACKEND" in
        posix|join|python)
            ;;
        auto)
            auto_set_kmt_scan_backend
            ;;
        *)
            echo "Invalid scanning backend $SCAN_BACKEND"
            return 1
            ;;
    esac

    log "SCAN_BACKEND: $SCAN_BACKEND"

    return 0

}

kmt_command_handler()
{
    cmd=$1
    shift

    for p in "$@";
    do
        case "$p" in
            --scan-backend=*)
                [ "$1" = "$p" ] && shift
                ! set_kmt_scan_backend "${p#*=}" && return 1
            ;;
        esac
    done

    [ -z "$SCAN_BACKEND" ] && ! auto_set_kmt_scan_backend && return 1

    dirs=$(select_dirs "$@")
    while IFS= read -r dir
    do
        decode_from_inline "$dir"; dir="$DECODE_RESULT"

        ! app_is_working_copy "$dir" && return 1
    done << EOF
$dirs
EOF

    ! detect_time_offset "$@" && return 1

    show_version

    echo "Scanning Backend: $SCAN_BACKEND"
    echo "Current Directory: $(pwd)"
    echo ""


    if [ -z "$cmd" ] || [ "$cmd" = "ui" ] || [ "$cmd" = "main" ]; then
        kmt_ui "$@"
    else
        kmt_foreach_file "$cmd" "$@"
    fi
}

batch_stat()
{
    if [ "$PLATFORM" = 'linux' ]; then
        xargs -0 -L 100 stat -c "%n$SEP%Y"
    else
        xargs -0 -L 100 stat -f "%N$SEP%m"
    fi
}

on_file_scan()
{
    file=$1
    file_mts=$2
    file_cts=$3
    prop_mts=$4
    prop_cts=$5

    last_cts=$6
    l2nd_cts=${7:-0}
    first_cts=${8:-0}

    [ "$file" = '.' ] && return 0

    checked_count=$(( checked_count+1 ))

    file_completed=1
    file_completable=0
    file_effected=0
    file_conflicts=0

    [ -z "$file_mts" ] && echo "No file mtime provided: '$*'" && return 1
    [ -z "$file_cts" ] && echo "No file btime provided: '$*'" && return 1


    if [ -n "$prop_mts" ]; then
        if [ "$file_mts" != "$prop_mts" ] && [ -f "$file" ]; then
            file_completed=0
            if [ "$file_mts" -gt "$prop_mts" ]; then
                if [ "$cmd" = "synchronize" ]; then
                    ! set_file_mtime "$file" "$prop_mts" && echo "Synchronize failed $(format_timestamp "$prop_mts") '$file'" && return 1
                    echo "Synchronizing mtime $(format_timestamp "$prop_mts") '$file'"
                    file_effected=1
                else
                    [ "$cmd" = "show_synchronizable" ] && echo "Synchronizable $(format_timestamp "$prop_mts") from $(format_timestamp "$file_mts") $file"
                    synchronizable_count=$(( synchronizable_count+1 ))
                fi
            elif [ "$l2nd_cts" -lt "$file_mts" ]; then
                if [ "$cmd" = "resolve" ]; then
    #                    now_ts=$(date +%s)
                    if [ "$file_mts" -gt "$now_ts" ]; then
                        echo "The file mtime can not be committed, because it is in the future. $(format_timestamp "$file_mts") $file"
                        return 2
                    fi

                    ! str=$(app_complete_file_time "$file" "1" "$file_mts" "$last_cts") && echo "$str" && return 1
                    echo "Resolve conflicting mtime $(format_timestamp "$prop_mts") replace with $(format_timestamp "$file_mts") '$file'"

                    file_effected=1
                else
                    file_conflicts=1
    #                log "prop_ts: $prop_ts, file_ts: $file_ts"
                    [ "$cmd" = "show_conflict" ] && echo "Conflict mtime repos: $(format_timestamp "$prop_mts") local: $(format_timestamp "$file_mts") $file"
                fi
            else
                echo "Invalidate file-mtime: $(format_timestamp "$file_mts") $file"
            fi
        fi
    else
        [ -z "$last_cts" ] && echo "No versioned timestamp provided: '$file'" && return 1

        if [ "$l2nd_cts" -lt "$file_mts" ] && [ "$file_mts" -lt "$last_cts" ]; then
            if [ "$cmd" = 'complete' ]; then
                if [ "$file_mts" -gt "$now_ts" ]; then
                    echo "The file mtime can not be committed, because it is in the future. $(format_timestamp "$file_mts") $file"
                    return 2
                fi

                ! app_complete_file_time "$file" "1" "$file_mts" "$last_cts" &&
                    echo "Complete mtime failed, commit-time: $(format_timestamp "$last_cts")  file-mtime: $(format_timestamp "$file_mts") '$file'" &&  return 1

                echo "Completing mtime $(format_timestamp "$file_mts") '$file'"

                file_effected=1
            else
                if [ "$cmd" = "show_completable" ]; then
                    echo "Completable mtime $(format_timestamp "$last_cts") $(format_timestamp "$file_mts") $file"
                fi
                file_completable=1
            fi
        else
            [ "$cmd" = "show_unsynchronizable" ] && echo "Unsynchronizable $(format_timestamp "$last_cts") $(format_timestamp "$file_mts") $file"
            unsynchronizable_count=$(( unsynchronizable_count+1 ))
        fi
    fi

    if [ -n "$prop_cts" ]; then
        if [ "$file_cts" -lt "$prop_cts" ]; then
            if [ "$cmd" = "resolve" ]; then
                ! app_complete_file_time "$file" "2" "$file_cts" "$first_cts" &&
                    echo "Resolve btime failed $(format_timestamp "$prop_cts") $(format_timestamp "$file_cts") '$file'" &&  return 1

                echo "Resolve conflicting mtime $(format_timestamp "$prop_cts") replace with $(format_timestamp "$file_cts") '$file'"
                file_effected=1
            else
                [ "$cmd" = "show_conflict" ] && echo "Conflict btime repos: $(format_timestamp "$prop_cts") local: $(format_timestamp "$file_cts") $file"
                file_conflicts=1
            fi
        fi
    else
        file_completed=0
        [ -z "$first_cts" ] && echo "No first commit timestamp provided: '$file'" && return 1

        if [ "$file_cts" -lt "$first_cts" ]; then
            if [ "$cmd" = 'complete' ]; then
                ! app_complete_file_time "$file" "2" "$file_cts" "$first_cts" && echo "Complete btime failed, commit-time: $(format_timestamp "$first_cts") file-btime: $(format_timestamp "$file_cts") '$file'" &&  return 1
                echo "Completing btime $(format_timestamp "$file_cts") '$file'"
                file_effected=1
            else
                if [ "$cmd" = "show_completable" ]; then
                    echo "Completable btime $(format_timestamp "$first_cts") $(format_timestamp "$file_cts") $file"
                fi
                file_completable=1
            fi
        fi
    fi

    if [ "$file_completed" = 1 ]; then
        completed_count=$(( completed_count+1 ))
        fast_format_timestamp "$file_mts"
        [ "$cmd" = "show_completed" ] && echo "Completed $FORMAT_RESULT $file"
    fi

    [ "$file_effected" = 1 ] && effected_count=$(( effected_count+1 ))
    [ "$file_completable" = 1 ] && completable_count=$(( completable_count+1 ))
    [ "$file_conflicts" = 1 ] && conflict_count=$(( conflict_count+1 ))

    return 0
}

kmt_foreach_file()
{
    if [ $# = 0 ]; then
        echo "Invalid command"
        return 1
    fi

    cmd=$1

    shift

    checked_count=0
    completed_count=0
    completable_count=0
    synchronizable_count=0
    conflict_count=0
    unsynchronizable_count=0

    effected_count=0

    [ "$cmd" = 'sync' ] && cmd='synchronize'

    case $cmd in
        scan)
            dirs=$(select_dirs "$@")
            dirs_inline=$(echo "$dirs" | tr '\n' ' ' | sed 's/[ \t]*$//')

            echo "Scanning versioned files in directories $dirs_inline..."
            ;;
        show_completed)
            echo "Listing completed files..."
            ;;
        show_completable)
            echo "Listing mtime completable files..."
            ;;
        show_synchronizable)
            echo "Listing mtime synchronizable files..."
            ;;
        show_conflict)
            echo "Listing files with mtime conflicts..."
            ;;
        show_unsynchronizable)
            echo "Listing files unable to synchronize due to $META_NAME not completed..."
            ;;
        complete)
            echo "Completing $META_NAME from local file mtime..."
            ;;
        synchronize)
            echo "Synchronizing local mtime from repository metadata..."
            ;;
        resolve)
            echo "Resolving mtime conflicts (use local file mtime)..."
            ;;
        *)
            echo "Invalid command $cmd"
            return 1
          ;;

    esac

    dirs=$(select_dirs "$@")

    while IFS= read -r dir
    do
        decode_from_inline "$dir"; dir="$DECODE_RESULT"

        ! app_is_update_to_date "$dir" && echo "The working copy '${dir:-.}' is not update to date." && return 1

#        if [ "$cmd" = 'complete' ] || [ "$cmd" = 'restore' ] || [ "$cmd" = 'resolve' ]; then

            if ! str=$(app_get_files_2_commit "$dir"); then
                echo "$str"
                return 1
            fi

            has_uncommitted=0
            [ -n "$str" ] && while read -r file
            do
                decode_from_inline "$file"; file="$DECODE_RESULT"
                if [ -e "$file" ]; then
                    echo "Uncommitted changes detected: $file"
                    has_uncommitted=1
                else
                    log "Not exists: $file"
                fi
            done << EOF
        $str
EOF

            if [ $has_uncommitted = 1 ]; then
                echo "Please commit your changes before running kmt $cmd"
                return 1
            fi
#        fi
    done << EOF
$dirs
EOF

    start=$(date +%s.%N)

    ! str=$(app_kmt_list "$@") && echo "$str" && echo "get kmt list failed" && return 1

    log "on scanned: $*"

    now_ts=$(date +%s)
    [ -n "$str" ] && while IFS="$SEP" read -r file file_mts file_cts prop_mts prop_cts last_cts l2nd_cts first_cts
    do
#        log "on file: $file"
        decode_from_inline "$file"
        defile="$DECODE_RESULT"
#        log "real file: $defile"
        ! on_file_scan "$defile" "$file_mts" "$file_cts" "$prop_mts" "$prop_cts" "$last_cts" "$l2nd_cts" "$first_cts" && return 1
    done << EOF
$str
EOF
    log "scanned result proceed: $*"

    end=$(date +%s.%N)
#    start=${start//0*$/}
#    end=${end//0*$/}
    start=$(echo "$start" | sed 's/0*$//')
    end=$(echo "$end" | sed 's/0*$//')
#    log "diff: $end - $start"
    duration=$(float_diff "$end" "$start")

    echo "Done."
    echo "Elapsed time(s): ${duration} by $SCAN_BACKEND"
    echo ""
    case "$cmd" in
     "scan")
        lc=${#checked_count}
        cat << EOF
Versioned files checked:  $checked_count
      Completed:          $(fix_len "$completed_count" "$lc")
      Completable:        $(fix_len "$completable_count" "$lc")
      Synchronizable:     $(fix_len "$synchronizable_count" "$lc")
      Conflicts:          $(fix_len "$conflict_count" "$lc")
      Unsynchronizable:   $(fix_len "$unsynchronizable_count" "$lc")

EOF
        ;;
    'complete')
        if [ "$effected_count" = 0 ]; then
            echo "No files completed"
        else
            ! app_on_kmt_completed "$effected_count" && return 1

            echo "Completed $effected_count files successfully."
            completed_count=$(( completed_count+effected_count ))
        fi
        ;;
    'synchronize')
        if [ "$effected_count" = 0 ]; then
            echo "No files synchronized"
        else
            echo "Synchronized $effected_count files successfully."
            completed_count=$(( completed_count+effected_count ))
        fi
        ;;
    'resolve')
        if [ "$effected_count" = 0 ]; then
            echo "No files resolved"
        else
            ! app_on_kmt_resolved "$effected_count" && return 1

            echo "Resolved $effected_count files successfully."
            completed_count=$(( completed_count+effected_count ))
        fi
        ;;
    'show_completed')
        echo "$completed_count completed files."
        ;;
    'show_completable')
        echo "$completable_count files completable."
        ;;
    'show_synchronizable')
        echo "$synchronizable_count files synchronizable."
        ;;
    'show_unsynchronizable')
        echo "$unsynchronizable_count unsynchronizable files."
        echo "
Unable to synchronize files:
  These files do not have $META_NAME metadata in the repository.
  This working copy is not eligible to complete them.
  They should be completed from a working copy that still contains
  the original file modification times.
  Once completed, they become synchronizable.
"
        ;;
    'show_conflict')
        echo "$conflict_count mtime conflicting files."
        ;;
    *)
        ;;

    esac

    return 0
}

kmt_ui()
{
    dirs=$(select_dirs "$@")

    dirs_inline=$(echo "$dirs" | tr '\n' ' ' | sed 's/[ \t]*$//')

    while true
    do
          [ -n "$checked_count" ] && files_count="[$checked_count files]" || files_count=

          if [ -z "$key" ]; then
              cat << EOF
Select an operation:

  -- Scan --

    1   -- Scan directories (${dirs_inline:-.}) $files_count

  -- Inspect --

    2   -- List mtime/btime completed files $completed_count
    3   -- List mtime/btime completable files $completable_count
    4   -- List mtime synchronizable files $synchronizable_count
    5   -- List files with mtime conflicts $conflict_count
    6   -- List mtime unsynchronizable files ($META_NAME not completed) $unsynchronizable_count

  -- Modify --

    7   -- Complete $META_NAME from local file mtime/btime $completable_count
    8   -- Synchronize local mtime from repository metadata $synchronizable_count
    9   -- Resolve mtime conflicts (use local file mtime) $conflict_count

  Other -- Exit

EOF
            read -r key
        fi

        case $key in

            1)
                cmd=scan    ;;

            2)
                cmd=show_completed  ;;

            3)
                cmd=show_completable ;;

            4)
                cmd=show_synchronizable ;;

            5)
                cmd=show_conflict ;;

            6)
                cmd=show_unsynchronizable ;;

            7)
                cmd=complete ;;

            8)
                cmd=synchronize ;;

            9)
                cmd=resolve ;;

            *)
                return 0 ;;

        esac

        echo ""

        ! kmt_foreach_file "$cmd" "$@" && return 1

        read -r key
    done

    return 0
}

##############################################################################
# Dispatcher
##############################################################################

dispatch()
{
    cmd="$1"

    if [ -n "$cmd" ]; then
        bn=$(basename "$0")
        if [ "$bn" = "$APP_KMT.sh" ]; then
            case $cmd in
                "kmt-install"|"install"|"kmt-upgrade"|"kmt-version")
                    #pass
                ;;
                *)
                    if ! $APP "kmt-version"; then
                        echo "The $KMT_FULL_NAME should be installed firstly,
        please run the command as follows to install it:
        ./$APP_KMT.sh kmt-install
        "
                    else
                        echo "The $APP commands should not be called startswith $APP_KMT.sh, but run as follows:
        $APP $*
        "
                    fi
                    return 1
                ;;
              esac
        else
            case $cmd in
                "kmt-install"|"install"|"kmt-upgrade")
                    echo "Please run the command as follows:
        ./$APP_KMT.sh $*
    "
                    return 1
                ;;
            esac
        fi
    fi

    case "$cmd" in

        kmt|kmt-ui|kmt-main)
            shift

            kmt_command_handler 'ui' "$@"

            ;;

        kmt-scan|kmt-complete|kmt-synchronize|kmt-sync|kmt-resolve)

            shift

            kmt_command_handler "${cmd#*-}" "$@"

            ;;

        kmt-version)

            show_version

            ;;

        kmt-install|install)

            shift

            kmt_install "$@"

            ;;

        kmt-uninstall)

            shift

            kmt_uninstall

            ;;

        kmt-upgrade)

            shift

            kmt_upgrade "$@"

            ;;

        *)

            app_command_handler "$@"

            ;;

    esac
}

##############################################################################
# Main
##############################################################################

main()
{
    case "$1" in
        "--kmt-debug-log"*)
            set_debug_log "$(select_arg "--kmt-debug-log" "$@")"
            shift
        ;;
    esac

    ! detect_platform ||
    ! detect_time_zone ||
    ! detect_original_app ||
    ! detect_conf ||
    ! auto_set_kmt_scan_backend && return 1

    dispatch "$@"
#    log "ret: $?"
#    return $?
}


# ---------------------------------------------------------------------------
# Commits helpers
# ---------------------------------------------------------------------------

git_rev_parse()
{
    origin_git rev-parse --verify "$1" 2>/dev/null
}

git_is_head()
{
    commit=${1}
    [ -z "$commit" ] && return 1

    [ "$(git_rev_parse "$commit")" = "$(git_current_head)" ]
}

git_current_head()
{
    git_rev_parse HEAD
    ret=$?
    if [ "$ret" != 0 ]; then
        commits_count=$(git_prev_commits 2> /dev/null | grep -c "") || [ "$commits_count" -eq "0" ] && return 0
    fi

    return $ret
}

git_prev_commit()
{
    commit=${1:-HEAD}
    git_rev_parse "$commit~1"
    ret=$?
    if [ "$ret" != 0 ]; then
        commits_count=$(git_prev_commits "$commit" 2>/dev/null | grep -c "") && [ "$commits_count" -eq "1" ] && return 0
    fi

    return $ret
}

git_prev_commits()
{
    if [ -z "$1" ]; then
        origin_git log --pretty=format:"%H,%ct"
    else
        origin_git log --pretty=format:"%H,%ct" "$1"
    fi
}

git_commit_time()
{
    origin_git show -s --format='%ct' "${1:-HEAD}"
}

git_last_commit_of_file()
{
    path="$1"
    to_commit="${2:-HEAD}"

    decode_from_inline "$path"; path="$DECODE_RESULT"

    origin_git log -1 "$to_commit" --format='%H' -- "$path"
}

git_status_files()
{
#    origin_git status --short -z "$@" | tr '\0' '\n'
    origin_git status --short --untracked-files=no -z | pipe_inline_encode | tr '\0' '\n'
}

#git_diff_staged_files()
#{
##    origin_git status --short -z "$@" | tr '\0' '\n'
#    origin_git diff --name-status --staged -z "$@" | pipe_inline_encode | tr '\0' '\n'
#}

git_diff_commit_files()
{
    commit=${1:-HEAD}

#    it should add param --root, or for the first commit, diff-tree will return empty.
#    and should add commit~1, or the merged files will be ignored to a merged commit

#    origin_git diff-tree --root --no-commit-id --no-renames --name-status -r "$commit" -z | xargs -0 -n 2 printf "%s$ETX%s\n"

    origin_git diff-tree --root -m --no-commit-id --no-renames --name-status -r "$commit~1" "$commit" -z |
        pipe_inline_encode |
        xargs -0 -n 2 printf "%s$ETX%s\n"
}

complete_directory()
{
    awk -v RS="$EOT" '
    function dirname(path) {
        sub(/\/+$/, "", path)
        if (path !~ /\//) return "."
        sub(/\/[^\/]*$/, "", path)
        if (path == "") path = "/"
        return path
    }
    {
        line=$0
        dir=dirname($0)
        if(!dirs[dir]){
            dirs[dir]=1
            printf "%s%c", dir, 0
        }
        printf "%s%c", line, 0
    }'
}

preview_fs_mtime()
{
    commit=${1:-HEAD}
    path=${2:-${SUB_DIR:-${REPO_ROOT}}}

    origin_git ls-tree -r --full-tree --name-only "$commit" -z -- "$path" |
#        tr '\0' "$EOT" | complete_directory | tr "$EOT" '\0' |
        tr '\0' "$EOT" | complete_directory |
        batch_stat_mc |
        index_encode_inline
}

# Output: <STX>path<ETX>commit<ETX>commit_ts
# for every still-existing file, using its most recent A/M commit.
git_last_commit_of_files()
{
    commit="${1:-HEAD}"
    path_filter=
    [ -n "$2" ] && path_filter="-- $2"
    origin_git log --pretty=format:"%H,%ct" --diff-merges=first-parent --name-status --no-renames -z "$commit" $path_filter |
        tr '\0' "$EOT" |
        awk -F, -v RS="$EOT" -v OFS="$ETX" -v stx="$STX" -v elf="$ELF" '
            BEGIN {commit=""}
            /^[0-9a-f]{40,},[0-9]+/ {
                split($0, arr, "\n")
                if(arr[2]!=""){
                    split(arr[1], arr2, ",")
                    commit=arr2[1];
                    ct=arr2[2];
                    status=arr[2]
                }
                else{
                    commit=""
                    ct=""
                    status=""
                }
                next
            }
            status=="" {
                status = $0
                next
            }
            {
                line = $0
                if(line == ""){
                    commit=""
                    ct=""
                    next
                }

                gsub("\n",elf,line)

                if (!complete[line]) {
                    complete[line] = 1
                    if(status != "D"){
                        print stx line,commit,ct
                    }
                }
                status = ""
            }
        '
    return $?
}

# Output: <STX>path<ETX>last_commit<ETX>last_commit_ts<ETX>l2nd_commit_ts<ETX>first_commit
# for every still-existing file, select its most recent 2 A/M commits and first_commit.
git_3_commits_of_files()
{
    commit="${1:-HEAD}"
    path_filter=
    [ -n "$2" ] && path_filter="-- $2"

    origin_git log --pretty=format:"%H,%ct" --diff-merges=first-parent --name-status --no-renames -z "$commit" $path_filter |
        tr '\0' "$EOT" |
        awk -F, -v RS="$EOT" -v OFS="$ETX" -v stx="$STX" -v elf="$ELF" '
            function dirname(path) {
                sub(/\/+$/, "", path)
                if (path !~ /\//) return "."
                sub(/\/[^\/]*$/, "", path)
                if (path == "") path = "/"
                return path
            }
            function on_complete(file, commit, commit_ts, status){
                path=dirname(file)

                if(status=="A"){
                    dir_not_empty[path]=1
                    dir_create_commit[path]=commit
                    dir_create_commit_ts[path]=commit_ts
                }

                if(!dir_last_commit[path]){
                    dir_last_commit[path]=commit
                    dir_last_commit_ts[path]=commit_ts
                }

#                if(!complete[path]){
#                    print stx path, commit, commit_ts, "", commit_ts, commit
#                    complete[path]=1
#                }
            }
            BEGIN {commit=""}
            /^[0-9a-f]{40,},[0-9]+/ {
                split($0, arr, "\n")
                if(arr[2]!=""){
                    split(arr[1], arr2, ",")
                    commit=arr2[1];
                    ct=arr2[2];
                    status=arr[2]
                }
                else{
                    commit=""
                    ct=""
                    status=""
                }
                next
            }
            status=="" {
                status = $0
                next
            }
            {
                line = $0
                if(line == ""){
                #end of a commit log
                    commit=""
                    ct=""
                    next
                }

                gsub("\n",elf,line)

                if(!complete[line]){
                    if(last_2nd_commit_time[line]){
                        if(status == "D"){
##                           all files should have a "A" record, this case should never happened, or data error.
                            print stx line, last_commit[line], last_commit_ts[line], last_2nd_commit_time[line], "", ""
                            complete[line] = 1
                            on_complete(line, commit, ct, status)
                        }
                        else if(status == "A"){
                            print stx line, last_commit[line], last_commit_ts[line], last_2nd_commit_time[line], ct, commit
                            complete[line] = 1
                            on_complete(line, commit, ct, status)
                        }
                    }
                    else if(last_commit[line]){
#                        complete[line] = 1
#                        if(ct > last_commit_ts[line]){
#                            print line, "ERROR COMMIT TIME: last_commit[line]", last_commit_ts[line], ct, commit
#                            exit 1
#                            next
#                        }

                        if(status == "D"){
##                           all files should have a "A" record, this case should never happened, or data error.
                            print stx line, last_commit[line], last_commit_ts[line], "", "", ""
                            complete[line] = 1
                            on_complete(line, commit, ct, status)
                        }
                        else if(status=="A"){
                            print stx line, last_commit[line], last_commit_ts[line], ct, ct, commit
                            complete[line] = 1
                            on_complete(line, commit, ct, status)
                        }
                        else{
                            last_2nd_commit_time[line]=ct
                        }
                    }
                    else{
                        last_commit[line] = commit
                        last_commit_ts[line] = ct

                        if(status == "D"){
                            complete[line] = 1
                            on_complete(line, commit, ct, status)
                        }
                        else if (status == "A"){
                            print stx line, commit, ct, "", ct, commit
                            complete[line] = 1
                            on_complete(line, commit, ct, status)
                        }
                    }
                }
                status = ""
            }
            END {
                for (i in last_commit) {
                    if(complete[i]){
                        continue
                    }

##                  all files should have a "A" record, this case should never happened, or data error.
                    print stx i, last_commit[i], last_commit_ts[i], last_2nd_commit_time[i], "", ""
#                    on_complete(complete[i])
                }

                for (dir in dir_last_commit) {
                    if(dir_not_empty[dir]){
                        print stx dir, dir_last_commit[dir], dir_last_commit_ts[dir], "", dir_create_commit_ts[dir], dir_create_commit[dir]
                    }
                }
            }
        '
#    return $?
}


# ---------------------------------------------------------------------------
# Note helpers
# ---------------------------------------------------------------------------

# git_note_add <commit> <file>
#   Replace the entire note of <commit> with the contents of <file>.
git_note_add()
{
    origin_git notes --ref="$NOTE_REF" add -f -F "$2" "$1"
}

# git_note_show <commit>
#   Print the whole note for a commit. Returns non-zero if no note.
git_note_show()
{
    origin_git notes --ref="$NOTE_REF" show "$1" 2>/dev/null
}

git_note_oid()
{
    origin_git notes --ref="$NOTE_REF" list "$1"
}

git_note_copy()
{
    origin_git notes --ref="$NOTE_REF" copy "$1" "$2"
}

# Look up the mtime of a file from a specific commit's note.
# If commit not specified, find the file's last commit first.
git_note_mtime()
{
    rpath=$1
    commit=$2

    [ -z "$commit" ] && commit=$(git_last_commit_of_file "${rpath#*"${SUB_DIR}"}" "$commit")

    ! line=$(git_note_show "$commit" | grep -m 1 -F "$STX$rpath$ETX") && return 1

    val=${line#*"$ETX"}
    MTIME_RESULT="${val%%"$ETX"*}"

    val=${val#*"$ETX"}
    BTIME_RESULT="${val%%"$ETX"*}"

    return 0
}

note_show_history()
{
    commit=${1:-HEAD}
    path=$2

    [ -z "$path" ] && echo "history requires a file path" && return 1

    # if you want to track the rename history, add --follow and --name-staus to git log
    # read out the origin name when renamed, use origin name to show history mtimes
    # THIS has not implemented yet.

    ! prev_commits=$(origin_git log --format='%H,%cI' "$commit" -- "$path") && return 1

    encode_into_inline "$path" && path="$ENCODE_RESULT"

    [ -z "$prev_commits" ] && echo "no history: '$path'" && return 0

    echo "$prev_commits" |
        while IFS="," read -r commit date; do
            git_note_mtime "$SUB_DIR$path" "$commit" && note_ts="$MTIME_RESULT"
            if [ -n "$note_ts" ]; then
                printf '%s | %s | %s | %s\n' "$commit" "$date" "$note_ts" "$(format_timestamp "$note_ts")"
            else
                printf '%s | %s | %10s | %s\n' "$commit" "$date" "$note_ts" "$(format_timestamp "")"
            fi
        done
}


# ---------------------------------------------------------------------------
# Local note management
# ---------------------------------------------------------------------------

pipe_inline_decode()
{
    tr "$ELF" '\n'
}

pipe_inline_encode()
{
    tr '\n' "$ELF"
}

index_encode_inline()
{
    awk -v elf="$ELF" -v etx="$ETX" 'NF{printf "%s%s", $0, (index($0, etx) > 0)?"\n":elf}'
}

index_file_encode_inline()
{
    file="$1"
    ! cat < "$file" | index_encode_inline > "$file.$$" && return 1

    ts=$(get_file_mtime "$file")
    set_file_mtime "$file.$$" "$ts" || return 1
    mv -f "$file.$$" "$file" || return 1

    return 0
}

escaped_file_exists()
{
    path_to_check="$1"
    decode_from_inline "$path_to_check"; path_to_check="$DECODE_RESULT"

#    real_file=$(printf "%s" "$1" | inline_decode )
    if [ -e "$path_to_check" ]; then
#        log "exists: $1"
        return 0
    else
        log "not exists: $1, $path_to_check"
        return 1
    fi
}

index_get_file()
{
    commit=$1
    cate=$2

    if [ ! -e "$GIT_DIR/kmt/" ]; then
        ! mkdir -p "$GIT_DIR/kmt/" && echo "mk kmt dir failed" && return 1
    fi

    echo "$GIT_DIR/kmt/$commit.$cate.idx"

    return 0
}

FOUND_LINE=
index_find_line()
{
    key="$1"
    index_file="$2"

    [ ! -f "$index_file" ] && return 1

    if [ "$IS_LOOK_INSTALLED" = "1" ]; then
        line=$(look -t "$ETX" "$key$ETX" "$index_file") || return 1
    else
        line=$(grep -m 1 -F "$key$ETX" "$index_file") || return 1
    fi

    FOUND_LINE="$line"
}

index_item_value_in_line()
{
    line="$1"
    idx_base_0="$2"

    __i=0
    INDEX_VALUE=
    while true
    do
        value="${line%%"$ETX"*}"

        if [ "$__i" = "$idx_base_0" ]; then
            INDEX_VALUE="$value"
            return 0
        fi

        if [ "$value" = "$line" ]; then
            return 1
        fi

        line=${line#*"$ETX"}
        __i=$((__i+1))

    done
}

index_select_item_value()
{
    item_id="$1"
    idx_file="$2"
    select_key="$3"

    index_find_line "$select_key" "$idx_file" || return 1

    index_item_value_in_line "$item_id" "$FOUND_LINE" || return 1

    return 1
}

index_get_file_mtime()
{
    index_find_line "$1" "$2" || return 1

    val=${FOUND_LINE#*"$ETX"}
    MTIME_RESULT="${val%%"$ETX"*}"

    next_value=${val#*"$ETX"}

    [ "$val" = "$next_value" ] && BTIME_RESULT="" || BTIME_RESULT="${next_value%%"$ETX"*}"

#    log "line: $FOUND_LINE, $MTIME_RESULT, $BTIME_RESULT"

    return 0
}

index_is_valid()
{
    case "$1" in
        delta|stage)
            if [ -z "$2" ]; then
                ! grep -Ev "^${STX}.*${ETX}(D|[0-9]+)${ETX}([0-9]*)$"
            else
                ! grep -Ev "^${STX}.*${ETX}(D|[0-9]+)${ETX}([0-9]*)$" "$2"
            fi
            ;;
        full)
            if [ -z "$2" ]; then
                ! grep -Ev "^${STX}.*${ETX}[0-9]*${ETX}([0-9]*)${ETX}[0-9a-f]{40,}${ETX}[0-9]+${ETX}[0-9]*${ETX}[0-9]*$"
            else
                ! grep -Ev "^${STX}.*${ETX}[0-9]*${ETX}([0-9]*)${ETX}[0-9a-f]{40,}${ETX}[0-9]+${ETX}[0-9]*${ETX}[0-9]*$" "$2"
            fi
            ;;
    esac
}

select_modified_directories()
{
    while IFS= read -r line
    do
        staged_flag=$(print_n "$line"| cut -c 1-1)
        case "$staged_flag" in
            A|D)
                file=$(print_n "$line" | cut -c 4- )
                dir=$(dirname "$file")

                [ -e "$dir" ] && print_n "$dir"
                ;;
        esac
    done | awk '(exists[$0]==""){printf "%s%c", $0, 0; exists[$0]=1; }'
}

select_diff_directories()
{
    while IFS="$ETX" read -r status rfile
    do
        case "$status" in
            A|D)
                dir=$(dirname "$rfile")

                [ -e "$dir" ] && print_n "$dir"
                ;;
        esac
    done | awk '(exists[$0]==""){printf "%s%c", $0, 0; exists[$0]=1; }'
}

select_stage_files()
{
    newly_added_files="$1"
    status_filter="$2"
    head_commit="$3"

    stage_file=$(index_get_file "$head_commit" "stage")
    stage_file_temp="$stage_file.$$"

    while IFS= read -r line
    do
        staged_flag=$(print_n "$line"| cut -c 1-1)

        [ -n "$status_filter" ] && [ "$staged_flag" != "$status_filter" ] && continue

        file=$(print_n "$line" | cut -c 4- )

        case "$staged_flag" in
            D)
                log "DELETE: $line"
                print_n "$STX$file${ETX}D${ETX}" >> "$stage_file_temp"
                ;;
            *)
                if [ -f "$stage_file" ] && index_get_file_mtime "$STX$file" "$stage_file"; then
                    if [ -n "$newly_added_files" ] && print_n "$newly_added_files" | grep -Fxq "$file"; then
                        log "RENEW: $line"
                        printf "%s\0" "$file"
                    else
                        log "REMAIN: $line, $MTIME_RESULT"
                        print_n "$STX$file${ETX}$MTIME_RESULT${ETX}$BTIME_RESULT" >> "$stage_file_temp"
                    fi
                else
                    log "ADD: $line"
                    printf "%s\0" "$file"
                fi
                ;;
        esac
    done

    return 0
}

refresh_stage_note()
{
    working_files_before=$1
    stage_file_temp=$2

    status_files=$(git_status_files | grep '^[AMD].')

    # The newly added files may be generated by the git add rm or rename,
    # the mtimes of them should be refreshed by stat(ed) values
    newly_added_files=
    if [ -n "$working_files_before" ]; then
        newly_added_files=$(print_n "$status_files" | grep '^[^ ] ' | cut -c 4- |
            while read -r staged_file
            do
                print_n "$working_files_before" | grep -Fx "$staged_file"
            done)
        log "newly_added_files: $newly_added_files"
    fi

    ! head_commit=$(git_current_head) && echo "no current head" && return 1

    stage_file=$(index_get_file "$head_commit" "stage")

    stage_file_temp="$stage_file.$$"

    [ -f "$stage_file_temp" ] && rm -f "$stage_file_temp"

    if [ -n "$status_files" ]; then
        print_n "$status_files" | select_stage_files "$newly_added_files" "A" "$head_commit" | pipe_inline_decode | batch_stat_mc >> "$stage_file_temp"
        print_n "$status_files" | select_stage_files "$newly_added_files" "M"  "$head_commit"| pipe_inline_decode | batch_stat_mc >> "$stage_file_temp"
        print_n "$status_files" | select_stage_files "$newly_added_files" "D"  "$head_commit"

        print_n "$status_files" | select_modified_directories | pipe_inline_decode | batch_stat_mc>> "$stage_file_temp" || return 1

        ! index_file_encode_inline "$stage_file_temp" && return 1

        if [ -s "$stage_file_temp" ]; then
            cat < "$stage_file_temp" | LC_ALL=C sort > "$stage_file"

            last_ts=$(awk -F"$ETX" 'BEGIN {max = 0} $2!="D" && $2 > max {max = $2} END {print max}' "$stage_file")

            ! set_file_mtime "$stage_file" "$last_ts" && return 1

            ! rm -f "$stage_file_temp" && return 1

            ! index_is_valid "stage" "$stage_file" && echo "invalid content in stage file: $stage_file" && return 1
        else
            mv -f "$stage_file_temp" "$stage_file"
        fi

    else
        [ -f "$stage_file" ] && rm -f "$stage_file"
        touch "$stage_file"
    fi

    log "refresh_stage_note ok"

    return 0
}

# all diff-tree files should included in the commit note, fill with empty if the real mtime is unknown,
# or the commit note would be incomplete, and the full note merged by commit notes would be incorrect

prepare_status_files()
{
    while IFS="$ETX" read -r status rfile
    do
        if [ "$status" = "D" ]; then
            printf "%sD%s\n" "$STX$rfile$ETX" "$ETX"
            continue
        fi

        if ! escaped_file_exists "$REPO_ROOT/$rfile"; then
            printf "%s\n" "$STX$rfile$ETX$ETX"
            continue
        fi

        [ "$status" = "$1" ] && printf "%s\0" "$rfile"

    done
}

prebuild_commit_note()
{
    commit=${1:-HEAD}

    # Step 1 --- pick up the diff-files
    ! commit_files=$(git_diff_commit_files "$commit") && echo "diff-tree failed" && return 1

    if [ -z "$commit_files" ]; then
        log "no committed diff files: $commit"
        return 0
    fi

    # Step 2 --- print out empty meta-data for the deleted or not exists diff-files
    print_n "$commit_files" | prepare_status_files "D"

    # Step 3 --- stat the mtime/btime for exists diff-files
    if ! added_files=$(print_n "$commit_files" | prepare_status_files "A" | pipe_inline_decode | batch_stat_mc | index_encode_inline); then
        echo "stat failed: $added_files"
        return 1
    fi

    if ! modified_files=$(print_n "$commit_files" | prepare_status_files "M" | pipe_inline_decode | batch_stat_mc | index_encode_inline); then
        echo "stat failed: $modified_files"
        return 1
    fi

    if ! modified_dirs=$(print_n "$commit_files" | select_diff_directories | pipe_inline_decode | batch_stat_mc | index_encode_inline); then
        echo "stat failed: $modified_dirs"
        return 1
    fi

    log "commit_files: $commit_files, modified_dirs: $modified_dirs"

    # Step 4 --- print out the mtime/btime meta-data with the stated timestamps
    if [ -n "$added_files" ] || [ -n "$modified_files" ] || [ -n "$modified_dirs" ]; then
        ! commit_ts=$(git_commit_time "$commit") && echo "get commit time failed" && return 1

        #if fs-mtime/btime greater than commit-time, means the real mtime/btime is missing, keep them empty
        print_n "$added_files" | exclude_status_files "1" |
            awk -F"$ETX" -v OFS="$ETX" -v cts="$commit_ts" '{print $1, ($2>cts)?"":$2, ($3>cts)?"":$3}'
        print_n "$modified_files" | exclude_status_files "1" |
            awk -F"$ETX" -v OFS="$ETX" -v cts="$commit_ts" '{print $1, ($2>cts)?"":$2, ($3>cts)?"":$3}'
        print_n "$modified_dirs" |
            awk -F"$ETX" -v OFS="$ETX" -v cts="$commit_ts" '{print $1, ($2>cts)?"":$2, ($3>cts)?"":$3}'
    fi

    return 0
}

reverse_before_key() {
    print_n "$1" | awk -v k="$2" -F, '
        BEGIN{n=0}
        k!="" && $1==k {found=1; next}
        !found{a[++n]=$0}
        END{for(i=n;i>=1;i--) print a[i]}
    '
}

index_merge_with_delta()
{
    main_note=$1
    delta=$2
    commit_id=$3
    commit_ts=$4

    print_n "$delta" | LC_ALL=C join -t "$ETX" -a1 -a2 -e '' -o 1.1,1.2,1.3,1.4,1.5,1.6,1.7,2.1,2.2,2.3 "$main_note" - |
        awk -F"$ETX" -v OFS="$ETX" -v ci="$commit_id" -v ct="$commit_ts" '
        {
            if($8 == ""){
                print $1,$2,$3,$4,$5,$6,$7
            }
            else if($1 == ""){
                print $8,$9,$10,ci,ct,"",ct
            }
            else if($9 != "D"){
                print $8,$9,($3!="")?$3:$10,ci,ct,$5,$7
            }
        }
        '
}

update_note_time_table()
{
    type="$1"
    doing_commit=
    cache_file=
    pid="$$"

    while IFS="$ETX" read -r sfile note_mtime note_btime last_commit last_commit_ts l2nd_commit_ts first_commit_dt first_commit
        do
            [ "$STX" = "$sfile" ] && continue

            if [ "$type" = 1 ]; then
                commit_key="$last_commit"
            else
                commit_key="$first_commit"
            fi

            if [ -n "$commit_key" ]; then
                if [ "$doing_commit" != "$commit_key" ]; then
                    [ -f "$cache_file" ] && ! rm -f "$cache_file" && return 1
                    doing_commit="$commit_key"

                    #going into next commit(files group)
                    cache_file="$(index_get_file "$doing_commit" "delta").$pid"
                    if ! git_note_show "$doing_commit" > "$cache_file"; then
                        rm -f "$cache_file" || return 1
                        cache_file=
                        log "commit has no note, commit-key: $commit_key, file:'$sfile', last_commit_ts: $last_commit_ts, l2nd_ts: $l2nd_commit_ts"
                    fi
                fi

                if [ -f "$cache_file" ]; then
                    if ! index_get_file_mtime "$sfile" "$cache_file"; then
                        log "file missing in note, type: $type, file: '$sfile', note-file: $cache_file"
#                        cat "$cache_file"
#                        return 1
                    else
                        [ "$type" = 1 ] && note_mtime="$MTIME_RESULT" || note_btime="$BTIME_RESULT"
                    fi
                fi
            fi

            print_n "${sfile}$ETX${note_mtime}$ETX${note_btime}$ETX${last_commit}$ETX${last_commit_ts}$ETX${l2nd_commit_ts}$ETX${first_commit_dt}$ETX${first_commit}"

        done

    [ -n "$cache_file" ] && ! rm -f "$cache_file" && return 1

    return 0
}

prebuild_full_note_file_by_file()
{
    tbl_file_commit="$1"

    ! str=$(print_n "$tbl_file_commit" | awk -F"$ETX" -v OFS="$ETX" '{print $1,"","",$2,$3,$4,$5,$6}' |
        sort -t "$ETX" -k4 | update_note_time_table "1") && echo "$str" && return 1

    ! str=$(print_n "$str" | sort -t "$ETX" -k7 | update_note_time_table "2") && echo "$str" && return 1

    print_n "$str" | awk -F"$ETX" -v OFS="$ETX" '{print $1,$2,$3,$4,$5,$6,$7}' || return 1

}

prebuild_full_note_commit_by_commit()
{
    commit="$1"
    commits_to_merge="$2"
    latest_full_note="$3"

    full_note_merging="$(index_get_file "$commit" "merging").$$"

    if [ -n "$latest_full_note" ]; then
        cp "$latest_full_note" "$full_note_merging"
    else
        printf "" > "$full_note_merging"
    fi

    [ -n "$commits_to_merge" ] && while IFS=, read -r next_commit next_commit_ts
        do
#            log "merge $next_commit ..."
            if ! delta=$(git_note_show "$next_commit"); then
                log "no commit note ... $next_commit"
                delta=$(git_diff_commit_files "$next_commit" |
                    awk -F"$ETX" -v OFS="$ETX" -v stx="$STX" '{print stx $2,($1=="D")?"D":"",""}')
            fi

            if ! str=$(index_merge_with_delta "$full_note_merging" "$delta" "$next_commit" "$next_commit_ts"); then
                log "merge failed: $str"
                rm -f "$full_note_merging"
                return 1
            fi

            print_n "$str" > "$full_note_merging"

        done << EOF
$commits_to_merge
EOF

    cat "$full_note_merging" && rm -f "$full_note_merging"

    return 0
}

prebuild_full_index()
{
    commit=$(git_rev_parse "${1:-HEAD}") || return 1

    ! prev_commits=$(git_prev_commits "$commit") && return 1

    [ -z "$prev_commits" ] && return 1

    latest_full_note=
    commits_to_merge=

    #find the latest full note to the commit
    while IFS="," read -r prev_commit _
        do
            #skip the current commit, even it has a full note
            [ "$prev_commit" = "$commit" ] && continue

            full_note_file=$(index_get_file "$prev_commit" "full")
            if [ -f "$full_note_file" ]; then
                latest_full_note="$full_note_file"
                commits_to_merge=$(reverse_before_key "$prev_commits" "$prev_commit")

                [ -z "$commits_to_merge" ] && echo "invalid commits list $prev_commits" && return 1
                break
            fi
        done << EOF
$prev_commits
EOF

    if [ -z "$commits_to_merge" ]; then
        commits_to_merge=$(reverse_before_key "$prev_commits")
    fi

    commits_count=$(print_n "$commits_to_merge"| grep -c "")

    ! all_files=$(git_3_commits_of_files "$commit") && print_n "$all_files" && return 1

    files_count=$(print_n "$all_files"| grep -c "")

    if [ "$files_count" -lt $((commits_count * 10)) ]; then
        log "prebuild by $files_count files, for $commit ..."
        ! prebuild_full_note_file_by_file "$all_files" && return 1
    else
        log "prebuild by $commits_count commits based on $latest_full_note, for $commit ..."

        ! prebuild_full_note_commit_by_commit "$commit" "$commits_to_merge" "$latest_full_note" && return 1
    fi

    log "prebuild full note ok $commit"

    return 0
}

refresh_later_full_notes()
{
    commit_id="$1"

    if [ ! -e "$GIT_DIR/kmt/" ]; then
        return 0
    fi

    delta_note=$(git_note_show "$commit_id")

    log "update all exists full note with commit note, $commit_id"

    for idx_file in "$GIT_DIR"/kmt/*.full.idx
    do
        [ -f "$idx_file" ] || continue

        if ! grep -m 1 -F "$ETX$commit_id$ETX" "$idx_file"; then
#            log "skip $file"
            continue
        fi

        ! print_n "$delta_note" | LC_ALL=C join -t "$ETX" -a1 -o 1.1,1.2,1.3,1.4,1.5,1.6,1.7,2.1,2.2,2.3 "$idx_file" - |
            awk -F"$ETX" -v OFS="$ETX" -v ci="$commit_id" '{print $1,($4==ci)?$9:$2,($3=="")?$10:$3,$4,$5,$6,$7}' > "$idx_file.new.$$" &&
            return 1

        full_note_file_ts=$(get_file_mtime "$idx_file") || return 1
        ! set_file_mtime "$idx_file.new.$$" "$full_note_file_ts" && return 1

        ! mv "$idx_file.new.$$" "$idx_file" && return 1

        log "update full note ok: $idx_file"

    done

    return 0
}

rebuild_commit_note()
{
    commit=${1:-HEAD}

#    if git_is_head "$commit"; then
#        ! post_commit && echo "post commit failed" && return 1
#        log "post commit ok $commit"
#        return 0
#    fi

    if ! note=$(prebuild_commit_note "$commit"); then
        echo "$note"
        echo "build note failed"
        return 1
    fi

    ! note_file=$(mktemp "${TMPDIR:-/tmp/}git-kmt-note.$$") && echo "mktemp failed" && return 1

    print_n "$note" | LC_ALL=C sort > "$note_file"

    ! index_is_valid "delta" "$note_file" && echo "invalid content in note file: $note_file" && return 1

    if git_is_head "$commit"; then
        ! post_commit "$note_file" && echo "post commit failed" && return 1

        rm -f "$note_file"

        log "post commit ok $commit"
    else
        if ! git_note_add "$commit" "$note_file"; then
            echo "add note failed: $commit, $note_file"
            rm -f "$note_file"
            return 1
        fi

        echo "note_add_file ok"

        rm -f "$note_file"

        ! refresh_later_full_notes "$commit" && echo "Failed to refresh later full notes" && return 1
    fi

    echo "refresh_later_full_notes ok"

    return 0
}

rebuild_full_index()
{
    commit="${1:-HEAD}"

    full_index_file=$(index_get_file "$commit" "full")

    ! str=$(prebuild_full_index "$commit") && echo "$str" && echo "prebuild full index failed" && return 1

    print_n "$str" | LC_ALL=C sort > "$full_index_file.temp.$$"

    ! index_is_valid "full" "$full_index_file.temp.$$" && echo "invalid content in index file: $full_index_file.temp.$$" && return 1

    ! mv "$full_index_file.temp.$$" "$full_index_file" && return 1

    ! commit_ts=$(git_commit_time "$commit") && return 1

    ! set_file_mtime "$full_index_file" "$commit_ts" && return 1

    return 0
}

index_show()
{
    cate=$1
    commit=$2
    [ -z "$commit" ] && return 1

    note_file=$(index_get_file "$commit" "$cate")
    if [ ! -f "$note_file" ]; then
        echo "$cate-index not exists" >&2
        return 1
    fi

    cat "$note_file"
    return 0
}

verify_or_amend_commit_note()
{
    #the hooks may change the commit files, diff the note, amend it if invalidate

    old_stage_note_file="$1"

    note_str=$(prebuild_commit_note | LC_ALL=C sort)

    diff=$(print_n "$note_str" | LC_ALL=C join -t "$ETX" -a1 -a2 -e '' -o 1.1,1.2,2.1,2.2 "$old_stage_note_file" - |
                awk -F"$ETX" -v OFS="$ETX" '{
                    # $4 is empty means the file is in working
                    if($1=="" || $3=="" || ($2!=$4 && $4!="")){
                        print $1, $2, $3, $4
                    }
                }') || return 1

    [ -z "$diff" ] && return 0

    log "diff: $diff"
    #amend it

    head_commit=$(git_current_head)

    commit_note=$(index_get_file "delta" "$head_commit")

    print_n "$note_str" > "$commit_note"

    [ -s "$commit_note" ] && kmt_note_oid=$(origin_git hash-object "$commit_note") || kmt_note_oid=

    log "amend trailer: $kmt_note_oid, commit: $head_commit"

    ! origin_git commit --amend --trailer "kmt-note-oid: $kmt_note_oid" --allow-empty --no-edit && return 1

    ! post_commit "$commit_note" && return 1

    [ -s "$commit_note" ] && [ "$(git_note_oid "HEAD")" != "$kmt_note_oid" ] && echo "NOTE-OID Check Failed" && return 1

    [ -f "$commit_note" ] && rm -f "$commit_note"

    return 2
}


show_help()
{
    cat <<EOF2
Git Keep MTime

Normal Git commands are forwarded to the original Git executable.

KMT commands:
  kmt-install [script]       install wrapper (must be invoked as: git_kmt.sh kmt-install)
  kmt-uninstall              uninstall wrapper
  kmt-upgrade [script]       uninstall then install wrapper (must be invoked as: git_kmt.sh kmt-upgrade)
  kmt-version                show version
  kmt-note [commit]          show timestamp note
  kmt-history <path>         show file mtime history

Intercepted Git commands:
  add
  commit
  merge
  restore
  revert
  reset
  rebase
  switch
  checkout
  clone
  pull
  push

Notes contain only:
  file${ETX}mtime
EOF2
}

# ---------------------------------------------------------------------------
# Git command wrapper
# ---------------------------------------------------------------------------

origin_git()
{
    log_ret=0
    "$ORIGIN_APP" "$@" || log "ret: $?, params: '$*'"
    return "$log_ret"
}

git_repo_root()
{
    origin_git rev-parse --show-toplevel 2>/dev/null
}

git_repo_dir()
{
    origin_git rev-parse --git-dir 2>/dev/null
}

python_batch_stat()
{
    with_btime="$1"

    cmd=$(find_command "python3") || cmd=$(find_command "python")
    main_code='
import os, sys
inp = getattr(sys.stdin, "buffer", sys.stdin)
out = getattr(sys.stdout, "buffer", sys.stdout)
data = inp.read()
STX = b"\x02" if isinstance(data, bytes) else "\x02"
ETX = b"\x03" if isinstance(data, bytes) else "\x03"
NUL = b"\0" if isinstance(data, bytes) else "\0"
NL  = b"\n" if isinstance(data, bytes) else "\n"
for n in [x for x in data.split(NUL) if x]:
    try:
        stt=os.stat(n)
        mts = int(stt.st_mtime)
        bts = int(stt.st_birthtime)
    except Exception as x:
        sys.stderr.write("%r: %s\n" % (n, x))
        continue
    out.write(STX + n + ETX + (str(mts).encode() if isinstance(n, bytes) else str(mts)) + \
                        ETX + (str(bts).encode() if isinstance(n, bytes) else str(bts)) + NL)
'

    $cmd -c "$main_code"

#    [ "$with_btime" = 1 ] &&
#        ext_data="ETX + (str(bts).encode() if isinstance(n, bytes) else str(bts)) + NL)" ||
#        ext_data="NL)"
#
#    $cmd -c "$main_code $ext_data"
}

batch_stat_mc()
{
#    with_empty_btime="$1"
    cd "$REPO_ROOT" || return 1

    if [ "$SCAN_BACKEND" = 'python' ]; then
        python_batch_stat "$with_btime"
    else
        if [ "$PLATFORM" = 'linux' ]; then
#            [ "$with_empty_btime" = 1 ] && ext_data="" || ext_data="%W"
            xargs -0 -L 100 stat -c "$STX%n$ETX%Y$ETX%W"
        else
#            [ "$with_empty_btime" = 1 ] && ext_data="" || ext_data="%B"
            xargs -0 -L 100 stat -f "$STX%N$ETX%m$ETX%B"
        fi
    fi
}

synchronize_file()
{
    rpath=$1
    ts=$2
    file_ts=$3

    path="$REPO_ROOT/$rpath"

    decode_from_inline "$path"; path="$DECODE_RESULT"

    if [ -z "$file_ts" ]; then
        if [ ! -e "$path" ]; then
            ls -l "$path"
            log "Path not exists: $path"
            return 1
        fi
        ! file_ts=$(get_file_mtime "$path") && log "get_file_mtime failed: $path" && return 1
        [ "$file_ts" = "$ts" ] && log "same time: $file_ts, $ts" && return 0
    fi

    ! set_file_mtime "$path" "$ts" && log "failed to synchronize mtime '$path'" && return 1

    fast_format_timestamp "$ts"
    log "Synchronized mtime ok $FORMAT_RESULT, '$rpath', $ts"

    return 0
}

exclude_status_files()
{
    empty_it="$1"

    tmp_file="${TMPDIR:-/tmp}/kmt_status_files.$$"

    # minus=$(sort a b | uniq)
    git_status_files | cut -c 4- | sed "s/^/$STX/" | index_encode_inline | LC_ALL=C sort > "$tmp_file"

#    log "status-files: $(cat "$tmp_file")"

    LC_ALL=C join -t "$ETX" -a1 -e '' -o 1.1,1.2,1.3,2.1 - "$tmp_file" |
                awk -F"$ETX" -v OFS="$ETX" -v ept_id="$empty_it" '{
                    if($4==""){
                        print $1, $2, $3
                    }
                    else if (ept_id=="1"){
                        print $1, "", ""
                    }
                }'

    rm -f "$tmp_file"
}

on_head_moved()
{
    ! refresh_stage_note && echo "refresh stage failed" && return 1

    cd "$REPO_ROOT" && init_path || return 1

    ! cur_commit=$(git_current_head) && return 1
    full_note=$(index_get_file "$cur_commit" "full")

    if [ ! -s "$full_note" ]; then
        ! rebuild_full_index "$cur_commit" && echo "rebuild full index failed" && return 1
    fi

    log "restore mtimes from full note $full_note"
    # the un-committed(modified and staged) files should exclude from restore list

#    ! index_is_valid "full" "$full_note" && echo "invalid full note" && return 1
#
#    ! str=$(preview_fs_mtime "HEAD") && return 1
#
#    ! printf "%s\n" "$str" | index_is_valid "stage"  && echo "invalid stage note" && return 1

    ! preview_fs_mtime "HEAD" \
    | LC_ALL=C sort | exclude_status_files "" |
            LC_ALL=C join -t "$ETX" -o 1.1,2.2,1.2,1.5 "$full_note" - |
                awk -F"$ETX" -v OFS="$ETX" '
                {
                    note_ts=$3
                    if(note_ts==""){
                        note_ts=$4
                    }
                    if ($2 > note_ts) {
                        print substr($1,2),note_ts
                    }
                }
                ' | batch_touch && echo "restore mtimes failed" && return 1

    log "restore mtimes ok"

    return 0
}

checkout_mtime_from_source()
{
    rpath="$1"
    source="$2"
    file_fs="$3"

    #get the real commit of $path to the specified source"
    if ! last_commit=$(git_last_commit_of_file "${rpath#*"${SUB_DIR}"}" "$source"); then
        log "no last commit to restore" && return 1
    fi

    if git_note_mtime "$rpath" "$last_commit"; then
        note_ts="$MTIME_RESULT"
    else
        note_ts=$(git_commit_time "$last_commit")
        log "use commit ts as note ts: $note_ts, $last_commit"
    fi

    [ -z "$note_ts" ] && echo "no timestamp to restore" && return 0

#    log "$rpath, $note_ts, $last_commit"
    synchronize_file "$rpath" "$note_ts" "$file_fs" || return 1

    return 0
}

restore_file_from_source()
{
    ir_path="$1"    #inline path to repo root
    source="$2"
    file_ts="$3"

    if [ -z "$source" ]; then
        # Look up the mtime of a file in the current HEAD's stage note.
        ! head_commit=$(git_current_head) && return 1
        stage_file=$(index_get_file "$head_commit" "stage")

        if index_get_file_mtime "$STX$ir_path" "$stage_file" && stage_ts="$MTIME_RESULT" && [ -n "$stage_ts" ]; then
            if [ "D" != "$stage_ts" ]; then
                log "restore from stage: $stage_ts"
                ! synchronize_file "$ir_path" "$stage_ts" "$file_ts" && return 1
                return 0
            fi
        fi

        log "restore from the last commit: $ir_path"
        checkout_mtime_from_source "$ir_path" "" "$file_ts" || return 1
    else
        log "checkout mtime from source: $source, '$ir_path'"
        checkout_mtime_from_source "$ir_path" "$source" "$file_ts" || return 1
    fi

    return 0
}


# ---------------------------------------------------------------------------
# prev / post-hooks
# ---------------------------------------------------------------------------

pre_commit()
{
    now_ts=$(date +%s)
    head_commit=$(git_current_head)

    ! refresh_stage_note && return 1

    stage_file=$(index_get_file "$head_commit" "stage")
    [ ! -f "$stage_file" ] && return 0

    full_note_file=$(index_get_file "$head_commit" "full")

    log "on prev commit: $stage_file"
    while IFS="$ETX" read -r file mtime _
    do
        log "check: $file, $mtime, $now_ts"
        if [ "$mtime" != "D" ]; then
            if [ -f "$full_note_file" ] && index_select_item_value 4 "$full_note_file" "$file"; then
                  if [ "$mtime" -lt "$now_ts" ]; then
                      echo "The file mtime can not be committed, because it is earlier than the last commit. $(format_timestamp "$mtime") $file"
                  fi
            fi
            if [ "$mtime" -gt "$now_ts" ]; then
                echo "The file mtime can not be committed, because it is in the future. $(format_timestamp "$mtime") $file"
                return 2
            fi
        fi
    done < "$stage_file"

    return 0
}

pre_revert()
{
    ! revert_target=$(skip_opt_args_from "revert" "m" "$@") && echo "revert target not found" && return 1

    git_rev_parse "${revert_target%%.*}~1" > "$(index_get_file "revert_target" "last")"

    return 0
}

pre_rebase()
{
    REBASE_ONTO_COMMIT=
    if select_arg "--continue" "$@"; then
        pre_commit || return 1

        stage_file=$(index_get_file "$head_commit" "stage")
        [ -s "$stage_file" ] && kmt_note_oid=$(origin_git hash-object "$stage_file") || kmt_note_oid=

        message_file=".git/rebase-merge/message"
        [ -f "$message_file" ] || message_file=".git/rebase-apply/message"

        [ -f "$message_file" ] || {
            echo "rebase message file not found"
            return 1
        }

        if grep "^kmt-note-oid: " "$message_file"; then
            sed -i "s/^kmt-note-oid: .*/kmt-note-oid: ${kmt_note_oid}/" "$message_file" > "$message_file.$$"
            mv -f "$message_file.$$" "$message_file" || return 1
        else
            [ "$ENABLE_OID_VERIFY" = 1 ] && echo "kmt-note-oid: ${kmt_note_oid}" >> "$message_file"
        fi

        REBASE_ONTO_COMMIT=$(cat .git/rebase-merge/onto) ||
            REBASE_ONTO_COMMIT=$(cat .git/rebase-apply/onto)

    elif select_any "--skip --abort --quit --edit-todo --show-current-patch" "$@"; then
        REBASE_ONTO_COMMIT=$(cat .git/rebase-merge/onto) ||
            REBASE_ONTO_COMMIT=$(cat .git/rebase-apply/onto)
    else
        rebase_onto=$(skip_opt_args_from "rebase" "m" "$@") || return 1

        [ -z "$rebase_onto" ] && rebase_onto=$(select_arg "--onto" "$@")

        REBASE_ONTO_COMMIT="$rebase_onto"

        git_current_head > "$(index_get_file "rebase_orig_head" "last")"
    fi

    return 0
}

post_clone()
{
    ! upstream_url=$(grep_arg '[^ ]+\.git$' "$@") && echo "unknown url" && return 0
    log "url: $upstream_url"

    repo_dir=$(select_arg "$upstream_url" "$@")
    if [ -z "$repo_dir" ] ; then
        repo_dir=$(print_n "$upstream_url" | grep -Eo '(:|/).*\.git$' | cut -c 2- | sed 's/.git$//')
    fi
    log "repo: $repo_dir"

    cd "$repo_dir" && init_path || return 1

    if ! post_fetch; then
        echo "post_fetch failed"
        return 1
    fi

    ! on_head_moved && echo "post_head_moved failed" && return 1

    return 0
}

post_commit()
{
    note_file="$1"

    [ ! -f "$note_file" ] && echo "stage file missing, it should be created before commit" && return 1
    ! cur_commit=$(git_current_head) && return 1

    if [ -s "$note_file" ]; then
        if ! str=$(git_note_add "$cur_commit" "$note_file"); then
            echo "add commit note failed: $note_file"
            return 1
        fi
    else
        log "empty note, $note_file"
    fi

    log "add note ok $cur_commit, $note_file"

    ! cur_commit=$(git_current_head) && return 1
    ! commit_ts=$(git_commit_time "$cur_commit") && return 1
    cur_full_note=$(index_get_file "$cur_commit" "full")

    ! pre_commit=$(git_prev_commit) && return 1
    pre_full_note=$(index_get_file "$pre_commit" "full")

    if [ -n "$pre_commit" ] && [ -f "$pre_full_note" ] && [ -f "$note_file" ]; then
        log "merge full note for $cur_commit ..."

        ! index_is_valid "stage" "$note_file" && echo "invalid content in stage file: $note_file" && return 1

        delta=$(cat "$note_file")

        if ! (index_merge_with_delta "$pre_full_note" "$delta" "$cur_commit" "$commit_ts") > "$cur_full_note"; then
            echo "merge full note failed"
            rm -f "$cur_full_note"
            return 1
        fi

        ! index_is_valid "full" "$cur_full_note" && echo "invalid content in index file: $cur_full_note" && return 1

        log "merge full note for $cur_commit ok"

        ! set_file_mtime "$cur_full_note" "$commit_ts" && return 1
        ! rm -f "$pre_full_note" && return 1

    else
        log "build full note for $cur_commit ..."

        if ! rebuild_full_index "$cur_commit"; then
            echo "build full note for $cur_commit failed"
            return 1
        fi

        log "build full note for $cur_commit ok"
    fi

    return 0
}

checkout_staged_file_mtimes_from_source()
{
    source=$1
    ts_cmd=$2

    git_status_files | grep '^[AM] ' | cut -c 4- |
        while IFS= read -r rpath
        do
            decode_from_inline "$rpath"; path="$DECODE_RESULT"

            file_ts=$(get_file_mtime "$REPO_ROOT/$path") || return 1
            if [ "$file_ts" -ge "$ts_cmd" ]; then
                log "restore: $rpath"
                checkout_mtime_from_source "$rpath" "$source" || return 1
            else
                log "keep mtime: $rpath, $file_ts"
            fi
        done

    return 0
}

post_checkout_files()
{
    working_files_before=$1
    ts_cmd="$2"
    source="$3"

    #select the staged and not modifying files
    ! checkout_staged_file_mtimes_from_source "$source" "$ts_cmd" && return 1

    ! refresh_stage_note "$working_files_before" && return 1

    return 0
}

post_merge_failed_with_conflicts()
{
    cmd="$1"
    old_commit_id="$2"
    ts_cmd="$3"

    shift
    shift
    shift

    ! head_commit=$(git_current_head) && return 1

    if select_any "--continue" "--abort" "--quit" "$@"; then
        log "pass $*"
    else
        if [ "$cmd" = "merge" ]; then
            ! source=$(skip_opt_args_from "merge" "m" "$@") && echo "merge source not found" && return 1
        elif [ "$cmd" = "revert" ]; then
            source=$(cat "$(index_get_file "revert_target" "last")")
#            ! revert_target=$(skip_opt_args_from "revert" "m" "$@") && echo "revert target not found" && return 1
#            source=${revert_target%%.*}~1
        else
            echo "Invalid command $cmd"
            return 1
        fi

        [ -z "$source" ] && echo "No source to $cmd" && return 1

        log "merge_source: $source"

        ! checkout_staged_file_mtimes_from_source "$source" "$ts_cmd" && return 1
    fi

    refresh_stage_note || return 1

    return 0
}

parse_range_diff()
{
    awk '{
            left = "-"; right = "-"; n = 0; s = $0
            while (match(s, /[0-9a-fA-F-]{40,}/)) {
              seg = substr(s, RSTART, RLENGTH)
              if (seg ~ /^-+$/) seg = "-"
              n++
              if (n == 1) left = seg
              else if (n == 2) { right = seg; break }
              s = substr(s, RSTART + RLENGTH)
            }
            print left, right
        }'
}

complete_rewritten_commit()
{
    while read -r orig_commit rewritten_commit
        do
            log "$orig_commit, $rewritten_commit"

            [ "$rewritten_commit" = "-" ] && log "skip orig_commit: $orig_commit" && continue

            if ! git_note_show "$rewritten_commit"; then
                prev_commit=$(git_prev_commit "$rewritten_commit") || return 1

                prev_stage_file=$(index_get_file "$prev_commit" "stage")

                if [ -f "$prev_stage_file" ]; then
                    log "complete commit from stage: $prev_stage_file to $rewritten_commit"
                    git_note_add "$rewritten_commit" "$prev_stage_file" || return 1
                    rm -f "$prev_stage_file" || return 1
                else
                    [ "$orig_commit" = "-" ] && log "skip rewritten_commit: $rewritten_commit" && continue

                    log "complete commit by copy: $orig_commit to $rewritten_commit"
                    git_note_copy "$orig_commit" "$rewritten_commit" || return 1
                fi
            fi
        done

    return 0
}

post_rebase_failed_with_conflicts()
{
    old_commit_id=$1
    ts_cmd="$2"
    shift
    shift

    if select_any "--skip --abort --quit --edit-todo --show-current-patch" "$@"; then
        log "pass $*"
    else
        # restore file mtimes to the rebase onto commit
        rewritten_list_file=".git/rebase-merge/rewritten-list"
        [ -f "$rewritten_list_file" ] || rewritten_list_file=".git/rebase-apply/rewritten-list"

        if [ -f "$rewritten_list_file" ]; then
            cat < "$rewritten_list_file" | complete_rewritten_commit || return 1
        fi

        source=$(origin_git rev-parse REBASE_HEAD) || return 1

        checkout_staged_file_mtimes_from_source "$source" "$ts_cmd" || return 1
    fi

    if [ "$old_commit_id" != "$(git_current_head)" ]; then
        on_head_moved || return 1
    fi

    refresh_stage_note || return 1

    return 0
}

post_rebase_succeed()
{
    old_commit_id=$1
    shift

    log "params: $old_commit_id, $*"

    if ! select_any "--skip --abort --quit --edit-todo --show-current-patch" "$@"; then
        # old_commit_id is not the real orig_head when --continue
        # the ORIG_HEAD is also untrustable, it may changed when rebase --skip
        # A better method is save the HEAD to a file when rebase started, read it out here

#        orig_head=$(git_rev_parse ORIG_HEAD)

        last_head_file=$(index_get_file "rebase_orig_head" "last")
        if [ ! -f "$last_head_file" ]; then
            echo "Last rebase orig head file missing"
            return 1
        fi

        orig_head=$(cat "$last_head_file")

        [ -z "$orig_head" ] && echo "orig_head not found" && return 1

        onto_commit="$REBASE_ONTO_COMMIT"

        [ -z "$onto_commit" ] && echo "onto_commit not found" && return 1

        if range_diff_list=$(origin_git range-diff --no-abbrev --no-color \
                        "$onto_commit..$orig_head" \
                        "$onto_commit..HEAD"
                        ); then

#            log "range_diff $onto_commit..$orig_head, $onto_commit..HEAD:
#$range_diff_list"

            print_n "$range_diff_list" |
                      parse_range_diff |
                      complete_rewritten_commit || return 1
        else
            log "range-diff failed $onto_commit..$orig_head, $onto_commit..HEAD"
            return 1
        fi
    fi

    if [ "$old_commit_id" != "$(git_current_head)" ]; then
        ! on_head_moved && echo "on head moved failed" && return 1
    fi

    ! refresh_stage_note && echo "refresh_stage_note failed" && return 1

    return 0

}

post_merge_succeed_from_source()
{
    cmd=$1
    old_commit_id="$2"
    ts_cmd="$3"

    shift
    shift
    shift

    source=
    if ! select_any "--continue --abort --quit" "$@"; then
        if [ "$cmd" = "merge" ]; then
            ! source=$(skip_opt_args_from "merge" "m" "$@") && echo "merge source not found" && return 1
        elif [ "$cmd" = "revert" ]; then
            source=$(cat "$(index_get_file "revert_target" "last")")
#            ! revert_target=$(skip_opt_args_from "revert" "m" "$@") && echo "revert target not found" && return 1
#            source=${revert_target%%.*}~1
            log "revert source: $source"
        else
            echo "Invalid command $cmd"
            return 1
        fi
        [ -z "$source" ] && echo "No source to $cmd, $*" && return 1
    fi

    ! head_commit=$(git_current_head) && return 1

    if [ "$old_commit_id" = "$head_commit" ]; then
        if ! select_any "--abort --quit" "$@"; then
            ! checkout_staged_file_mtimes_from_source "$source" "$ts_cmd" && return 1
        fi

        log "$cmd not complete $old_commit_id"

        ! refresh_stage_note && return 1

    else
        if select_arg "--continue" "$@"; then

            log "$cmd succeeded after conflicts resolved"

            note_file="$(index_get_file "$old_commit_id" "stage")"

            [ -f "$note_file" ] || note_file=

        else
            log "$cmd succeeded with no conflicts"

            git_diff_commit_files "$head_commit" |
                while IFS="$ETX" read -r status rpath
                do
                    [ "$status" = "D" ] && continue

                    decode_from_inline "$rpath"; path="$DECODE_RESULT"

                    file_ts=$(get_file_mtime "$REPO_ROOT/$path") || return 1
                    if [ "$file_ts" -ge "$ts_cmd" ]; then
                        log "restore: $rpath"
                        checkout_mtime_from_source "$rpath" "$source" || return 1
                    else
                        log "keep mtime: $rpath, $file_ts"
                    fi
                done
        fi

        if [ -z "$note_file" ]; then

            note_file="$(index_get_file "$head_commit" "commit")"

            ! note=$(prebuild_commit_note "$head_commit") && echo "$note" && return 1

            print_n "$note" | LC_ALL=C sort > "$note_file"

            if [ -s "$note" ]; then
                ! index_is_valid "delta" "$note_file" && echo "invalid content in delta file: $note_file" && return 1
            fi
        fi

        if [ "$ENABLE_OID_VERIFY" = 1 ]; then
            [ -s "$note_file" ] && kmt_note_oid=$(origin_git hash-object "$note_file") || kmt_note_oid=

            log "amend trailer: $kmt_note_oid, commit: $head_commit, prev-commit: $old_commit_id"

            ! origin_git commit --amend --trailer "kmt-note-oid: $kmt_note_oid"  --allow-empty --no-edit && return 1
        fi

        ! post_commit "$note_file" && return 1

        if [ "$ENABLE_OID_VERIFY" = 1 ]; then
            [ -s "$note_file" ] && [ "$(git_note_oid "HEAD")" != "$kmt_note_oid" ] && echo "NOTE-OID Check Failed" && return 1
        fi

        [ -f "$note_file" ] && rm -f "$note_file"

    fi

    return 0
}

post_restore_files()
{
    files="$1"
    cmd_ts="$2"
    source="$3"

    [ -n "$files" ] && while IFS= read -r ipath;
    do
        log "restore: $ipath"
        decode_from_inline "$ipath"
        path="$DECODE_RESULT"

        [ ! -e "$path" ] && echo "file not found $path" && continue

        if [ -d "$path" ]; then
            # restore the mtime for each files which fs mtime later then $ts_before in $sub_files
            sub_files=$(preview_fs_mtime "HEAD" "$path" | cut -c 2-)
            [ -n "$sub_files" ] && while IFS="$ETX" read -r ir_file file_mts _
                do
                    [ "$file_mts" -lt "$cmd_ts" ] && continue
                    ! restore_file_from_source "$ir_file" "$source" "$file_mts" && return 1
                done <<EOF
$sub_files
EOF
        else
            ! file_ts=$(get_file_mtime "$path") && return 1

            [ "$file_ts" -lt "$cmd_ts" ] && echo "file not changed: $file_ts < $cmd_ts" && continue

            ! restore_file_from_source "$SUB_DIR$ipath" "$source" "$file_ts" && echo "restore failed: $SUB_DIR, $path" && return 1
        fi
    done << EOF
$files
EOF
    return 0
}

post_push ()
{
    ! origin_git push \
                origin \
                "refs/notes/$NOTE_REF:refs/notes/$NOTE_REF" && return 1 || return 0
}

post_fetch()
{
    old_commit_id="$1"

    old_note_id="$(git_rev_parse "refs/notes/$NOTE_REF")"

    if ! origin_git fetch origin "+refs/notes/$NOTE_REF:refs/notes/$NOTE_REF"; then
        return 1
    fi

    new_note_id=$(git_rev_parse "refs/notes/$NOTE_REF")

    if [ -n "$old_note_id" ] &&
        [ -n "$new_note_id" ] &&
        [ "$old_note_id" != "$new_note_id" ]; then

        log "old_note_id: $old_note_id, new_note_id: $new_note_id"

        git diff-tree -r "$old_note_id" "$new_note_id" --name-only | sed 's/\///' | while IFS= read -r commit_id
            do
                log "commit note changed: $commit_id"
                ! refresh_later_full_notes "$commit_id" && return 1
            done
    fi

    return 0
}

post_pull()
{
    old_commit_id="$1"

    if ! post_fetch "$old_commit_id"; then
        return 1
    fi

    if [ "$(git_current_head)" != "$old_commit_id" ]; then
        ! on_head_moved && return 1

        full_note_file=$(index_get_file "$old_commit_id" "full")
        [ -f "$full_note_file" ] && rm -f "$full_note_file"
    else
        log "head has not moved: $old_commit_id"
        if [ "$old_note_id" != "$new_note_id" ]; then
            log "note has changed: $old_note_id"
            ! on_head_moved && return 1
        else
            log "note has not changed: $old_note_id"
        fi
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Checkout / restore / pull/update handlers
# ---------------------------------------------------------------------------

git_command_handler()
{
    cmd="$1"
    shift

    log "git_command_handler $*"

    [ -z "$cmd" ] && return 1
    ts_before=$(date +%s)
    case "$cmd" in
        add|rm|rename|checkout|restore)
            working_files_before=$(git_status_files | grep '^.M' | cut -c 4-)
            ;;
        commit)
            pre_commit || return 1
            ;;
        revert)
            pre_revert "$@" || return 1
            ;;
        rebase)
            pre_rebase "$@" || return 1
            ;;
        reset)
            ;;
    esac

    if [ "$cmd" = 'clone' ]; then
        old_commit_id=
    else
        ! old_commit_id=$(git_current_head) && return 1
    fi

#    log "git cmd: $*"

    if [ "$cmd" = "commit" ]; then

        ! refresh_stage_note && echo "refresh stage note failed!" && return 1

        select_arg "--trailer" "$@" | grep -q "^kmt-note-oid:" && echo "Do not specify the kmt-note-oid manually" && return 1

        if [ "$ENABLE_OID_VERIFY" = 1 ]; then
            stage_file=$(index_get_file "$old_commit_id" "stage")

            [ -s "$stage_file" ] && kmt_note_oid=$(origin_git hash-object "$stage_file") || kmt_note_oid=

            log "add trailer: $kmt_note_oid"

            id=$(select_arg_pos "commit" "$@")

            eval "$(insert_after "$((id + 1))" "2" "--trailer" "kmt-note-oid: $kmt_note_oid" "$@")"

            log "args: $id, $*"
        fi
    fi

    origin_git "$@"

    ret=$?

    if [ "$ret" = 0 ]; then
        log "origin_git $cmd ok"
    else
        case "$cmd" in
            merge|revert)
                [ "$ret" = 1 ] && post_merge_failed_with_conflicts "$cmd" "$old_commit_id" "$ts_before" "$@"
                ;;
            rebase)
                [ "$ret" = 1 ] && post_rebase_failed_with_conflicts "$old_commit_id" "$ts_before"
                ;;
        esac
        log "origin_git $cmd failed: $ret"
        return $ret
    fi

    case "$cmd" in
        add|rm|rename)
            log "post $cmd ..."
            ! refresh_stage_note "$working_files_before" && echo "$cmd succeeded but timestamp note $cmd failed." && return 1
            log "post $cmd ok"
            ;;
        commit)
            log "post $cmd ..."

            pre_stage_note_file="$(index_get_file "$old_commit_id" "stage")"

            ! post_commit "$pre_stage_note_file" && echo "commit succeeded but timestamp note creation failed." && return 1

            if [ "$ENABLE_OID_VERIFY" = 1 ]; then
                verify_or_amend_commit_note "$pre_stage_note_file"
                ret=$?
                case "$ret" in
                    1)
                        echo "verify failed"
                        return 1
                    ;;
                    2)
                        echo "amended ok"
                    ;;
                    0)
                        echo "verified ok"
                        [ -s "$pre_stage_note_file" ] && [ "$(git_note_oid "HEAD")" != "$kmt_note_oid" ]  && echo "NOTE-OID Check Failed" && return 1
                      ;;
                esac
            fi

            [ -f "$pre_stage_note_file" ] && rm -f "$pre_stage_note_file"

            log "post $cmd ok"
            ;;
        restore)
            log "post $cmd ..."
            if select_arg "--staged" "$@"; then
                # in this case( with --staged), the file just moved out from the stage, but not restore the file content.
                # and commit not changed, so do not restore the mtime, just refresh the stage note.
                ! refresh_stage_note "$working_files_before" && return 1
                log "post $cmd ok"
                return 0
            fi

            if source=$(select_arg "--source" "$@"); then
                log "source: $source"
                files=$(select_args_inline "--source=$source" "$@")
            else
                source=
                files=$(select_args_inline "restore" "$@")
            fi

            if [ -n "$files" ]; then
                log "restore $files from source: '$source'"
                post_restore_files "$files" "$ts_before" "$source" || return 1
            else
                echo "no files to restore" && return 1
            fi
            log "post $cmd ok"
            ;;
        checkout)
            log "post $cmd ..."
            source=$(select_arg "checkout" "$@")
            [ -z "$source" ] && echo "unknown branch" && return 1

            if select_arg "--" "$@" > /dev/null; then
                files=$(select_args "--" "$@")
            else
                files=$(select_args "$source" "$@")
            fi

            if [ "$(git_current_head)" != "$old_commit_id" ]; then
                echo "checkout from $old_commit_id to $(git_current_head)"
                ! on_head_moved && return 1
            elif [ -n "$files" ]; then
                #checkout path may be a dir, and they had moved into the stage
                ! post_checkout_files "$working_files_before" "$ts_before" "$source" && return 1
            fi
            log "post $cmd ok"
            ;;
        switch)
            log "post $cmd ..."
            if [ "$(git_current_head)" != "$old_commit_id" ]; then
                on_head_moved || return 1
            fi
            log "post $cmd ok"
            ;;
        merge|revert)
            log "post $cmd ..."

            ! post_merge_succeed_from_source "$cmd" "$old_commit_id" "$ts_before" "$@" && return 1

            log "post $cmd ok"
            ;;
        rebase)
            log "post $cmd ..."
            ! post_rebase_succeed "$old_commit_id" "$@" && echo "post $cmd failed" && return 1
            log "post $cmd ok"
            ;;
        reset)
            log "post $cmd ..."
            if select_arg "--hard" "$@" && [ "$(git_current_head)" != "$old_commit_id" ]; then
                on_head_moved || return 1
            fi
            log "post $cmd ok"
            ;;
        clone)
            log "post $cmd ..."
            if ! post_clone "$@"; then
                ! origin_git ls-remote --exit-code origin "refs/notes/$NOTE_REF" && echo "ref:$NOTE_REF not exists" && return 0
                return 1
            fi
            log "post $cmd ok"
            ;;
        push)
            log "post $cmd ..."
            if ! post_push; then
                ! origin_git ls-remote --exit-code origin "refs/notes/$NOTE_REF" && echo "ref:$NOTE_REF not exists" && return 0
                echo "Git push succeeded but timestamp note push failed." && return 1
            fi
            log "post $cmd ok"
            ;;
        fetch)
            log "post $cmd ..."
            if ! post_fetch "$old_commit_id"; then
                ! origin_git ls-remote --exit-code origin "refs/notes/$NOTE_REF" && echo "ref:$NOTE_REF not exists" && return 0
                echo "Git pull succeeded but timestamp note fetch failed." && return 1
            fi
            log "post $cmd ok"
            ;;
        pull)
            log "post $cmd ..."
            if ! post_pull "$old_commit_id"; then
                ! origin_git ls-remote --exit-code origin "refs/notes/$NOTE_REF" && echo "ref:$NOTE_REF not exists" && return 0
                echo "Git pull succeeded but timestamp note pull failed." && return 1
            fi
            log "post $cmd ok"
            ;;
    esac

    return 0
}

# ---------------------------------------------------------------------------
# KMT command UI / command handler
# ---------------------------------------------------------------------------

init_path()
{
    #Use pwd -P to get the realpath, eg. /tmp
    CUR_DIR=$(pwd -P)
    REPO_ROOT=$(git_repo_root)
    GIT_DIR=$(git_repo_dir)
    [ "$REPO_ROOT" = "$CUR_DIR" ] && SUB_DIR= || SUB_DIR=${CUR_DIR#*"$REPO_ROOT/"}/
    find_command "look" > /dev/null && IS_LOOK_INSTALLED=1 || IS_LOOK_INSTALLED=0
}

show_note()
{
    while IFS="$ETX" read -r file mtime btime ci ct l2nd_cts first_commit
    do
        [ -z "$file" ] && continue

        btime=$(format_timestamp "$btime")

        if is_timestamp "$mtime"; then
            fast_format_timestamp "$mtime"
            mtime="$FORMAT_RESULT"
        fi

        printf "%s\n" "$file, $mtime, $btime, $ci, $ct, $l2nd_cts, $first_commit"
    done
    return 0
}

kmt_note()
{
    key="$1"
    shift

    tm_start=$(date +%s.%N | sed 's/0*$//')
    case $key in
        1)
            str=$(git_note_show "$commit") &&
                [ -n "$str" ] && print_n "$str" | show_note||
                echo "$str"
            ;;
        2)
#            index_show "full" "$commit"
            str=$(index_show "full" "$commit") &&
                [ -n "$str" ] && print_n "$str" | show_note||
                echo "$str"
            ;;
        3)
            str=$(index_show "stage" "$commit") &&
                [ -n "$str" ] && print_n "$str" | show_note ||
                echo "$str"
            ;;
        4)
            preview_fs_mtime "$commit" | show_note ||
                echo "FAILED"
            ;;
        5)
            note_show_history "$commit" "$2"
            ;;
        6)
            prebuild_commit_note "$commit" | LC_ALL=c sort | show_note ||
                echo "FAILED"
            ;;
        7)
            ! rebuild_commit_note "$commit" && return 1
            ;;
        8)
            prebuild_full_index "$commit" | LC_ALL=C sort | show_note
            ;;
        9)
            ! rebuild_full_index "$commit" && echo "build full note for $commit failed" && return 1
            ;;
        10)
            git_last_commit_of_files "$commit" | LC_ALL=C sort | show_note
            ;;
        11)
            git_3_commits_of_files "$commit" | LC_ALL=C sort | show_note
            ;;
        12)
            on_head_moved || return 1
            ;;
        *)
            echo "Invalid sub command: $key"
            return 0
            ;;
    esac

    tm_end=$(date +%s.%N | sed 's/0*$//')

    duration=$(float_diff "$tm_end" "$tm_start")

    echo "done."
    echo "Elapsed time(s): ${duration}"

    return 0
}

kmt_note_ui()
{
    alias=${1:-HEAD}

    app_is_working_copy || return 1

    ! commit=$(git_rev_parse "$alias") || [ -z "$commit" ] && echo "Commit not exists: $alias" && return 1

    [ "$alias" = "$commit" ] && alias=

    key=

    while true
    do
        if [ -z "$key" ]; then
            git_note_show "$commit" > /dev/null && note_exists=1 || note_exists=0
            full_note_file=$(index_get_file "$commit" "full") &&
                [ -f "$full_note_file" ] && full_note_exists=1 || full_note_exists=0

            cat << EOF

Select an operation:

commit: $commit$([ -n "$alias" ] && echo "($alias)")
commit date: $(format_timestamp "$(git_commit_time "$commit")")

  -- Commit Note --

    1   -- List commit-note$([ "$note_exists" = "0" ] && echo " (NOT EXISTS)")
    2   -- List full-note$([ "$full_note_exists" = "0" ] && echo " (NOT EXISTS)")

  -- Index & Working --

    3   -- List stage-note (indexed files)
    4   -- List tracked files

  -- History --

    5   -- List mtime note history for a specified file

  -- Modification --

    6   -- Preview commit-note to complete
    7   -- Complete the commit-note$([ "$note_exists" = "1" ] && echo " (ALREADY EXISTS)")

    8   -- Preview full-note to complete
    9   -- Complete the full-note$([ "$full_note_exists" = "1" ] && echo " (ALREADY EXISTS)")

  Other -- Exit

EOF
            read -r key

            [ -z "$key" ] && return 0
        fi

        if [ "$key" = 5 ]; then
            echo "Input a file to show history:"
            read -r file
            [ -z "$file" ] && key= && continue

            kmt_note "5" "$file"

            continue
        else
            kmt_note "$key"
        fi

        read -r key
    done

    return 0
}


app_command_handler()
{
    cmd=$(skip_opt_args "c" "$@")

    case "$cmd" in
        -h|--help|help)
            if [ "$2" = 'kmt' ]; then
                show_help
            else
                origin_git "$@"
            fi
            ;;
        add|rm|rename|commit|merge|restore|revert|reset|rebase|switch|checkout|clone|push|fetch|pull)
            init_path
            git_command_handler "$cmd" "$@"
            ;;
        kmt-note)
            shift
            init_path
            key="$1"
            shift
#            alias="$2"
#            alias="$(select_arg "kmt-note" "$@")"
            if [ -z "$key" ]; then
                kmt_note_ui "$@"
            else
                app_is_working_copy || return 1
                alias="${1:-HEAD}"
                ! commit=$(git_rev_parse "$alias") || [ -z "$commit" ] && echo "Commit not exists: $alias" && return 1

                kmt_note "$key" "$@"
            fi

            ;;
        *)
            [ -z "$cmd" ] && log "no command: $*"
            origin_git "$@"
            ;;
    esac
}

app_is_working_copy()
{
    ! ret=$(origin_git rev-parse --is-inside-work-tree) && echo "Not in a git repository" &&  return 1

    [ "$ret" != "true" ] && echo "Not in a work tree" && return 1

    return 0
}

app_is_update_to_date()
{
    init_path

    return 0
}

app_get_files_2_commit()
{
    #select working files which diff to staged index
    str=$(origin_git diff --name-only -z -- . | pipe_inline_encode | tr '\0' '\n')
    [ -n "$str" ] && echo "$str" && return 0

    #select added to stage but not committed files
    str=$(git_status_files) || return 1
    str=$(print_n "$str" | grep "^[^?]." | cut -c 4-)
    [ -n "$str" ] && echo "$str" && return 0

    log "no working files"

    return 0
}

app_get_remote_url()
{
    origin_git remote -v | grep -m 1 -oE 'http[s]?://[^/]*'
}

app_kmt_list()
{
    ! commit=$(git_current_head) && return 1

    full_note_file=$(index_get_file "$commit" "full")
    if [ ! -s "$full_note_file" ]; then
        ! rebuild_full_index "$commit" && return 1
    fi

    while IFS= read -r dir
        do
            log "scan dir: $dir"
            ! preview_fs_mtime "$commit" "$dir" |
                LC_ALL=C sort |
                LC_ALL=C join -t "$ETX" -a1 -e '' -o 1.1,1.2,1.3,2.2,2.3,2.5,2.6 - "$full_note_file" | sed "s/^$STX//" && return 1
        done << EOF
$dirs
EOF

    return 0
}

app_complete_file_time()
{
    file="$1"
    [ -z "$file" ] && return 1

    type="$2"
    [ -z "$type" ] && return 1

    file_ts=$3
    [ -z "$file_ts" ] && return 1

    commit_time=$4
    [ -z "$commit_time" ] && return 1

    encode_into_inline "$file" && efile="$ENCODE_RESULT"

    if ! commit=$(origin_git log -1 --format='%H' --since="$commit_time" --until="$commit_time" -- "$file"); then
#    if ! commit=$(git_last_commit_of_file "$efile"); then
        echo "$commit"
        echo "get commit failed '$file'" && return 1
    fi

    if git_note_mtime "$SUB_DIR$efile" "$commit"; then
        [ "$type" = 1 ] && note_ts="$MTIME_RESULT" || note_ts="$BTIME_RESULT"
        if [ "$note_ts" = "$file_ts" ]; then
            log "mtime exists in note, type:$type, file:'$file', 'ts':$file_ts,  'commit':$commit,"
            return 0
        fi
    fi

    log "complete file: '$file', note ts: $note_ts, file_ts, $file_ts, commit: $commit"

    ! rebuild_commit_note "$commit" && echo "update commit note failed" && return 1

    log "rebuild commit note ok '$file'"

    return 0
}

app_on_kmt_completed()
{
    return 0
}

app_on_kmt_resolved()
{
    return 0
}

main "$@"
