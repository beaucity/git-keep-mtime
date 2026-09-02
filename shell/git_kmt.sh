#!/bin/sh

# git_kmt.sh - Git Keep MTime prototype
#
# Storage model:
#   git notes --ref=timestamps <commit>
#
# Note format:
#   path\x03unix_mtime
#
# The wrapper is intentionally implemented as POSIX sh.  It keeps the
# original Git executable behind .git_kmt/git and forwards all commands that
# are not handled by KMT to that executable.
APP='git'
APP_KMT='git_kmt'
KMT_FULL_NAME='Git Keep MTime'
KMT_VERSION='0.1.2-alpha'

META_NAME="mtime-notes"

#NOTE_REF="timestamps"
NOTE_REF="kmt/mtime"

STX=$(printf '\x02')
TAB=$(printf '\t')

CUR_DIR=$(pwd)
REPO_ROOT=
GIT_DIR=
SUB_DIR=


#!/bin/sh
##############################################################################
# Utility
##############################################################################

PLATFORM=""

KMT_DEBUG=1

TZ_SECONDS=0

last_log_ts=
logging=
log()
{
    ret=$?

    [ -z "$KMT_DEBUG" ] && return $ret

    [ -n "$logging" ] && return $ret

    logging=1

    [ -n "$last_log_ts" ] && tsd=$(float_diff "$(date +%s.%N)" "$last_log_ts") || tsd=$(date +%s)

#    echo "[ + $tsd] $*" >&2
    echo "[ $$ + $tsd] $*" >> "/tmp/$APP_KMT.log"

    last_log_ts=$(date +%s.%N)

    logging=
    return $ret
}

set_debug_mode()
{
    KMT_DEBUG=${1:-1}
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

    str="$(cd "$(dirname "$dir")" && pwd)/$(basename "$dir")" || return 1

    echo "$str"

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

    path=$(command -v "${1}" 2>/dev/null) && [ -x "$path" ] && echo "$path" && return 0

    path=$(which "${1}" 2>/dev/null) && [ -x "$path" ] && echo "$path" && return 0

    return 1
}

##############################################################################
# Time Functions
##############################################################################

is_timestamp()
{
    echo "$1" | grep -Eq '^[0-9]+$'
}

format_timestamp() {
#    log "ts: $1, tz: $TZ_SECONDS"
    [ -z "$1" ] && return 0

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
                echo "get_file_mtime failed: '$file'"
                return 1
            fi
            ;;


        macos)

            if ! stat -f %m "$file"; then
                echo "get_file_mtime failed: '$file'"
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
    file="$1"
    timestamp="$2"

    ! is_timestamp "$timestamp" && echo "invalid timestamp: $timestamp" && return 1

    case "$PLATFORM" in

        linux)

            touch -m -d "@$timestamp" "$file" || return 1

            ;;

        macos)

            touch -m \
                -t "$(date -r "$timestamp" "+%Y%m%d%H%M.%S")" \
                "$file" || return 1

            ;;

        *)

            return 1
            ;;

    esac
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

select_arg()
{
    key=$1
    shift
    _select_from_args 1 "$key" "$@"
}

select_args()
{
    key=$1
    shift
    _select_from_args 0 "$key" "$@"
}

_select_from_args()
{
    one_only=$1
    key=$2
    opt_key=

    shift
    shift

    for p in "$@";
    do
        case "$p" in
            "$key"=*)
                echo "${p#*"$key"=}"
                return 0
            ;;
            "$key")
                opt_key=$p && continue
            ;;
            *)
                if [ -n "$opt_key" ]; then
                    echo "$p"
                    [ "$one_only" = 1 ] && return 0
                fi
            ;;
        esac
    done

    [ -n "$opt_key" ] && return 0

    return 1
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
        echo "$p"
    done

    return 0
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

        [ -L "$orig_caller_path" ] &&
        [ -x "$orig_caller_path" ] &&
        [ "$(basename "$(readlink "$orig_caller_path")")" = "$APP" ]; then
            return 0
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

    ! mkdir -p "$kmt_sub_dir" && ehco "mkdir $kmt_sub_dir failed." && return 1

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
            error "cannot find a writable PATH directory before original git"
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
            error "orig_restore_path is empty but $orig_caller_path is not a symlink"
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

#!/bin/sh

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

