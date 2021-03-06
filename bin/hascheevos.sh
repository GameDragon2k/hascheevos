#!/bin/bash
# hascheevos.sh
####################
#
# A tool to check if your ROMs have cheevos (RetroAchievements.org).
#
# valid ROM extensions for:
# nes, snes, megadrive, mastersystem, gb, gba, gbc, n64, pcengine
# zip 7z nes fds gb gba gbc sms bin smd gen md sg smc sfc fig swc mgd iso cue z64 n64 v64 pce ccd cue

        

# TODO: check dependencies curl, jq, zcat, unzip, 7z, cheevoshash (from this repo).

# globals ####################################################################

readonly USAGE="
USAGE:
$0 romfile1 [romfile2 ...]"

# the extensions below were taken from RetroPie's configs
readonly EXTENSIONS='zip|7z|nes|fds|gb|gba|gbc|sms|bin|smd|gen|md|sg|smc|sfc|fig|swc|mgd|iso|cue|z64|n64|v64|pce|ccd|cue'
readonly SCRIPT_DIR="$(cd "$(dirname $0)" && pwd)"
readonly DATA_DIR="$SCRIPT_DIR/../data"
readonly GAMEID_REGEX='^[1-9][0-9]{0,9}$'

RA_USER=
RA_PASSWORD=
RA_TOKEN=
CHECK_FALSE_FLAG=0

CONSOLE_NAME=()
CONSOLE_NAME[1]=megadrive
CONSOLE_NAME[2]=n64
CONSOLE_NAME[3]=snes
CONSOLE_NAME[4]=gb
CONSOLE_NAME[5]=gba
CONSOLE_NAME[6]=gbc
CONSOLE_NAME[7]=nes
CONSOLE_NAME[8]=pcengine
CONSOLE_NAME[9]=segacd
CONSOLE_NAME[10]=sega32x
CONSOLE_NAME[11]=mastersystem
#CONSOLE_NAME[12]=xbox360
#CONSOLE_NAME[13]=atari
#CONSOLE_NAME[14]=neogeo


# functions ##################################################################

# Getting the RetroAchievements token
# input: RA_USER, RA_PASSWORD
# updates: RA_TOKEN
# exit if fails
function get_cheevos_token() {
    if [[ -z "$RA_USER" ]]; then
        echo "ERROR: undefined RetroAchievements.org user (see \"--user\" option)." >&2
        exit 1
    fi

    if [[ -z "$RA_PASSWORD" ]]; then
        echo "ERROR: undefined RetroAchievements.org password (see \"--password\" option)." >&2
        exit 1
    fi

    RA_TOKEN="$(curl -s "http://retroachievements.org/dorequest.php?r=login&u=${RA_USER}&p=${RA_PASSWORD}" | jq -r .Token)"
    if [[ "$RA_TOKEN" == null || -z "$RA_TOKEN" ]]; then
        echo "ERROR: cheevos authentication failed. Aborting..."
        exit 1
    fi
}


# download hashlibrary for a specific console
# $1 is the console_id
function download_hashlibrary() {
    local console_id="$1"

    if [[ "$console_id" -le 0 || "$console_id" -gt "${#CONSOLE_NAME[@]}" ]]; then
        echo "ERROR: invalid console ID: $console_id" >&2
        exit 1
    fi

    local json_file="$DATA_DIR/${CONSOLE_NAME[console_id]}_hashlibrary.json"

    echo "--- getting the console hash library for \"${CONSOLE_NAME[console_id]}\"..." >&2
    curl -s "http://retroachievements.org/dorequest.php?r=hashlibrary&c=$console_id" \
        | jq '.' > "$json_file" 2> /dev/null \
        || echo "ERROR: failed to download hash library for \"${CONSOLE_NAME[console_id]}\"!" >&2

    [[ -s "$json_file" ]] || rm -f "$json_file"
}


