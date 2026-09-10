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
#      0.1.3
#
#  Storage model:
#      git notes --ref=kmt/mtime <commit>
#
#  Note format:
#      <STX>path<ETX>unix_mtime
#
# ============================================================================

APP='git'
APP_KMT='git_kmt'
KMT_FULL_NAME='Git Keep MTime'
KMT_VERSION='0.1.3'

META_NAME="mtime-notes"

NOTE_REF="kmt/mtime"

STX=$(printf '\x02')
ETX=$(printf '\x03')

CUR_DIR=$(pwd)
REPO_ROOT=
GIT_DIR=
SUB_DIR=
IS_LOOK_INSTALLED=0


##############################################################################
# Utility
##############################################################################

PLATFORM=""

KMT_DEBUG_LOG_FILE=

TZ_SECONDS=

last_log_ts=
logging=

log()
{
    log_ret=$?

    [ -z "$KMT_DEBUG_LOG_FILE" ] && return $log_ret

    [ "$logging" = "1" ] && return $log_ret

    logging=1

    if [ -n "$last_log_ts" ]; then
        tsd=$(float_diff "$(date +%s.%N)" "$last_log_ts")
    else
        tsd=$(format_timestamp "$(date +%s)")
    fi

    case "$KMT_DEBUG_LOG_FILE" in
        "&1")
            echo "[ $$ + $tsd] $*"
            ;;
        "&2")
            echo "[ $$ + $tsd] $*" >&2
            ;;
        *)
            echo "[ $$ + $tsd] $*" >> "$KMT_DEBUG_LOG_FILE"
            ;;
    esac

    last_log_ts=$(date +%s.%N)

    logging=0

    return $log_ret
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
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
#    echo "$1" | grep -Eq '^[0-9]+$'
}

format_timestamp()
{
    fast_format_timestamp "$@"
    echo "$TM_RET"
}

fast_format_timestamp() {
    ts=$1
    TM_RET=
    [ -z "$1" ] && return 1
    [ -z "$TZ_SECONDS" ] && detect_time_zone
    ts=$(($1 + ${2:-"$TZ_SECONDS"}))
    days=$((ts / 86400))
    sod=$((ts % 86400))

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

    TM_RET="${year}-${month}-${day} ${hour}:${minute}:${second}"
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
    file_to_set="$1"
    timestamp="$2"

    ! is_timestamp "$timestamp" && echo "invalid timestamp: $timestamp" && return 1

    case "$PLATFORM" in

        linux)

            touch -m -d "@$timestamp" "$file_to_set" || return 1

            ;;

        macos)

            touch -m \
                -t "$(date -r "$timestamp" "+%Y%m%d%H%M.%S")" \
                "$file_to_set" || return 1

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