on_file_scan()
{
    file=$1
    file_ts=$2
    prop_ts=$3
    version_ts=$4

    [ "$file" = '.' ] && return 0

    checked_count=$(( checked_count+1 ))

    [ -z "$file_ts" ] && echo "No file mtime provided: '$*'" && return 1

    if [ -n "$prop_ts" ]; then
        if [ "$file_ts" = "$prop_ts" ] || [ -d "$file" ]; then
            [ "$cmd" = "show_completed" ] && echo "Completed $(format_timestamp "$file_ts") $file"
            completed_count=$(( completed_count+1 ))
            return 0
        fi

        if [ "$file_ts" -lt "$prop_ts" ]; then
#            COMMENT-COMPLETE-CONFLICT
#            if file_ts < prop_ts, the prop_ts completed by peers may wrong, this working copy should be
#            the right orign mtime

#            Strictly，a completable file mtime should between the latest 2 [A/M]-COMMIT-TIMES.
#            as normal, if working copy is up-to-date, mtime should later then the last 2nd commit time.
#            be carefully, check if it is later then the last 2nd commit time, or is out-of-date

            if app_is_later_then_last_2nd_commit "$file" "$file_ts"; then
                if [ "$cmd" = "resolve" ]; then
                    ! str=$(app_save_file_mtime "$file" "$file_ts") && echo "$str" && return 1
                    echo "Resolve conflicting mtime $(format_timestamp "$prop_ts") replace with $(format_timestamp "$file_ts") '$file'"
                    effected_count=$(( effected_count+1 ))
                else
                    conflict_count=$(( conflict_count+1 ))
    #                log "prop_ts: $prop_ts, file_ts: $file_ts"
                    [ "$cmd" = "show_conflict" ] && echo "Conflict mtime repos: $(format_timestamp "$prop_ts") local: $(format_timestamp "$file_ts") $file"
                fi

                return 0
            else
                log "Out of date file_ts: $file_ts, prop_ts: $prop_ts"
            fi
        fi

        if [ "$cmd" = "synchronize" ]; then
            ! set_file_mtime "$file" "$prop_ts" && echo "Synchronize failed $(format_timestamp "$prop_ts") '$file'" && return 1
            echo "Synchronizing mtime $(format_timestamp "$prop_ts") '$file'"
            effected_count=$(( effected_count+1 ))
        else
            [ "$cmd" = "show_synchronizable" ] && echo "Synchronizable $(format_timestamp "$prop_ts") from $(format_timestamp "$file_ts") $file"
            synchronizable_count=$(( synchronizable_count+1 ))
        fi

    else
        [ -z "$version_ts" ] && echo "No versioned timestamp provided: '$file'" && return 1

        if [ "$file_ts" -ge "$version_ts" ]; then
            [ "$cmd" = "show_unsynchronizable" ] && echo "Unsynchronizable $(format_timestamp "$version_ts") $(format_timestamp "$file_ts") $file"
            unsynchronizable_count=$(( unsynchronizable_count+1 ))
        else
            if [ "$cmd" = 'complete' ]; then
                ! app_save_file_mtime "$file" "$file_ts" && echo "Complete mtime failed $(format_timestamp "$version_ts") $(format_timestamp "$file_ts") '$file'" &&  return 1
                echo "Completing mtime $(format_timestamp "$file_ts") '$file'"
                effected_count=$(( effected_count+1 ))
            else
                [ "$cmd" = "show_completable" ] && echo "Completable $(format_timestamp "$version_ts") $(format_timestamp "$file_ts") $file"
                completable_count=$(( completable_count+1 ))
            fi
        fi
    fi

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
        ! app_is_update_to_date "$dir" && echo "The working copy '${dir:-.}' is not update to date." && return 1

#        if [ "$cmd" = 'complete' ] || [ "$cmd" = 'restore' ] || [ "$cmd" = 'resolve' ]; then

            if ! str=$(app_get_files_2_commit "$dir"); then
                echo "$str"
                return 1
            fi

            has_uncommitted=0
            [ -n "$str" ] && while read -r file
            do
                if [ -e "$file" ]; then
                    echo "Uncommitted changes detected: $file"
                    has_uncommitted=1
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

    ! str=$(app_kmt_list "$@") && echo "$str" && return 1

    log "on scanned: $*"

    [ -n "$str" ] && while IFS="$SEP" read -r file file_ts prop_ts version_ts
    do
        ! on_file_scan "$file" "$file_ts" "$prop_ts" "$version_ts" && return 1
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

    2   -- List mtime completed files $completed_count
    3   -- List mtime completable files $completable_count
    4   -- List mtime synchronizable files $synchronizable_count
    5   -- List files with mtime conflicts $conflict_count
    6   -- List mtime unsynchronizable files ($META_NAME not completed) $unsynchronizable_count

  -- Modify --

    7   -- Complete $META_NAME from local file mtime $completable_count
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
                        echo "The SVN commands should not be called startswith $APP_KMT.sh, but run as follows:
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

    return $?
}

##############################################################################
# Main
##############################################################################

main()
{
    [ "$1" = '--kmt-debug' ] && shift && set_debug_mode 1

    ! detect_platform ||
    ! detect_time_zone ||
    ! detect_original_app && return 1

    dispatch "$@"

    return $?
}

show_help()
{
    cat <<EOF2
Git Keep MTime prototype

Normal Git commands are forwarded to the original Git executable.

KMT commands:
  kmt-install [script]       install wrapper
  kmt-uninstall              uninstall wrapper (must be invoked as: git kmt-uninstall)
  kmt-upgrade [script]       uninstall then install wrapper (must be invoked as: git kmt-upgrade)
  kmt-version                show version
  kmt-note [commit]          show timestamp note
  kmt-history <path>         show file mtime history
  kmt-complete               complete missing historical notes
  kmt-synchronize [commit]   synchronize mtime from a commit note
  kmt-push-notes [remote]    push refs/notes/timestamps
  kmt-fetch-notes [remote]   fetch refs/notes/timestamps

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
  pull
  push

Notes contain only:
  file${SEP}mtime
EOF2
}

# ---------------------------------------------------------------------------
# Git command wrapper
# ---------------------------------------------------------------------------

origin_git()
{
    "$ORIGIN_APP" "$@"
    return $?
}

repo_root()
{
    origin_git rev-parse --show-toplevel 2>/dev/null
}

repo_git_dir()
{
    origin_git rev-parse --git-dir 2>/dev/null
}

# ---------------------------------------------------------------------------
# Commits helpers
# ---------------------------------------------------------------------------

commit_parse()
{
    origin_git rev-parse --verify "$1"
}

is_head()
{
    commit=${1}
    [ -z "$commit" ] && return 1

    if [ "$(commit_parse "$commit")" = "$(current_head)" ]; then
        return 0
    fi

    return 1
}

get_commit_time()
{
    origin_git show -s --format='%ct' "${1:-HEAD}"
#    commit=$1
#    dt=$(origin_git show -s --format='%cI' "$commit") || return 1
#    case "$PLATFORM" in
#        linux) date -d "$dt" +%s 2>/dev/null ;;
#        macos)
#            # macOS date has no portable ISO-8601 parser; normalize the common
#            # +08:00 form to a numeric offset understood by BSD date.
#            date -j -f '%Y-%m-%dT%H:%M:%S%z' "$(echo "$dt" | sed 's/\.[0-9][0-9]*//' | sed 's/Z/+0000/' | sed -E 's/([+-][0-9][0-9]):([0-9][0-9])$/\1\2/')" '+%s' 2>/dev/null
#            ;;
#        *) return 1 ;;
#    esac
}

last_commit_for_file()
{
    path=$1
    to_commit=${2:-HEAD}
    origin_git log -1 "$to_commit" --format='%H' -- "$path"
}