# download hashlibrary for all consoles
function get_hash_libraries() {
    local i

    echo "Getting hash libraries..."

    for i in $(seq 1 ${#CONSOLE_NAME[@]}); do
        # XXX: do not get hashlibrary for sega32x and segacd (currently unsupported)
        [[ $i -eq 9 || $i -eq 10 ]] && continue
        download_hashlibrary "$i"
    done
}


# Print (echo) the game ID of a given rom file
# This function try to get the game id from local *_hashlibrary.json files, if
# these files don't exist the script will try to get them from RA server.
# input:
# $1 is a rom file (should be previously validated with validate_rom_file())
# also needs RA_TOKEN
function get_game_id() {
    local rom="$1"
    local hash
    local hash_i
    local gameid
    local console_id=0

    hash="$(get_rom_hash "$rom")" || return 1

    for hash_i in $(echo "$hash" | sed 's/^\(SNES\|NES\|Genesis\|plain MD5\): //'); do
        echo "--- hash:    $hash_i" >&2
        gameid="$(grep -h "\"$hash_i\"" "$DATA_DIR"/*_hashlibrary.json 2> /dev/null | cut -d: -f2 | tr -d ' ,')"
        [[ $gameid =~ $GAMEID_REGEX ]] && break
    done

    if [[ ! $gameid =~ $GAMEID_REGEX ]]; then
        echo "--- checking at RetroAchievements.org server..." >&2
        for hash_i in $(echo "$hash" | sed 's/^\(SNES\|NES\|Genesis\|plain MD5\): //'); do
            echo "--- hash:    $hash_i" >&2
            gameid="$(curl -s "http://retroachievements.org/dorequest.php?r=gameid&m=$hash_i" | jq .GameID)"
            if [[ $gameid =~ $GAMEID_REGEX ]]; then
                # if the logic reaches this point, mark this game's console to download the hashlibrary
                console_id="$(
                    curl -s "http://retroachievements.org/dorequest.php?r=patch&u=${RA_USER}&g=${gameid}&f=3&l=1&t=${RA_TOKEN}" \
                        | jq '.PatchData.ConsoleID'
                )"
                break
            fi
        done
    fi

    if [[ "$gameid" == 0 ]]; then
        echo "WARNING: this ROM file doesn't feature achievements." >&2
        return 1
    fi

    if [[ ! $gameid =~ $GAMEID_REGEX ]]; then
        echo "ERROR: \"$rom\": unable to get game ID." >&2
        return 1
    fi

    # if the logic reaches this point, we have a valid game ID

    [[ "$console_id" -ne 0 ]] && download_hashlibrary "$console_id"

    echo "$gameid"
}


# Check if a game has cheevos.
# returns 0 if yes; 1 if not; 2 if an error occurred
function game_has_cheevos() {
    local gameid="$1"
    local hascheevos_file
    local boolean

    if [[ ! $gameid =~ $GAMEID_REGEX ]]; then
        echo "ERROR: \"$gameid\" invalid game ID." >&2
        return 1
    fi

    echo "--- game ID: $gameid" >&2

    # TODO: check if $DATA_DIR exist.
    #       if does not, download the *_hascheevos.txt files from the repo
    hascheevos_file="$(grep -l "^$gameid:" "$DATA_DIR"/*_hascheevos.txt)"
    if [[ -f "$hascheevos_file" ]]; then
        boolean="$(grep "^$gameid:" "$hascheevos_file" | cut -d: -f2)"
        [[ "$boolean" == true ]] && return 0
        [[ "$boolean" == false && "$CHECK_FALSE_FLAG" -eq 0 ]] && return 1
    fi
    
    [[ -z "$RA_TOKEN" ]] && get_cheevos_token

    echo "--- checking at RetroAchievements.org server..." >&2

    local patch_json="$(curl -s "http://retroachievements.org/dorequest.php?r=patch&u=${RA_USER}&g=${gameid}&f=3&l=1&t=${RA_TOKEN}")"
    local number_of_cheevos="$(echo "$patch_json" | jq '.PatchData.Achievements | length')"
    [[ -z "$number_of_cheevos" || "$number_of_cheevos" -lt 1 ]] && return 1

    # if the logic reaches this point, the game has cheevos

    # updating the _hascheevos.txt file
    local console_id="$(echo "$patch_json" | jq '.PatchData.ConsoleID')"
    hascheevos_file="${CONSOLE_NAME[console_id]}_hascheevos.txt"

    sed -i "s/^${gameid}:.*/${gameid}:true/" "$hascheevos_file"
    grep -q "^${gameid}:true" "$hascheevos_file" || echo "${gameid}:true" >> "$hascheevos_file"
    sort -un "$hascheevos_file" -o "$hascheevos_file"

    sleep 1 # XXX: a small delay to not stress the server
    return 0
}


# print the hash of a given rom file
function get_rom_hash() {
    local rom="$1"
    local hash
    local uncompressed_rom

    case "$rom" in
        # TODO: check if "inflating" and "Extracting" are really OK for any locale config
        *.zip|*.ZIP)
            uncompressed_rom="$(unzip -o -d /tmp "$rom" | sed -e '/\/tmp/!d; s/.*inflating: //; s/ *$//')"
            validate_rom_file "$uncompressed_rom" || return 1
            hash="$($SCRIPT_DIR/cheevoshash "$uncompressed_rom")"
            rm -f "$uncompressed_rom"
            ;;
        *.7z|*.7Z)
            uncompressed_rom="/tmp/$(7z e -y -bd -o/tmp "$rom" | sed -e '/Extracting/!d; s/Extracting  //')"
            validate_rom_file "$uncompressed_rom" || return 1
            hash="$($SCRIPT_DIR/cheevoshash "$uncompressed_rom")"
            rm -f "$uncompressed_rom"
            ;;
        *)
            hash="$($SCRIPT_DIR/cheevoshash "$rom")"
            ;;
    esac
    [[ "$hash" =~ :\ [^\ ]{32} ]] || return 1
    echo "$hash"
}