grep_arg()
{
    key=$1
    shift
    for p in "$@";
    do
        echo "$p" | grep -E "$key" && return 0
    done
    return 1
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

#
# ============================================================================
#  KMT Note Library
#
#  Purpose:
#      Generic "path -> value" mapping stored in Git notes.
#      Does NOT know about mtime, timestamps, or file semantics.
#
#  Storage:
#      git notes --ref=<NOTE_REF> <commit>
#
#  Line format:
#      <STX>key<ETX>value
#
#  Requires (from caller):
#      NOTE_REF    - notes ref name (e.g. "kmt/mtime")
#      STX, ETX    - record separators
#      origin_git  - function to run the real git
#      IS_LOOK_INSTALLED - 0/1, whether `look` is available
#
# ============================================================================

# ---------------------------------------------------------------------------
# Single-record access
# ---------------------------------------------------------------------------

# note_show <commit>
#   Print the whole note for a commit. Returns non-zero if no note.
note_show()
{
    origin_git notes --ref="$NOTE_REF" show "$1" 2>/dev/null
}

# note_get <commit> <key>
#   Print the value for <key>. Returns non-zero if key not present.
note_get()
{
    _ng_commit=$1
    _ng_key=$2

    ! _ng_line=$(note_show "$_ng_commit" | grep -m 1 -F "$STX$_ng_key$ETX") && return 1

    echo "${_ng_line#*"$ETX"}"
    return 0
}

# note_get_or <commit> <key> <fallback-value>
#   Print value for <key>, or <fallback-value> if key missing or commit empty.
#   (Replaces original "use_commit_ts_when_failed" mode)
note_get_or()
{
    _ng_commit=$1
    _ng_key=$2
    _ng_fallback=$3

    if _ng_val=$(note_get "$_ng_commit" "$_ng_key"); then
        echo "$_ng_val"
        return 0
    fi

    echo "$_ng_fallback"
    return 0
}

# note_has <commit> <key>
#   Return 0 if key exists in the note.
note_has()
{
    note_show "$1" | grep -q -F "$STX$2$ETX"
}

# ---------------------------------------------------------------------------
# Whole-note access
# ---------------------------------------------------------------------------

# note_write <commit> <file>
#   Replace the entire note of <commit> with the contents of <file>.
note_write()
{
    origin_git notes --ref="$NOTE_REF" add -f -F "$2" "$1"
}

# note_remove <commit>
#   Delete the note for <commit>. Silent if not present.
note_remove()
{
    origin_git notes --ref="$NOTE_REF" remove "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Local note file helpers
#
#   Some notes are cached in local files (e.g. stage/full snapshots).
#   These functions operate on those files, not on Git notes.
# ---------------------------------------------------------------------------

# note_file_find <file> <key>
#   Find a record in a local note file. Uses `look` when available.
note_file_find()
{
    _nf_file=$1
    _nf_key=$2

    [ ! -f "$_nf_file" ] && return 1

    if [ "$IS_LOOK_INSTALLED" = "1" ]; then
        ! _nf_line=$(look -t "$ETX" "$_nf_key$ETX" "$_nf_file") && return 1
    else
        ! _nf_line=$(grep -m 1 -F "$_nf_key$ETX" "$_nf_file") && return 1
    fi

    echo "$_nf_line"
    return 0
}

# note_file_get <file> <key>
#   Print the value for <key> from a local note file.
note_file_get()
{
    ! _ngf_line=$(note_file_find "$1" "$2") && return 1
    _ngf_val=${_ngf_line#*"$ETX"}
    echo "${_ngf_val%%"$ETX"*}"
    return 0
}

# ---------------------------------------------------------------------------
# Line format helpers (for producers / consumers)
# ---------------------------------------------------------------------------

# note_line <key> <value>
#   Print one note line.
note_line()
{
    printf '%s%s%s%s\n' "$STX" "$1" "$ETX" "$2"
}

# note_line_delete <key>
#   Print one deletion marker line.
note_line_delete()
{
    printf '%s%s%sD\n' "$STX" "$1" "$ETX"
}

# note_parse <line>
#   Parse one line into NOTE_KEY / NOTE_VALUE.
note_parse()
{
    NOTE_KEY=
    NOTE_VALUE=

    case "$1" in
        "$STX"*"$ETX"*)
            NOTE_KEY=${1#"$STX"}
            NOTE_KEY=${NOTE_KEY%%"$ETX"*}
            NOTE_VALUE=${1#*"$ETX"}
            ;;
    esac
}

note_merge_with_delta()
{
    main_note=$1
    delta=$2
    commit_id=$3
    commit_ts=$4

    echo "$delta" | LC_ALL=C join -t "$ETX" -a1 -a2 -e '' -o 0,1.2,1.3,1.4,2.1,2.2 "$main_note" - |
        awk -F"$ETX" -v OFS="$ETX" -v ci="$commit_id" -v ct="$commit_ts" '
        {
            if($5 == "" && $1 != ""){
                print $1,$2,$3,$4
            }
            else if($5 != "" && $6 != "D"){
                print $5,$6,ci,ct
            }
        }
        '
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

detect_debug_log()
{
    [ -n "$KMT_DEBUG_LOG_FILE" ] && return 0

    if ! app_entry_path=$(find_command "$APP"); then
        echo "Original $APP executable not found."
        return 1
    fi

    kmt_debug_log="$(dirname "$app_entry_path")/kmt-debug-log"

    [ -f "$kmt_debug_log" ] && KMT_DEBUG_LOG_FILE=$(cat < "$kmt_debug_log")

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
    file_ts=$2
    prop_ts=$3
    version_ts=$4

    [ "$file" = '.' ] && return 0

    checked_count=$(( checked_count+1 ))

    [ -z "$file_ts" ] && echo "No file mtime provided: '$*'" && return 1

    if [ -n "$prop_ts" ]; then
        if [ "$file_ts" = "$prop_ts" ] || [ -d "$file" ]; then
            fast_format_timestamp "$file_ts"
            [ "$cmd" = "show_completed" ] && echo "Completed $TM_RET $file"
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
#                    now_ts=$(date +%s)
                    if [ "$file_ts" -gt "$now_ts" ]; then
                        echo "The file mtime can not be committed, because it is in the future. $(format_timestamp "$file_ts") $file"
                        return 2
                    fi
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
#                now_ts=$(date +%s)
                if [ "$file_ts" -gt "$now_ts" ]; then
                    echo "The file mtime can not be committed, because it is in the future. $(format_timestamp "$file_ts") $file"
                    return 2
                fi

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

    ! str=$(app_kmt_list "$@") && echo "$str" && echo "get kmt list failed" && return 1

    log "on scanned: $*"

    now_ts=$(date +%s)
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
    ! detect_debug_log && return 1

    dispatch "$@"
#    log "ret: $?"
#    return $?
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
    "$ORIGIN_APP" "$@" || log "ret: $?, params: '$*'"
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

git_rev_parse()
{
    origin_git rev-parse --verify "$1" 2>/dev/null
}

is_head()
{
    commit=${1}
    [ -z "$commit" ] && return 1

    if [ "$(git_rev_parse "$commit")" = "$(get_current_head)" ]; then
        return 0
    fi

    return 1
}

get_commit_time()
{
    origin_git show -s --format='%ct' "${1:-HEAD}"
}

last_commit_for_file()
{
    path="$1"
    to_commit="${2:-HEAD}"
    origin_git log -1 "$to_commit" --format='%H' -- "$path"
}

# Output: <STX>path<ETX>commit<ETX>commit_ts
# for every still-existing file, using its most recent A/M commit.
last_commit_for_files()
{
    origin_git log --pretty=format:"%H,%ct" --name-status --no-renames -z HEAD | tr '\0' '\n' |
        awk -F, -v OFS="$ETX" -v stx="$STX" '
            /^[0-9a-f]{40},[0-9]+$/ { commit=$1; ct=$2; next }
            /^[AMDR]$/ { status = $0; next }
            {
                if ($0!="" && !seen[$0]) {
                    seen[$0] = 1
                    if(status != "D"){
                        print stx $0,commit,ct
                    }
                }
                status = ""
            }
        '
    return $?
}

# ---------------------------------------------------------------------------
# Path and mtime note processing
# ---------------------------------------------------------------------------

# Look up the mtime of a file from a specific commit's note.
# If commit is empty, find the file's last commit first.
note_get_mtime()
{
    wanted=$1
    commit=$2

    [ -z "$commit" ] && commit=$(last_commit_for_file "$wanted" "$commit")

    note_get "$commit" "$wanted"
}

# Look up the mtime of a file from a local note file.
# Wrapper around note_file_get from note.sh (kept for legacy call sites).
note_get_mtime_ex()
{
    wanted=$1
    note_file=$2

    note_file_get "$note_file" "$wanted"
}

# Look up the mtime of a file in the current HEAD's stage note.
stage_get_mtime()
{
    wanted=$1

    ! head_commit=$(get_current_head) && return 1

    stage_file=$(get_note_file "$head_commit" "stage")

    [ ! -f "$stage_file" ] && return 1

    note_file_get "$stage_file" "$wanted"
}

valid_note_line()
{
    path=$1
    ts=$2
    [ -n "$path" ] || return 1
    is_timestamp "$ts"
}

batch_stat_ex()
{
    cd "$REPO_ROOT" || return 1

    if [ "$PLATFORM" = 'linux' ]; then
        xargs -0 -L 100 stat -c "$STX%n$ETX%Y"
    else
        xargs -0 -L 100 stat -f "$STX%N$ETX%m"
    fi
}

refresh_stage_note()
{
    modified_before=$1

    # The newly added files may be generated by the git add rm or rename,
    # the mtimes of them should be refreshed by stat(ed) values
    newly_added_files=
    if [ -n "$modified_before" ]; then
        newly_added_files=$(origin_git status --short -z| tr '\0' '\n' | grep '^[^ ]  ' | cut -c 4- |
            while read -r staged_file
            do
                echo "$modified_before" | grep -Fx "$staged_file"
            done)
        log "newly_added_files: $newly_added_files"
    fi

    ! head_commit=$(get_current_head) && return 1

    stage_file=$(get_note_file "$head_commit" "stage")

    stage_file_temp="$stage_file.$$"

    [ -f "$stage_file_temp" ] && rm -f "$stage_file_temp"

    origin_git status --short -z | tr '\0' '\n' | grep '^[AMD]. ' |
        while IFS= read -r line
        do
            staged_flag=$(echo "$line"| cut -c 1-1)
            file=$(echo "$line"| cut -c 4-)

            case "$staged_flag" in
                D)
                    log "DELETE: $line"
                    echo "$STX$file${ETX}D" >> "$stage_file_temp"
                    ;;
                *)
                    if [ -f "$stage_file" ] && staged_ts=$(note_get_mtime_ex "$STX$file" "$stage_file"); then
                        if [ -n "$newly_added_files" ] && echo "$newly_added_files" | grep -Fxq "$file"; then
                            log "RENEW: $line"
                            printf "%s\0" "$file"
                        else
                            log "REMAIN: $line, $staged_ts"
                            echo "$STX$file${ETX}$staged_ts" >> "$stage_file_temp"
                        fi
                    else
                        log "ADD: $line"
                        printf "%s\0" "$file"
                    fi
                    ;;
            esac
        done | batch_stat_ex >> "$stage_file_temp" || return 1

    if [ -s "$stage_file_temp" ]; then
        cat < "$stage_file_temp" | LC_ALL=C sort > "$stage_file"
        last_ts=$(awk -F"$ETX" 'BEGIN {max = 0} $2!="D" && $2 > max {max = $2} END {print max}' "$stage_file")
        log "set_file_mtime: $stage_file, $last_ts"
        set_file_mtime "$stage_file" "$last_ts"
    else
        [ ! -s "$stage_file" ] && rm -f "$stage_file"
    fi

    ! rm -f "$stage_file_temp" && return 1

    return 0
}

restore_mtime_from_source()
{
    path="$1"
    source="$2"

    [ ! -e "$path" ] && return 1

    #the target may not the real commit of $path
    last_commit=$(last_commit_for_file "$SUB_DIR$path" "$source")

    if ! note_ts=$(note_get_mtime "$SUB_DIR$path" "$last_commit") || [ -z "$note_ts" ]; then
        note_ts=$(get_commit_time "$last_commit")
    fi

    [ -z "$note_ts" ] && return 1

    log "$last_commit: $files, $note_ts"
    ! synchronize_file "$SUB_DIR$path" "$note_ts" && return 1

    return 0
}


post_restore_file()
{
    file="$1"
    source="$2"

    if stage_ts=$(stage_get_mtime "$file") && [ -n "$stage_ts" ]; then
        note_ts="$stage_ts"
        if [ "D" = "$note_ts" ]; then
            ! note_ts=$(note_get_mtime "$file" "$source") && return 1
            [ -z "$note_ts" ] && note_ts=$(get_commit_time "$source")
            log "restore from last commit: $note_ts"
        else
            log "restore from stage: $stage_ts"
        fi
    else
        ! note_ts=$(note_get_mtime "$file" "$source") && return 1
        [ -z "$note_ts" ] && note_ts=$(get_commit_time "$source")
        log "restore from source: $source, $note_ts"
    fi

    [ -z "$note_ts" ] && echo "no timestamp to restore" && return 0

    ! synchronize_file "$file" "$note_ts" && return 1

    return 0
}

post_restore_files()
{
    files="$1"
    cmd_ts="$2"
    source="${3:-HEAD}"

    [ -n "$files" ] && while IFS= read -r path;
    do
        [ -e "$path" ] || continue

        if [ -d "$path" ]; then
            # restore the mtime for each files which fs mtime later then $ts_before in $sub_files
            sub_files=$(preview_fs_note "HEAD" "$path")
            [ -n "$sub_files" ] && while IFS="$ETX" read -r file file_ts
                do
                    [ "$file_ts" -lt "$cmd_ts" ] && continue
                    ! post_restore_file "$file" "$source" && return 1
                done <<EOF
$sub_files
EOF
        else
            file_ts=$(get_file_mtime "$path")
            [ "$file_ts" -lt "$cmd_ts" ] && continue

            ! post_restore_file "$SUB_DIR$path" "$source" && return 1
        fi
    done << EOF
$files
EOF
    return 0
}

post_checkout_files()
{
    modified_before=$1
    ts_checkout="$2"
    source="$3"

    #select the staged and not modifying files
    origin_git status --short --untracked-files=no | grep '^[AM]  ' | cut -c 4- |
        while IFS="$ETX" read -r path
        do
            file_ts=$(get_file_mtime "$path")
            if [ "$file_ts" -le "$ts_checkout" ]; then
                log "restore: $path"
                ! restore_mtime_from_source "$path" "$source" && return 1
            else
                log "keep mtime: $path, $file_ts"
            fi
        done

    ! refresh_stage_note "$modified_before" && return 1

    return 0
}


show_stage_note()
{
    commit=$(git_rev_parse "${1:-HEAD}")

    stage_file=$(get_note_file "$commit" "stage")

    [ ! -f "$stage_file" ] && echo "no stage.">&2 && return 1

    cat "$stage_file"

    return 0
}

preview_fs_note()
{
    commit=${1:-HEAD}
    path=${2:-${SUB_DIR:-${REPO_ROOT}}}
    origin_git ls-tree -r --full-tree --name-only "$commit" -z -- "$path" | batch_stat_ex
}

get_committed_files()
{
    commit=${1:-HEAD}
    filter=${2:-ACMRT}

    #it should add param --root, or for the first commit, diff-tree will return empty.
    origin_git diff-tree --root --diff-filter="$filter" --no-commit-id --no-renames --name-only -r -M "$commit" -z | tr '\0' '\n'
}

# all diff-tree files should included in the commit note, fill with empty if the real mtime is unknown,
# or the commit note would be incomplete, and the full note merged by commit notes would be incorrect

prebuild_commit_note()
{
    commit=${1:-HEAD}

    ! str=$(get_committed_files "$commit") && echo "diff-tree failed" && return 1

    if [ -n "$str" ]; then
        log "files: $str"

        echo "$str" |
            while IFS= read -r file
            do
                [ ! -e "$file" ] && printf "%s%s%s\n" "$STX" "$file" "$ETX"
            done

        if ! exists_files=$(echo "$str" |
                  while IFS= read -r file
                  do
                      [ -e "$file" ] && printf "%s\0" "$file"
                  done |
                      batch_stat_ex); then
            echo "stat failed"
            return 1
        fi

        log "exists_files: $exists_files"
        if [ -n "$exists_files" ]; then
            ! commit_ts=$(get_commit_time "$commit") && echo "get commit time failed" && return 1
            log "commit_ts: $commit_ts"

            #if fs-mtime greater than commit-time, means the real mtime missing, keep empty
            echo "$exists_files" | awk -F"$ETX" -v OFS="$ETX" -v cts="$commit_ts" '{
                  if($2!="" && $2<=cts){
                      print $1,$2
                  }
                  else{
                      print $1,""
                  }
              }'
        fi
    fi

    get_committed_files "$commit" "D" | while IFS= read -r file
        do
            printf "%s%s%sD\n" "$STX" "$file" "$ETX"
        done

    return 0
}

reverse_before_key() {
    printf "%s\n" "$1" | awk -v k="$2" -F, '
        BEGIN{n=0}
        k!="" && $1==k {found=1; next}
        !found{a[++n]=$0}
        END{for(i=n;i>=1;i--) print a[i]}
    '
}

prebuild_full_note()
{
    commit=$(git_rev_parse "${1:-HEAD}") || return 1

    prev_commits=$(origin_git log --pretty=format:"%H,%ct" "$commit")

    [ -z "$prev_commits" ] && return 1

    latest_full_note=
    commits_to_merge=

    #find the latest full note to the commit
    while IFS="," read -r prev_commit _
        do
            #skip the current commit, even it has a full note
            [ "$prev_commit" = "$commit" ] && continue

            full_note_file=$(get_note_file "$prev_commit" "full")
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

    commits_count=$(echo "$commits_to_merge"| grep -c "")

    ! all_files=$(last_commit_for_files "$commit") && return 1

    files_count=$(echo "$all_files"| grep -c "")

    if [ "$files_count" -lt $((commits_count * 10)) ]; then
        all_files=$(echo "$all_files" | sort)
        log "prebuild by $files_count files, for $commit ..."
        ! prebuild_full_note_file_by_file "$commit" "$all_files" && return 1
    else
        log "prebuild by $commits_count commits based on $latest_full_note, for $commit ..."

        ! prebuild_full_note_commit_by_commit "$commit" "$commits_to_merge" "$latest_full_note" && return 1
    fi

    log "prebuild full note ok $commit"

    return 0
}

prebuild_full_note_file_by_file()
{
    commit=$1
    tbl_file_commit=$2

    [ -z "$commit" ] && echo "no commit hash" && return 1

    pid="$$"
    ret=0

    [ -n "$tbl_file_commit" ] && while
        IFS="$ETX" read -r sfile last_commit commit_ts
        do
            [ "$STX" = "$sfile" ] && continue

            if [ -z "$last_commit" ]; then
                echo "no commit info $sfile, $last_commit, $commit_ts"
                ret=1
                break
            fi

            cache_file="$(get_note_file "$last_commit" "delta").$pid"
            if [ ! -f "$cache_file" ]; then
                if ! note_show "$last_commit" > "$cache_file"; then
                    log "commit note not exists: $sfile, commit: $last_commit, commit_ts: $commit_ts"
                    echo "$sfile$ETX$ETX$last_commit$ETX$commit_ts"
                    continue
                fi
            fi

            if ! note_ts=$(note_get_mtime_ex "$sfile" "$cache_file"); then
                note_ts=""
                log "note missing file: $sfile, commit: $last_commit, commit_ts: $commit_ts"
            fi

            echo "$sfile$ETX$note_ts$ETX$last_commit$ETX$commit_ts"
        done <<EOF
$tbl_file_commit
EOF

    #DO NOT double quote cache_files, or cache files will not be removed correctly
    cache_files="$(get_note_file "*" "delta").$pid"
    ! rm -f $cache_files && return 1

    return $ret
}

prebuild_full_note_commit_by_commit()
{
    commit="$1"
    commits_to_merge="$2"
    latest_full_note="$3"

    full_note_merging="$(get_note_file "$commit" "merging").$$"

    if [ -n "$latest_full_note" ]; then
        cp "$latest_full_note" "$full_note_merging"
    else
        printf "" > "$full_note_merging"
    fi

    [ -n "$commits_to_merge" ] && while IFS=, read -r next_commit next_commits_ts
        do
            log "merge $next_commit ..."
            if ! delta=$(note_show "$next_commit"); then
                log "no commit note ... $next_commit"

                delta=$(get_committed_files "$next_commit" | sed "s/^/$STX/;s/$/$ETX/" &&
                        get_committed_files "$next_commit" "D" | sed "s/^/$STX/;s/$/${ETX}D/")
            fi

            if ! str=$(note_merge_with_delta "$full_note_merging" "$delta" "$next_commit" "$next_commits_ts"); then
                log "merge failed: $str"
                rm -f "$full_note_merging"
                return 1
            fi

#            echo "$str" > "$full_note_merging"
            printf "%s\n" "$str" > "$full_note_merging"

        done << EOF
$commits_to_merge
EOF

    cat "$full_note_merging" && rm -f "$full_note_merging"

    return 0
}

show_full_note()
{
    commit=$1
    if [ -z "$commit" ]; then
        ! commit=$(get_current_head) && return 1
    fi

    note_file=$(get_note_file "$commit" "full")
    if [ ! -f "$note_file" ]; then
        echo "full-index-note not exists" >&2
        return 1
    fi

    cat "$note_file"
    return 0
}

complete_head_note()
{
    ! pre_commit=$(get_prev_commit "HEAD") && return 1

    pre_stage_file=$(get_note_file "$pre_commit" "stage")

    if ! [ -f "$pre_stage_file" ]; then

        #check if the head commit has modified, the mtime may changed invalid
        status_files=$(origin_git status --short --untracked-files=no | cut -c 4-)
        [ -n "$status_files" ] && echo "head commit modified" && return 1

        #stage file missing, find completable files if mtime is valid
        ! note=$(prebuild_commit_note "HEAD") && echo "$note" && return 1

        [ -z "$note" ] && echo "completable note is empty of HEAD" && return 1

        echo "$note" | sort > "$pre_stage_file"
    fi

    if ! note_write "HEAD" "$pre_stage_file"; then
        echo "add head note failed: $pre_stage_file"
        return 1
    fi

    return 0
}

rebuild_commit_note()
{
    commit=${1:-HEAD}

    if is_head "$commit"; then
        ! post_commit && echo "post commit failed" && return 1
        log "post commit ok $commit"
        return 0
    fi

    if ! note=$(prebuild_commit_note "$commit"); then
        echo "$note"
        echo "build note failed"
        return 1
    fi

    [ -z "$note" ] && echo "preview result is empty $commit" && return 0

    ! note_file=$(mktemp "${TMPDIR:-/tmp}/git-kmt-diff.XXXXXX") &&
        echo "mktemp failed" &&
        return 1

    echo "$note" | sort > "$note_file"

    if ! note_write "$commit" "$note_file"; then
        echo "add note failed: $commit, $note_file"
        rm -f "$note_file"
        return 1
    fi

    rm -f "$note_file"

    echo "note_add_file ok"

    ! refresh_later_full_notes "$commit" && echo "Failed to refresh later full notes" && return 1

    echo "refresh_later_full_notes ok"

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
    while IFS="$ETX" read -r path ts rest; do
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
    ! commit=$(get_current_head) && return 1
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

post_clone()
{
    ! upstream_url=$(grep_arg '[^ ]+\.git$' "$@") && echo "unknown url" && return 0
    log "url: $upstream_url"

    repo_dir=$(select_arg "$upstream_url" "$@")
    if [ -z "$repo_dir" ] ; then
        repo_dir=$(echo "$upstream_url" | grep -Eo '(:|/).*\.git$' | cut -c 2- | sed 's/.git$//')
    fi
    log "repo: $repo_dir"

    cd "$repo_dir" || return 1

    init_path
    ! post_fetch && return 1
    ! on_head_moved && return 1
    return 0
}

post_commit_to_stash()
{
    refresh_stage_note "$1"
}

prev_commit()
{
    now_ts=$(date +%s)
    head_commit=$(get_current_head)
    stage_file=$(get_note_file "$head_commit" "stage")
    [ ! -f "$stage_file" ] && return 0
    log "on prev commit: $stage_file"
    while IFS="$ETX" read -r file file_ts
    do
        log "check: $file, $file_ts, $now_ts"
        if [ "$file_ts" != "D" ] && [ "$file_ts" -gt "$now_ts" ]; then
            echo "The file mtime can not be committed, because it is in the future. $(format_timestamp "$file_ts") $file"
            return 2
        fi
    done < "$stage_file"

    return 0
}

post_commit()
{
    ! complete_head_note && return 1

    ! cur_commit=$(get_current_head) && return 1

    ! pre_commit=$(get_prev_commit "HEAD") && return 1

    ! commit_ts=$(get_commit_time "$cur_commit") && return 1

    pre_stage_note_file="$(get_note_file "$pre_commit" "stage")"
    pre_full_note=$(get_note_file "$pre_commit" "full")
    cur_full_note=$(get_note_file "$cur_commit" "full")

    if [ -f "$pre_full_note" ] && [ -f "$pre_stage_note_file" ]; then
        delta=$(cat "$pre_stage_note_file")

        ! note_merge_with_delta "$pre_full_note" "$delta" "$cur_commit" "$commit_ts" > "$cur_full_note" && echo "merge full note failed" && return 1
        rm -f "$pre_full_note"

    else
        log "build full note for $cur_commit ..."

        if ! rebuild_full_note "$cur_commit"; then
            echo "build full note for $cur_commit failed"
            return 1
        fi

        log "build full note for $cur_commit ok"
    fi

    set_file_mtime "$cur_full_note" "$commit_ts"
    [ -f "$pre_stage_note_file" ] && rm -f "$pre_stage_note_file"

    return 0
}

post_revert()
{
    old_commit_id=$1
    shift

    ! head_commit=$(get_current_head) && return 1

    if [ "$old_commit_id" = "$head_commit" ]; then
        if select_arg "--abort" "$@"; then
            echo "rever abort"
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
    ! refresh_stage_note && return 1

    # the un-committed(modified and staged) files should exclude from restore list
    # minus=$(sort a b | uniq)
    status_files=$(origin_git status --short --untracked-files=no | cut -c 4-)

    ! cur_commit=$(get_current_head) && return 1
    full_note=$(get_note_file "$cur_commit" "full")

    if [ ! -s "$full_note" ]; then
        ! rebuild_full_note "$cur_commit" && return 1
    fi

    log "restore mtimes from full note $full_note"

    ! preview_fs_note "HEAD" |
        LC_ALL=C sort |
            LC_ALL=C join -t "$ETX" -e '' -o 1.1,2.2,1.2,1.4 "$full_note" - |
                awk -F"$ETX" -v OFS="$ETX" '
                {
                    if ($2 != $3) {
                        print substr($1,2),$2,$3,$4
                    }
                }
                ' |
                while IFS="$ETX" read -r file file_ts note_ts last_commit_ts
                do
                    ! [ -e "$REPO_ROOT/$file" ] && echo "file not exists $file" && continue

                    [ -n "$status_files" ] && echo "$status_files" | grep -F "$file" && echo "skip $file" && continue

                    if [ -z "$note_ts" ]; then
                        log "no note, use commit date, '$file'"
                        note_ts="$last_commit_ts"
                    fi

                    if [ -z "$file_ts" ] || [ -z "$note_ts" ]; then
                        echo "Invalid file or note timestamp: '$file_ts','$note_ts','$file'"
                        continue
                    fi

                    if [ "$file_ts" -lt "$note_ts" ]; then
                        echo "Conflicting mtime $(format_timestamp "$note_ts") with local $(format_timestamp "$file_ts")  $file"
                        continue
                    fi

                    ! set_file_mtime "$REPO_ROOT/$file" "$note_ts" && return 1

                    fast_format_timestamp "$note_ts"
                    log "synchronize: $TM_RET $file, $note_ts, $file_ts"

                done

    return 0
}

post_push ()
{
    ! origin_git push \
                origin \
                "refs/notes/$NOTE_REF:refs/notes/$NOTE_REF" && return 1 || return 0
}


refresh_later_full_notes()
{
    commit_id="$1"

    if [ ! -e "$GIT_DIR/kmt/" ]; then
        return 0
    fi

    delta_note=$(note_show "$commit_id")

    log "update all exists full note with commit note, $commit_id"

    full_note_files=$(find "$GIT_DIR"/kmt/*.full.note)

    [ -n "$full_note_files" ] && while IFS= read -r file
    do
        if ! grep -m 1 -F "$ETX$commit_id$ETX" "$file"; then
#            log "skip $file"
            continue
        fi

        echo "$delta_note" | LC_ALL=C join -t "$ETX" -a1 -o 1.1,1.2,1.3,1.4,2.1,2.2 "$file" - |
            awk -F"$ETX" -v OFS="$ETX" -v ci="$commit_id" '
            {
                if($3 == ci){
                    print $1,$6,$3,$4
                }
                else{
                    print $1,$2,$3,$4
                }
            }
            ' > "$file.new.$$"

        full_note_file_ts=$(get_file_mtime "$file")
        ! set_file_mtime "$file.new.$$" "$full_note_file_ts" && return 1

        ! mv "$file.new.$$" "$file" && return 1

        log "update full note ok: $file"

    done << EOF
$full_note_files
EOF

    return 0
}

post_fetch()
{
    old_commit_id="$1"

    old_note_id="$(git_rev_parse "refs/notes/kmt/mtime")"

    if ! origin_git fetch origin "+refs/notes/$NOTE_REF:refs/notes/$NOTE_REF"; then
        ! origin_git ls-remote --exit-code origin "refs/notes/$NOTE_REF" && echo "ref not exists" && return 0
        return 1
    fi

    new_note_id=$(git_rev_parse "refs/notes/kmt/mtime")

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

    ! post_fetch "$old_commit_id" && return 1

    if [ "$(get_current_head)" != "$old_commit_id" ]; then
        ! on_head_moved && return 1

        full_note_file=$(get_note_file "$old_commit_id" "full")
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

get_current_head()
{
    git_rev_parse HEAD
    ret=$?
    if [ "$ret" != 0 ]; then
        commits_count=$(origin_git log --pretty=format:"%H,%ct" 2> /dev/null | grep -c "") && [ "$commits_count" -eq "0" ] && return 0
    fi

    return $ret
}

get_prev_commit()
{
    commit=${1:-HEAD}
    git_rev_parse "$commit~1"
    ret=$?
    if [ "$ret" != 0 ]; then
        commits_count=$(origin_git log --pretty=format:"%H,%ct" "$commit" 2>/dev/null | grep -c "") && [ "$commits_count" -eq "1" ] && return 0
    fi

    return $ret
}

current_branch()
{
    origin_git branch --show-current
}

# ---------------------------------------------------------------------------
# Checkout / restore / pull/update handlers
# ---------------------------------------------------------------------------

git_command_handler()
{
    log "git_command_handler $*"

    cmd=$(select_git_command "$@")

    [ -z "$cmd" ] && return 1

    case "$cmd" in
        commit)
            ! prev_commit && return 1
            ;;
        add|rm|rename|checkout|restore)
            #also can get the added files by the outputs as the following two commands
            #git diff --name-only
            #git diff --name-only --staged
            modified_before=$(origin_git status --short --untracked-files=no -z |  tr '\0' '\n' | grep '^.M ' | cut -c 4-)
            ts_before=$(date +%s)
            ;;
        reset)
            ;;
    esac

    if [ "$cmd" = 'clone' ]; then
        old_commit_id=
    else
        ! old_commit_id=$(get_current_head) && return 1
    fi

    log "git cmd: $cmd"
    #DO NOT USE ! ... && return $?, because ! command will change the $? to 0
    origin_git "$@" || return $?
    log "origin_git ok"
    case "$cmd" in
        clone)
            ! post_clone "$@" && return 1
            ;;
        add|rm|rename)
            log "post $cmd"
            ! post_commit_to_stash "$modified_before" && echo "$cmd succeeded but timestamp note $cmd failed." && return 1
            log "KMT: mtime $cmd."
            ;;
        commit)
            log "post commit ..."

            ! post_commit && echo "commit succeeded but timestamp note creation failed." && return 1

            log "KMT: notes added."
            ;;
        merge)
            log "post merge ..."
            # merge creates a new commit in the usual non-ff case.  If it did, create
            # its note; afterwards synchronize the resulting HEAD.

            ! post_commit && echo "commit succeeded but timestamp note creation failed." && return 1

            log "KMT: notes added."
            ;;
        restore)
            if select_arg "--staged" "$@"; then
                # in this case( with --staged), the file just moved out from the stash, but not restore the file content.
                # and commit not changed, so do not restore the mtime, just refresh the stage note.
                ! refresh_stage_note "$modified_before" && return 1
                return 0
            fi

            if source=$(select_arg "--source" "$@"); then
                log "source: $source"
                files=$(select_args "--source=$source" "$@")
            else
                source=
                files=$(select_args "restore" "$@")
            fi

            log "source: $source, files: $files"
            if [ -n "$files" ]; then
                ! post_restore_files "$files" "$ts_before" "$source" && return 1
            fi
            ;;
        checkout)
            source=$(select_arg "checkout" "$@")
            [ -z "$source" ] && echo "unknown branch" && return 1

            if select_arg "--" "$@" > /dev/null; then
                files=$(select_args "--" "$@")
            else
                files=$(select_args "$source" "$@")
            fi

            if [ "$(get_current_head)" != "$old_commit_id" ]; then
                echo "checkout from $old_commit_id to $(get_current_head)"
                ! on_head_moved && return 1
            elif [ -n "$files" ]; then
                #checkout path may be a dir, and they had moved into stash
                ! post_checkout_files "$modified_before" "$ts_before" "$source" && return 1
            fi
            ;;
        switch)
            if [ "$(get_current_head)" != "$old_commit_id" ]; then
                ! on_head_moved && return 1
            fi
            return 0
            ;;
        reset)
            if select_arg "--hard" "$@" && [ "$(get_current_head)" != "$old_commit_id" ]; then
                ! on_head_moved && return 1
            fi
            ;;
        revert)
            ! post_revert "$old_commit_id" "$@" && return 1
            return 0
            ;;
        push)
            log "post push ..."

            ! post_push && echo "Git push succeeded but timestamp note push failed." && return 1

            echo "KMT: notes pushed."
            ;;
        fetch)
            post_fetch "$old_commit_id"
            ;;

        pull)
            log "post pull ..."

            ! post_pull "$old_commit_id" && echo "Git pull succeeded but timestamp note fetch failed." && return 1

            echo "KMT: notes fetched."

            ;;
    esac

    return 0
}

# ---------------------------------------------------------------------------
# Maintenance / inspection commands
# ---------------------------------------------------------------------------

show_commit_note()
{
    ! commit=$(git_rev_parse "${1:-HEAD}") && echo "get commit-id failed $1" && return 1

    ! note_show "$commit" &&  return 1

    return 0
}

show_history()
{
    path=$1
    commit=${2:-HEAD}

    [ -z "$path" ] && echo "history requires a file path" && return 1

    # if you want to track the rename history, add --follow and --name-staus to git log
    # read out the origin name when renamed, use origin name to show history mtimes
    # THIS has not implemented yet.

    ! prev_commits=$(origin_git log --format='%H,%cI' "$commit" -- "$path") && return 1

    [ -z "$prev_commits" ] && echo "no history" && return 0

    echo "$prev_commits" |
        while IFS="," read -r commit date; do
            note_ts=$(note_get_mtime "$SUB_DIR$path" "$commit")
            if [ -n "$note_ts" ]; then
                printf '%s | %s | %s | %s\n' "$commit" "$date" "$note_ts" "$(format_timestamp "$note_ts")"
            else
                printf '%s | %s | %10s | %s\n' "$commit" "$date" "$note_ts" "$(format_timestamp "")"
            fi
        done
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
    find_command "look" > /dev/null && IS_LOOK_INSTALLED=1 || IS_LOOK_INSTALLED=0
}

select_git_command()
{
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

show_note()
{
    while IFS="$ETX" read -r file ts ci ct
    do
        [ -z "$file" ] && continue

        if is_timestamp "$ts"; then
            fast_format_timestamp "$ts"
            ts="$TM_RET"
        fi

        printf "%s,%s,%s,%s\n" "$file" "$ts" "$ci" "$ct"
    done
    return 0
}


kmt_note_ui()
{
    alias=${1:-HEAD}

    ! commit=$(git_rev_parse "$alias") || [ -z "$commit" ] && echo "Commit not exists: $alias" && return 1

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
        tm_start=$(date +%s.%N | sed 's/0*$//')
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
                preview_fs_note "$commit" | show_note ||
                    echo "FAILED"
                ;;

            5)
                echo "Input a file to show history:"
                read -r file
                [ -z "$file" ] && key= && continue

                show_history "$file" "$commit"

                continue

                ;;

            6)
                prebuild_commit_note "$commit" | sort | show_note ||
                    echo "FAILED"
                ;;
            7)
                ! rebuild_commit_note "$commit" && return 1
                ;;

            8)
                prebuild_full_note "$commit" | show_note
                ;;
            9)
                ! rebuild_full_note "$commit" && echo "build full note for $commit failed" && return 1
                ;;
            *)
                return 0
                ;;
        esac

        tm_end=$(date +%s.%N | sed 's/0*$//')

        duration=$(float_diff "$tm_end" "$tm_start")

        echo "done."
        echo "Elapsed time(s): ${duration}"

        read -r key
    done

    return 0
}


app_command_handler()
{
    cmd=$(select_git_command "$@")

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

    return 0
}

app_get_remote_url()
{
    origin_git remote -v | grep -m 1 -oE 'http[s]?://[^/]*'
}

rebuild_full_note()
{
    commit="${1:-HEAD}"
    full_note_file=$(get_note_file "$commit" "full")

    ! ( prebuild_full_note "$commit" > "$full_note_file.temp.$$" ) && return 1

    ! mv "$full_note_file.temp.$$" "$full_note_file" && return 1

    ! set_file_mtime "$full_note_file" "$(get_commit_time "$commit")" && return 1

    return 0
}

app_kmt_list()
{
    ! commit=$(get_current_head) && return 1

    full_note_file=$(get_note_file "$commit" "full")
    if [ ! -s "$full_note_file" ]; then
        ! rebuild_full_note "$commit" && return 1
    fi

    while IFS= read -r dir
        do
            log "scan dir: $dir"
            ! preview_fs_note "$commit" "$dir" |
                LC_ALL=C sort |
                LC_ALL=C join -t "$ETX" -a1 -e '' -o 1.1,1.2,2.2,2.4 - "$full_note_file" | sed "s/^$STX//" && return 1
        done << EOF
$dirs
EOF

    return 0
}

app_save_file_mtime()
{
    file="$1"

    [ -z "$file" ] && return 1

    file_ts=$2

    [ -z "$file_ts" ] && return 1

    if ! commit=$(last_commit_for_file "$file"); then
        echo "$commit"
        echo "get commit failed '$file'" && return 1
    fi

    if note_ts=$(note_get_mtime "$SUB_DIR$file" "$commit") && [ "$file_ts" = "$note_ts" ]; then
        log "mtime exists in note, '$file', $file_ts, $commit"
        return 0
    fi

    log "file: '$file', note ts: $note_ts, file_ts, $file_ts"

    ! rebuild_commit_note "$commit" && echo "update commit note failed" && return 1

    log "rebuild_commit_note ok '$file'"

    return 0
}

app_is_later_then_last_2nd_commit()
{
    echo '0'
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