last_commit_for_files()
{
    commit=${1:-HEAD}
#    log "1"
#    origin_git ls-tree -r --name-only "$commit" | xargs -P5 -n1 sh -c "
#      hash=\$(git log -1 --format=%H $commit -- "\$1" 2>/dev/null)
#      echo "\$1$SEP\$hash"
#    " _
    log "1"

    if false; then
        origin_git log --pretty=format:%H,%ct --name-only --no-renames --diff-filter=AM "$commit" | awk -F, -v OFS="$SEP" '
  /^[0-9a-f]{40},[0-9]*$/ {commit=$1; cts=$2; next}
  NF && !seen[$0] {seen[$0]=commit; print $0,commit,cts}
'
    elif true; then
        origin_git log --pretty=format:"%H,%ct" --name-status --no-renames "$commit" | awk -F, -v OFS="$SEP" '
            /^[^ ]{40},.*$/ {commit=$1;cts=$2;next}
            NF {
                file = substr($0, 3)
                if (!(file in seen)) {
                    seen[file] = 1
                    if (substr($0, 1, 1) != "D") {
                        print file,commit,cts
                    }
                }
            }
    '
    elif true; then
        tmp_file="/tmp/kmt_existing_files.txt.$$"
        origin_git ls-tree -r --name-only "$commit" | sort > "$tmp_file"
        if true; then
            origin_git log --pretty=format:%H,%ct --name-only --no-renames --diff-filter=AM "$commit" | awk -F, -v OFS="$SEP" '
  /^[0-9a-f]{40},[0-9]*$/ {commit=$1; cts=$2; next}
  NF && !seen[$0] {seen[$0]=commit; print $0,commit,cts}
' | sort | join -t "$SEP" - "$tmp_file"
        else
            origin_git log --pretty=format:%H,%ct --name-only --no-renames --diff-filter=AM "$commit" | awk -F, -v OFS="$SEP" -v tmp="$tmp_file" '
    BEGIN {
      while (getline < tmp) {
        existing[$0] = 1
      }
    }
  /^[0-9a-f]{40},[0-9]*$/ {commit=$1; cts=$2; next}
  NF && !seen[$0] && existing[$0] {seen[$0]=commit; print $0,commit,cts}
'
        fi
        rm -f "$tmp_file"
    fi

    log "2"
}

# ---------------------------------------------------------------------------
# Notes helpers
# ---------------------------------------------------------------------------

note_show()
{
    commit=$1

    origin_git notes --ref="$NOTE_REF" show "$commit" 2>/dev/null
}

note_add_file()
{
    commit=$1
    note_file=$2
    origin_git notes --ref="$NOTE_REF" add -f -F "$note_file" "$commit"
}

note_remove()
{
    commit=$1
    ! origin_git notes --ref="$NOTE_REF" remove "$commit" >/dev/null 2>&1 && return 1

    return 0
}

# ---------------------------------------------------------------------------
# Path and mtime note processing
# ---------------------------------------------------------------------------

note_get_mtime()
{
    wanted=$1
    commit=$2

    [ -z "$commit" ] && commit=$(last_commit_for_file "$wanted" "$commit")

    ! line=$(note_show "$commit" | grep -m 1 -F "$STX$wanted$SEP") && return 1

    echo "$line" | cut -d "$SEP" -f 2

    return 0
}

stage_get_mtime()
{
    wanted=$1

    head_commit=$(current_head)

    stage_file=$(get_note_file "$head_commit" "stage")

    [ ! -f "$stage_file" ] && return 1

    ! line=$(grep -m 1 -F "$wanted$SEP" "$stage_file") && return 1

    echo "$line" | cut -d "$SEP" -f 2

    return 0
}

valid_note_line()
{
    path=$1
    ts=$2
    [ -n "$path" ] || return 1
    is_timestamp "$ts"
}

batch_stat()
{
    cd "$REPO_ROOT" || return 1

    if [ "$PLATFORM" = 'linux' ]; then
        xargs -0 -L 100 stat -c "$STX%n$SEP%Y"
    else
        xargs -0 -L 100 stat -f "$STX%N$SEP%m"
    fi
}

#param #1 is the git status before an add operation, use it to check if an staged file was re-add or not, when re-add,
#refresh the mtime by stat

refresh_stage_note()
{
    before=$1
    after=$(origin_git status --short | grep '^[AM]. ')

    head_commit=$(current_head)

    stage_file=$(get_note_file "$head_commit" "stage")

    if [ -z "$after" ]; then
        [ -f "$stage_file" ] && rm -f "$stage_file"
        return 0
    fi

    [ -f "$stage_file" ] && stage_file_exists=1 || stage_file_exists=

    new_stage_file="$stage_file.$$"

    [ -f "$new_stage_file" ] && rm -f "$new_stage_file"

    log "before:
$before"
    log "after:
$after"

    echo "$after" | while IFS= read -r line
    do
        after_flag=$(echo "$line"| cut -c 2-2)
        file=$(echo "$line"| cut -c 4-)
#        log "wf: $w_flag, file: $file"
        if [ -n "$before" ] && [ "$after_flag" = ' ' ] &&
           ( echo "$before" | grep -F "M $file" | cut -c 4- | grep -Fxq "$file" || \
             echo "$before" | grep -F "? $file" | cut -c 4- | grep -Fxq "$file" ); then
            # working_area '[AM]' -> ' ', even in stage file or not, add it
            log "add-mtime: $file"
            echo "$file"
        elif [ -n "$stage_file_exists" ] && line=$(grep -m 1 -F "$file$SEP" "$stage_file"); then
            # mtime info already in stage file, reuse it
            log "keep-mtime: $file"
            echo "$line" >> "$new_stage_file"
        else
            # file in stash, but no mtime added before, complete it
            log "missing-mtime: $file"
            echo "$file"
        fi
    done |
    while IFS= read -r line
    do
        printf "%s\0" "$line";
    done | batch_stat | sort >> "$new_stage_file"

    ! mv -f "$new_stage_file" "$stage_file" && return 1

#    cat "$stage_file"

    return 0
}

show_stage_note()
{
    commit=$(commit_parse "${1:-HEAD}")

    stage_file=$(get_note_file "$commit" "stage")

#    refresh_stage_note "$commit"

    [ ! -f "$stage_file" ] && echo "no stage.">&2 && return 1

    cat "$stage_file"

    return 0
}

preview_fs_note()
{
    origin_git ls-tree -r --full-tree --name-only "${1:-HEAD}" -z | batch_stat
}