# check if the file exists and has a valid extension
function validate_rom_file() {
    local rom="$1"

    if [[ -z "$rom" ]]; then
        echo "ERROR: missing ROM file name." >&2
        echo "$USAGE" >&2
        return 1
    fi

    if [[ ! -f "$rom" ]]; then
        echo "ERROR: \"$rom\": file not found!" >&2
        return 1
    fi

    if [[ ! "${rom##*.}" =~ ^($EXTENSIONS)$ ]]; then
        echo "ERROR: \"$rom\": invalid file extension." >&2
        return 1
    fi

    return 0
}


# Check if a game has cheevos.
# returns 0 if yes; 1 if not; 2 if an error occurred
function rom_has_cheevos() {
    local rom="$1"
    validate_rom_file "$rom" || return 1

    echo "Checking \"$rom\"..." >&2

    local gameid
    gameid="$(get_game_id "$rom")" || return 1

    game_has_cheevos "$gameid"
}


# helping to deal with command line arguments
function check_argument() {
    # limitation: the argument 2 can NOT start with '-'
    if [[ -z "$2" || "$2" =~ ^- ]]; then
        echo "$1: missing argument" >&2
        return 1
    fi
}



# START HERE ##################################################################

while [[ -n "$1" ]]; do
    case "$1" in

#H -h|--help                Print the help message and exit.
#H 
        -h|--help)
            echo "$USAGE"
            echo
            # getting the help message from the comments in this source code
            sed -n 's/^#H //p' "$0"
            exit
            ;;

#H -u|--user USER           USER is your RetroAchievements.org username.
#H 
        -u|--user)
            check_argument "$1" "$2" || exit 1
            shift
            RA_USER="$1"
            ;;

#H -p|--password PASSWORD   PASSWORD is your RetroAchievements.org password.
#H 
        -p|--password)
            check_argument "$1" "$2" || exit 1
            shift
            RA_PASSWORD="$1"
            ;;

#H --get-hashlibs           Download JSON hash libraries for all supported
#H                          consoles and exit.
#H 
        --get-hashlibs)
            get_hash_libraries
            exit
            ;;

#H -f|--check-false         Check at RetroAchievements.org server even if the
#H                          game ID is marked as "has no cheevos" (false) in the
#H                          local *_hascheevos.txt files.
#H 
        -f|--check-false)
            CHECK_FALSE_FLAG=1
            ;;

# TODO: --repo-compare

        *)  break
            ;;
    esac
    shift
done

get_cheevos_token

for f in "$@"; do
    if rom_has_cheevos "$f"; then
        echo -n "$f"
        echo -n " HAS CHEEVOS!" >&2
        echo
    else
        echo "\"$f\" has no cheevos. :(" >&2
    fi
done