get_committed_files()
{
    commit=${1:-HEAD}
    origin_git diff-tree --diff-filter=ACMRT --no-commit-id --name-only -r -M "$commit"
}

# Build notes for an already-created commit.  diff-tree is used because it
# describes the commit itself instead of the current index/working tree.
# This is intentionally a post-commit operation.

stat_completable_files()
{
    commit=${1:-HEAD}

    log "build_note start $commit"

    ! str=$(get_committed_files "$commit") && echo "diff-tree failed" && return 1

    [ -z "$str" ] && return 0

    log "files: $str"

    if ! exists_files=$(echo "$str" |
              while IFS= read -r file
              do
                  [ -e "$file" ] && printf "%s\0" "$file"
              done |
                  batch_stat); then
        echo "stat failed"
        return 1
    fi

    log "exists_files: $exists_files"

    [ -z "$exists_files" ] && return 0

    #if fs-mtime later than commit-time, means the real mtime missing, skip it
    ! commit_ts=$(get_commit_time "$commit") && echo "get commit time failed" && return 1

    log "commit_ts: $commit_ts"

    echo "$exists_files" | awk -F"$SEP" -v OFS="$SEP" -v cts="$commit_ts" '{
                  if($2!="" && $2<=cts){
                      print $1,$2
                  }
              }' | LC_ALL=C sort

    log "build_note end"

    return 0
}

gen_full_note_commit_by_commit()
{
    commit=$1

    prev_commits="$2"

    full_note_result="$(get_note_file "$commit" "full").$$"

    echo "$prev_commits" | while IFS="," read -r prev_commit prev_commit_ts;
    do
        log "deal: $prev_commit" >&2

        full_note_file=$(get_note_file "$prev_commit" "full")
        if [ -f "$full_note_file" ]; then
            log "got $full_note_file" >&2
            if [ -s "$full_note_result" ]; then
                echo "join $full_note_file" >&2

                #join FILE,PRE_NOTE_TS,PRE_COMMIT,CUR_NOTE_TS,COMMIT_TS
                if ! str=$(LC_ALL=C join -t "$SEP" -a1 -a2 -o 0,1.2,1.3,2.2,2.3 "$full_note_file" "$full_note_result"); then
                    rm -f "$full_note_result"
                    echo "$str"
                    return 1
                fi

                echo "$str" | awk -F"$SEP" -v OFS="$SEP" '{
                    if($5 != ""){
                        print $1,$4,$5
                    }
                    else{
                        print $1,$2,$3
                    }
                }' >"$full_note_result"

            else
                log "cp $full_note_file"
                ! cp "$full_note_file" "$full_note_result" && return 1
            fi
            break
        fi

        if ! commit_note=$(note_show "$prev_commit"); then
            ! str=$(get_committed_files "$prev_commit") && echo "diff-tree failed" && return 1
            commit_note=$(echo "$str" | while IFS= read -r file; do
                    echo "$file$SEP$SEP$prev_commit_ts"
                done | LC_ALL=C sort)
        fi

        if [ -s "$full_note_result" ]; then
            echo "join: $prev_commit" >&2
            #join FILE,PRE_NOTE_TS,CUR_NOTE_TS,COMMIT_TS
            if ! str=$(echo "$commit_note"|LC_ALL=C join -t "$SEP" -a1 -a2 -o 0,1.2,2.2,2.3 - "$full_note_result"); then
                rm -f "$full_note_result"
                echo "$str"
                return 1
            fi

            echo "$str" | awk -F"$SEP" -v OFS="$SEP" -v ct="$prev_commit_ts" '{
                if($4 != ""){
                    print $1,$3,$4
                }
                else{
                    print $1,$2,ct
                }
            }' >"$full_note_result"
        else
#            log "output: $prev_commit" >&2
            echo "$commit_note" | awk -F"$SEP" -v OFS="$SEP" -v ct="$prev_commit_ts" '{
                print $1,$2,ct
            }'>"$full_note_result"
        fi
    done

    cat "$full_note_result" && rm -f "$full_note_result"

    return 0
}

preview_full_note()
{
    commit=$(commit_parse "${1:-HEAD}")

    prev_commits=$(origin_git log --pretty=format:"%H,%ct" "$commit")
    [ -n "$prev_commits" ] && while IFS="," read -r prev_commit prev_commit_ts
        do
            full_note_file=$(get_note_file "$prev_commit" "full")
            if [ -f "$full_note_file" ]; then
                if ! gen_full_note_commit_by_commit "$commit" "$prev_commits"; then
                    echo "generate failed"
                    return 1
                fi

                log "gen for $commit ok" >&2
                return 0
            fi
        done << EOF
$prev_commits
EOF

    log "by files"
    ! gen_full_note_file_by_file "$commit" && return 1
    return 0
}

gen_full_note_file_by_file()
{
    commit=$1

    log "build full note file-by-file ... $commit"

    [ -z "$commit" ] && echo "no commit hash" && return 1

    ! str=$(last_commit_for_files "$commit") && return 1

    [ -n "$str" ] && echo "$str" | while IFS="$SEP" read -r file last_commit commit_ts
    do
        if [ -z "$last_commit" ]; then
            log "no commit $file, $last_commit, $commit_ts"
            continue
        fi

        if ! note_ts=$(note_get_mtime "$file" "$last_commit"); then
            note_ts=""
        fi

        echo "$STX$file$SEP$note_ts$SEP$commit_ts"

    done | LC_ALL=C sort

    return 0
}

show_full_note()
{
    commit=$1
    [ -z "$commit" ] && commit=$(current_head)

    note_file=$(get_note_file "$commit" "full")
    if [ ! -f "$note_file" ]; then
        echo "full-index-note not exists" >&2
        return 1
    fi

    cat "$note_file"
    return 0
}

refresh_later_full_notes()
{
    start="$1"
    end=${2:-HEAD}

    [ -z "$start" ] || [ -z "$end" ] && return 1

    later_commits=$(origin_git log --pretty=format:"%H" --reverse "$start".."$end")

    echo "$later_commits" | while read -r later_commit;
    do
        full_note_file=$(get_note_file "$later_commit" "full")
        [ ! -f "$full_note_file" ] && continue

        log "deal with: $later_commit"

        ! str_old=$(show_full_note "$later_commit") && continue

        str_new=$(preview_full_note "$later_commit")

        [ "$str_old" = "$str_new" ] && echo "same full note $later_commit" && break

        log "update $later_commit"

        echo "$str_new" > "$full_note_file"

    done
}

update_all_commit_notes()
{
    commit=${1:-HEAD}
    prev_commits=$(origin_git log --pretty=format:"%H" "$commit")

    origin_git log --pretty=format:"%H" "$commit" | while read -r prev_commit
    do
#        echo "commit: $prev_commit"
        ! str=$(note_show "$prev_commit" 2>/dev/null) && continue

        [ -z "$str" ] && continue

        updated=0
        while IFS="$SEP" read -r file ts
        do
            echo "$file" | grep -F "$STX" && updated=1 && break

            if [ -z "$ts" ]; then
                new=$(echo "$file" | sed "s/,/$SEP/;s/\|/$SEP/")
                IFS="$SEP" read -r file ts << EOF
$new
EOF
            fi
            echo "$STX$file$SEP$ts"
        done > "/tmp/update-note.$$" <<EOF
$str
EOF

        [ "$updated" = 1 ] && echo "skip: $prev_commit" && continue

        echo "updated: $prev_commit"

#        cat "/tmp/update-note.$$"

        ! note_add_file "$prev_commit" /tmp/update-note.$$ && return 1
        rm -f /tmp/update-note.$$
    done

    return 0
}

complete_head_note()
{
    pre_commit=$1

    status_files=$(origin_git status --short --untracked-files=no | cut -c 4-)
    [ -n "$status_files" ] && echo "head commit modified" && return 1

    if [ -z "$pre_commit" ]; then
        ! pre_commit=$(commit_parse HEAD~1) && return 1
        [ -z "$pre_commit" ] && return 1
    fi

    pre_stage_file=$(get_note_file "$pre_commit" "stage")

    if ! [ -f "$pre_stage_file" ]; then
        ! note=$(stat_completable_files "HEAD") && echo "$note" && return 1

        [ -z "$note" ] && echo "prev result is empty HEAD" && return 1

        echo "$note" > "$pre_stage_file"
    fi

    if ! note_add_file "HEAD" "$pre_stage_file"; then
        echo "add head note failed: $pre_stage_file"
        return 1
    fi

    while IFS="$SEP" read -r file note_ts
    do
        path="$REPO_ROOT/$file"
        file_ts=$(get_file_mtime "$path")
        if [ "$file_ts" -lt "$note_ts" ]; then
            set_file_mtime "$path" "$note_ts"
            echo "$path, $(format_timestamp "$file_ts"), $(format_timestamp "$note_ts")"
        fi
    done < "$pre_stage_file"

    return 0
}

complete_history_note()
{
    commit=${1:-HEAD}

    if is_head "$commit"; then
        echo "complete head $commit"
        ! complete_head_note && return 1
        return 0
    fi

    ! note=$(stat_completable_files "$commit") &&
        echo "$note" &&
        echo "build note failed" &&
        return 1

    [ -z "$note" ] && echo "preview result is empty $commit" && return 0

    ! note_file=$(mktemp "${TMPDIR:-/tmp}/git-kmt-diff.XXXXXX") &&
        echo "mktemp failed" &&
        return 1

    echo "$note" > "$note_file"

    if ! note_add_file "$commit" "$note_file"; then
        echo "add note failed: $commit, $note_file"
        rm -f "$note_file"
        return 1
    fi

    rm -f "$note"

    echo "note_add_file ok"

    ! refresh_later_full_notes "$commit" && echo "Failed to refresh later notes" && return 1

    echo "refresh_later_full_notes ok"

    return 0
}

merge_full_note()
{
    main=$1
    delta=$2
    commit=$3

    ! commit_ts=$(get_commit_time "$commit") && return 1

    ! LC_ALL=C join -t "$SEP" -a1 -a2 -e '' -o 0,1.2,1.3,2.2 "$main" "$delta" |
      awk -F"$SEP" -v OFS="$SEP" -v ct="$commit_ts" '
      {
          print $1,$4?$4:$2,$4?ct:$3
      }
      ' && return 1

    return 0
}

# ---------------------------------------------------------------------------
# Synchronization
# ---------------------------------------------------------------------------

#$1 path to root
#$2  timestamp to set
synchronize_file()
{
    p2r=$1
    ts=$2

    path="$REPO_ROOT/$p2r"

    ! [ -e "$path" ] && return 0

    file_ts=$(get_file_mtime "$path") || return 1

    [ "$file_ts" = "$ts" ] && return 0

    ! set_file_mtime "$path" "$ts" &&
        echo "failed to synchronize mtime '$p2r'" &&
        return 1

    echo "Synchronized mtime $(format_timestamp "$ts") '$p2r'"

    return 0
}

synchronize_commit()
{
    commit=$1

    if ! note=$(note_show "$commit"); then
        echo "$note" | grep 'not found' && return 0
    fi

    [ -z "$note" ] && return 1

    count=0
    failed=0
    while IFS="$SEP" read -r path ts rest; do
        [ -n "$rest" ] && continue
        valid_note_line "$path" "$ts" || continue
        if synchronize_file "$path" "$ts"; then
            count=$((count + 1))
        else
            failed=$((failed + 1))
        fi
    done <<EOF2
$note
EOF2

    log "Synchronized $count files; failed: $failed."
    [ "$failed" -eq 0 ]
}

synchronize_head()
{
    commit=$(current_head) || return 1
    synchronize_commit "$commit"
}

# ---------------------------------------------------------------------------
# Commit / post-commit
# ---------------------------------------------------------------------------

get_note_file()
{
    commit=$1
    cate=$2

    if [ ! -e "$GIT_DIR/kmt/" ]; then
        ! mkdir -p "$GIT_DIR/kmt/" && echo "mk kmt dir failed" && return 1
    fi

    echo "$GIT_DIR/kmt/$commit.$cate.note"

    return 0
}

post_add()
{
    addable_files=$1

    ! refresh_stage_note "$addable_files" && return 1

    return 0
}

post_commit()
{
    pre_commit=$1

    ! complete_head_note "$pre_commit" && return 1

    cur_commit=$(current_head)
    pre_stage_note_file="$(get_note_file "$pre_commit" "stage")"
    pre_full_note=$(get_note_file "$pre_commit" "full")
    cur_full_note=$(get_note_file "$cur_commit" "full")
    if [ -f "$pre_full_note" ] && [ -f "$pre_stage_note_file" ]; then
        ! merge_full_note "$pre_full_note" "$pre_stage_note_file" "$cur_commit" > "$cur_full_note" && echo "merge full note failed" && return 1
        rm -f "$pre_full_note"
        rm -f "$pre_stage_note_file"
    else
        [ -f "$pre_stage_note_file" ] && rm -f "$pre_stage_note_file"

        log "build full note for $cur_commit ..."

        if ! preview_full_note "$cur_commit" > "$cur_full_note"; then
            echo "build full note for $cur_commit failed"
            return 1
        fi

        set_file_mtime "$cur_full_note" "$(get_commit_time "$cur_commit")"

        log "build full note for $cur_commit ok"
    fi

    return 0
}

post_revert()
{
    OLD=$1
    shift

    head_commit=$(current_head)
    if [ "$OLD" = "$head_commit" ]; then
        if select_arg "--abort" "$@"; then
            ehco "rever abort"
        fi

        ! refresh_stage_note && return 1
    else
        #....
        #update mtime for revert files
        #....

        ! post_commit && return 1
    fi

    return 0
}

on_head_moved()
{
    OLD=$1

    ! refresh_stage_note && return 1

    # the un-committed(modified and staged) files should exclude from restore list
    # minus=$(sort a b | uniq)
    status_files=$(origin_git status --short --untracked-files=no | cut -c 4-)

    full_note=$(get_note_file "$(current_head)" "full")

    if [ -f "$full_note" ]; then
        log "restore mtime for each file by full note $full_note"

        ! preview_fs_note "HEAD" |
            LC_ALL=C sort |
                LC_ALL=C join -t "$SEP" -e '' -o 1.1,1.2,2.2,2.3 - "$full_note" |
                    awk -F"$SEP" -v OFS="$SEP" '
                    {
                        if ($2 != $3) {
                            print substr($1,2),$3,$4
                        }
                    }
                    ' |
                    while IFS="$SEP" read -r file note_ts last_commit
                    do
                        ! [ -e "$REPO_ROOT/$file" ] && echo "file not exists $file" && continue

                        [ -n "$status_files" ] && echo "$status_files" | grep -F "$file" && echo "skip $file" && continue

                        [ -z "$note_ts" ] && note_ts=$(get_commit_time "$last_commit")

                        set_file_mtime "$REPO_ROOT/$file" "$note_ts"

                        log "synchronize: $(format_timestamp "$note_ts") $file, $note_ts"
                    done
    else
        log "restore mtime for each file"

        last_commit_for_files "HEAD" | while IFS="$SEP" read -r file commit commit_ts
        do
            ! [ -e "$REPO_ROOT/$file" ] && echo "file not exists $file" && continue

            [ -n "$status_files" ] && echo "$status_files" | grep -F "$file" && echo "skip $file" && continue

            note_ts=$(note_get_mtime "$file" "$commit")

            [ -z "$note_ts" ] && note_ts="$commit_ts"

            set_file_mtime "$REPO_ROOT/$file" "$note_ts"
            log "synchronize: $(format_timestamp "$note_ts") $file, $note_ts"
        done
#        ! synchronize_range "$OLD" "HEAD" && return 1
    fi

    return 0
}

post_push ()
{
    ! origin_git push \
                origin \
                "refs/notes/$NOTE_REF:refs/notes/$NOTE_REF" && return 1 || return 0
}

post_pull()
{
    ! origin_git fetch \
        origin \
        "+refs/notes/$NOTE_REF:refs/notes/$NOTE_REF" && return 1 || return 0
}

current_head()
{
    commit_parse HEAD
}

current_branch()
{
    origin_git branch --show-current
}

synchronize_range()
{
    from_commit=$1
    to_commit=$2

    echo "synchronize_range $from_commit to $to_commit"

    if [ "$from_commit" = "$to_commit" ]; then
        commits="$to_commit"
    else
        commits=$(origin_git log --pretty=format:"%H" --reverse "$from_commit".."$to_commit")
    fi

    echo "$commits" | while read -r cmt
    do
        log "synchronize $cmt ..."
        ! synchronize_commit "$cmt" && echo "synchronize $cmt failed." && return 1
        log "synchronize $cmt ok."
    done

    return 0
}

# ---------------------------------------------------------------------------
# Checkout / restore / pull/update handlers
# ---------------------------------------------------------------------------

git_command_handler()
{
#    log "git_command_handler $*"

    cmd=$(select_git_command "$@")

    [ -z "$cmd" ] && return 1

    need_sync=
    case "$cmd" in
        pull)
            need_sync=1
            ;;
        add)
            #also can get the added files by the outputs as the following two commands
            #git diff --name-only
            #git diff --name-only --staged
            addable_files=$(origin_git status --short --untracked-files=no | grep '^.[?M] ')
            ;;
        commit|merge)
            pre_commit=$(current_head)
            ;;
        reset)
            ;;
    esac

    OLD=$(current_head 2>/dev/null)

#    [ "$need_sync" = 1 ] &&  || OLD=

    log "git cmd: $cmd"

    origin_git "$@" || return $?

    case "$cmd" in
        add)
            log "post add ..."
            ! post_add "$addable_files" && echo "add succeeded but timestamp note creation failed." && return 1
            log "KMT: mtime added."
            ;;
        commit)
            log "post commit ..."

            ! post_commit "$pre_commit" && echo "commit succeeded but timestamp note creation failed." && return 1

            log "KMT: notes added."
            ;;
        merge)
            log "post merge ..."
            # merge creates a new commit in the usual non-ff case.  If it did, create
            # its note; afterwards synchronize the resulting HEAD.

            ! post_commit "$pre_commit" && echo "commit succeeded but timestamp note creation failed." && return 1

            log "KMT: notes added."
            ;;
        restore)
            if select_arg "--staged" "$@"; then
                # in this case( with --staged), the file just moved out from the stash, but not restore the file content.
                # and commit not changed, so do not restore the mtime, just refresh the stage note.
                ! refresh_stage_note && return 1
                return 0
            fi

            if source=$(select_arg "--source" "$@"); then
                log "source: $source"
                files=$(select_args "--source=$source" "$@")
            else
                source=
                files=$(select_args "restore" "$@")
            fi

            log "$source, $files"

            [ -n "$files" ] && while IFS= read -r path;
            do
                [ -e "$path" ] || continue

                if stage_ts=$(stage_get_mtime "$SUB_DIR$path") && [ -n "$stage_ts" ]; then
                    note_ts="$stage_ts"
                    echo "restore from stage: $stage_ts"
                else
                    note_ts=$(note_get_mtime "$SUB_DIR$path" "$source")
                    echo "restore from source: $source, $note_ts"
                fi

                [ -z "$note_ts" ] && continue

                synchronize_file "$SUB_DIR$path" "$note_ts"
            done << EOF
$files
EOF

            ;;
        checkout)
            target=$(select_arg "checkout" "$@")
            [ -z "$target" ] && echo "unknown branch" && return 1

            if select_arg "--" "$@" > /dev/null; then
                files=$(select_args "--" "$@")
            else
                files=$(select_args "$target" "$@")
            fi

            if [ "$(current_head)" != "$OLD" ]; then
                echo "checkout from $OLD to $(current_head)"
                ! on_head_moved "$OLD" && return 1
            elif [ -n "$files" ]; then
                while IFS= read -r path;
                do
                    [ -e "$path" ] || continue

                    if ! note_ts=$(note_get_mtime "$SUB_DIR$path" "$target") || [ -z "$note_ts" ]; then
                        note_ts=$(get_commit_time "$target")
                    fi

                    [ -z "$note_ts" ] && continue

                    log "$target: $files, $note_ts"
                    synchronize_file "$SUB_DIR$path" "$note_ts"
                done << EOF
$files
EOF
                return 0
            fi
            ;;
        switch)
            if [ "$(current_head)" != "$OLD" ]; then
                ! on_head_moved "$OLD" && return 1
            fi
            return 0
            ;;
        reset)
            if select_arg "--hard" "$@" && [ "$(current_head)" != "$OLD" ]; then
                ! on_head_moved "$OLD" && return 1
            fi
            ;;
        revert)
            ! post_revert "$OLD" "$@" && return 1
            return 0
            ;;
        push)
            log "post push ..."

            ! post_push && echo "Git push succeeded but timestamp note push failed." && return 1

            echo "KMT: notes pushed."
            ;;
        pull)
            log "post pull ..."

            ! post_pull && echo "Git pull succeeded but timestamp note fetch failed." && return 1

            echo "KMT: notes fetched."
            ;;
    esac

    if [ "$need_sync" = "1" ]; then
        [ "$cmd" = "reset" ] && OLD=HEAD
        ! synchronize_range "$OLD" HEAD && return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# kmt-complete
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Maintenance / inspection commands
# ---------------------------------------------------------------------------

show_commit_note()
{
    ! commit=$(commit_parse "${1:-HEAD}") && echo "get commit-id failed $1" && return 1

    ! note_show "$commit" &&  return 1

    return 0
}

show_history()
{
    path=$1
    commit=${2:-HEAD}

    [ -z "$path" ] && echo "history requires a file path" && return 1
#    echo "===== mtime history: $path ====="
    ! prev_commits=$(origin_git log --format='%H%x09%cI' --follow "$commit" -- "$path") && return 1

    [ -z "$prev_commits" ] && echo "no history" && return 0

    echo "$prev_commits" |
        while IFS="$TAB" read -r commit date; do
            note_ts=$(note_get_mtime "$SUB_DIR$path" "$commit")
            if [ -n "$note_ts" ]; then
                printf '%s | %s | %s | %s\n' "$commit" "$date" "$note_ts" "$(format_timestamp "$note_ts")"
            else
                printf '%s | %s | %10s | %s\n' "$commit" "$date" "$note_ts" "$(format_timestamp "$note_ts")"
            fi
        done
}

push_notes()
{
    remote=${1:-origin}
    branch=${2:-refs/notes/$NOTE_REF}
    echo "Pushing KMT notes to $remote ($branch)..."
    origin_git push "$remote" "refs/notes/$NOTE_REF:$branch"
}

fetch_notes()
{
    remote=${1:-origin}
    branch=${2:-refs/notes/$NOTE_REF}
    echo "Fetching KMT notes from $remote ($branch)..."
    origin_git fetch "$remote" "$branch:refs/notes/$NOTE_REF"
}

sync_notes()
{
    remote=${1:-origin}
    fetch_notes "$remote" || return 1

    synchronize_head
}

# ---------------------------------------------------------------------------
# KMT command UI / command handler
# ---------------------------------------------------------------------------

init_path()
{
    CUR_DIR=$(pwd)
    REPO_ROOT=$(repo_root)
    GIT_DIR=$(repo_git_dir)
    [ "$REPO_ROOT" = "$CUR_DIR" ] && SUB_DIR= || SUB_DIR=${CUR_DIR#*"$REPO_ROOT/"}/
}

select_git_command()
{
#    log "all: $*"
    cmd=
    opt_key=
    for p in "$@"
    do
        [ "-c" = "$p" ] && opt_key="$p" && continue

        [ -n "$opt_key" ] && opt_key= && continue

        cmd="$p"

        break
    done

    [ -z "$cmd" ] && cmd="$1"

    echo "$cmd"

    return 0
}

select_checkout_files()
{
    opt_key=
    for p in "$@"
    do
        [ "--" = "$p" ] && opt_key="paths" && continue

        [ -n "$opt_key" ] && echo "$p"
    done

    [ -z "$opt_key" ] && return 1

    return 0
}

show_note()
{
    while IFS="$SEP" read -r file ts commit
    do
        echo "$file,$ts,$(format_timestamp "$ts"),$commit"
    done
    return 0
}


kmt_note_ui()
{
    alias=${1:-HEAD}

    commit=$(commit_parse "$alias")

    [ "$alias" = "$commit" ] && alias=

    key=

    while true
    do
        if [ -z "$key" ]; then
            note_show "$commit" > /dev/null && note_exists=1 || note_exists=0
            full_note_file=$(get_note_file "$commit" "full") &&
                [ -f "$full_note_file" ] && full_note_exists=1 || full_note_exists=0

            cat << EOF

Select an operation:

commit: $commit$([ -n "$alias" ] && echo "($alias)")
commit date: $(format_timestamp "$(get_commit_time "$commit")")

  -- Commit Note --

    1   -- List commit-note$([ "$note_exists" = "0" ] && echo " (NOT EXISTS)")
    2   -- List full--note$([ "$full_note_exists" = "0" ] && echo " (NOT EXISTS)")

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

        case $key in
            1)
                str=$(show_commit_note "$@") &&
                    [ -n "$str" ] && echo "$str" | show_note||
                    echo "$str"
                ;;
            2)
                str=$(show_full_note "$@") &&
                    [ -n "$str" ] && echo "$str" | show_note||
                    echo "$str"
                ;;
            3)
                str=$(show_stage_note "$@") &&
                    [ -n "$str" ] && echo "$str" | show_note ||
                    echo "$str"
                ;;
            4)
                str=$(preview_fs_note "$commit") &&
                    [ -n "$str" ] && echo "$str" | show_note ||
                    echo "$str"
                ;;

            5)
                echo "Input a file to show history:"
                read -r file
                [ -z "$file" ] && key= && continue

                show_history "$file" "$commit"

                continue

                ;;

            6)
                str=$(stat_completable_files "$commit") &&
                    [ -n "$str" ] && echo "$str" | show_note ||
                    echo "$str"
                ;;
            7)
                ! complete_history_note "$commit" && return 1
                ;;

            8)
                str=$(preview_full_note "$commit") &&
                    [ -n "$str" ] && echo "$str" | show_note ||
                    echo "$str"
                ;;
            9)
                full_note_file=$(get_note_file "$commit" "full")

                [ -f "$full_note_file" ] && rm -f "$full_note_file"

                if ! str=$(preview_full_note "$commit"); then
                    echo "build full note for $commit failed"
                    echo "$str"
                    return 1
                fi

                echo "$str" > "$full_note_file"

                set_file_mtime "$full_note_file" "$(get_commit_time "$commit")"
                ;;
            10)
                update_all_commit_notes "HEAD"
                ;;
            *)
                return 0
                ;;
        esac

        echo "done."
        read -r key
    done

    return 0
}


app_command_handler()
{
    cmd=$(select_git_command "$@")

#    log "cmd: $cmd"

    case "$cmd" in
        -h|--help|help)
            if [ "$2" = 'kmt' ]; then
                show_help
            else
                origin_git "$@"
            fi
            ;;
        add|commit|merge|restore|revert|reset|rebase|switch|checkout|pull|push)
            init_path
            git_command_handler "$@"
            ;;
        kmt-note)
            shift
            init_path
            kmt_note_ui "$@"
            ;;
        *)
            origin_git "$@"
            ;;
    esac

    return $?
}

app_is_working_copy()
{

    return 0
}

app_is_update_to_date()
{
    init_path

    return 0
}

app_get_files_2_commit()
{
    #check working copy
    str=$(origin_git diff --name-only --relative -- .)
    [ -n "$str" ] && echo "$str" && return 0

    #check added to stage but not committed files
    str=$(origin_git status --short | grep "^[^?].*" |cut -c 4-)
    [ -n "$str" ] && echo "$str" && return 0

    #check not pushed commits
#    ! branch=$(git branch --show-current) && return 1
#    unpushed_commits=$(origin_git log --oneline origin/"$branch".."$branch")
#    [ -n "$unpushed_commits" ] && echo "There has some commits not pushed to repo as follows:" && echo "$unpushed_commits" && return 1

    return 0
}

app_get_remote_url()
{
    origin_git remote -v | grep -m 1 -oE 'http[s]?://[^/]*'
}

app_kmt_list()
{
    ! str=$(origin_git ls-files) && echo "$str" && return 1

    [ -n "$str" ] && while IFS= read -r path
    do
#            echo "path: $path"
        fpath="$CUR_DIR/$path"

        ! [ -e "$fpath" ] && echo "file not exists: $fpath" && return 1

        ! file_ts=$(get_file_mtime "$fpath") && echo "$file_ts" && return 1

#        echo "$path, $file_ts" && return 1
        ! commit=$(last_commit_for_file "$path")  && echo "$commit" && return 1

        [ -z "$commit" ] && return 1

        note_ts="$(note_get_mtime "$SUB_DIR$path" "$commit")"

#        echo "$SUB_DIR$path, $commit, $note_ts" && return 1

        if [ -z "$note_ts" ]; then
            ! version_ts=$(get_commit_time "$commit") || [ -z "$version_ts" ] && echo "Get versioned timestamp failed: '$path'" && return 0
        fi

        echo "$path$SEP$file_ts$SEP$note_ts$SEP$version_ts"

    done << EOF
$str
EOF
    return 0
}

app_save_file_mtime()
{
    file=$1

    [ -z "$file" ] && return 1

    file_ts=$2

    [ -z "$file_ts" ] && return 1

    now_ts=$(date +%s)
    if [ "$file_ts" -gt "$now_ts" ]; then
        echo "The file mtime can not be committed, because it is in the future. $(format_timestamp "$file_ts") $file"
        return 2
    fi

    ! commit=$(last_commit_for_file "$file") || [ -z "$commit" ] && echo "$commit" && echo "get commit failed $file" && return 1

    if show_commit_note "$commit" > /dev/null; then
        note_ts=$(note_get_mtime "$SUB_DIR$file" "$commit")
        if [ "$file_ts" = "$note_ts" ]; then
            log "mtime exists in note, $file, $file_ts"
            return 0
        else
            echo "file:$file, note ts: $note_ts, file_ts, $file_ts"
        fi
    fi

    ! complete_history_note "$commit" && echo "update commit note failed" && return 1

    return 0
}

app_is_later_then_last_2nd_commit()
{
    echo '0'
    return 0
}

app_on_kmt_completed()
{
#    ! origin_git push && echo "push commit failed." && return 1
#
#    ! post_push && echo "push notes failed." && return 1

    return 0
}

app_on_kmt_resolved()
{
    return 0
}

main "$@"
