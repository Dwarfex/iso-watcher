#!/bin/bash
set -euo pipefail

INPUT="/media/input"
WORK="/media/work"
OUTPUT="/media/output"
MOUNT="/mnt/iso"

SCAN_INTERVAL=60

TARGET_UID="${APP_UID:-1000}"
TARGET_GID="${APP_GID:-1000}"

mkdir -p "$WORK" "$OUTPUT" "$MOUNT"

LOG_LEVEL="${LOG_LEVEL:-info}"

# -------- Logging --------

log() {
    LEVEL="$1"
    shift
    
    if [[ "${LOG_LEVEL,,}" == "info" && "$LEVEL" == "DEBUG" ]]; then
        return 0
    elif [[ "${LOG_LEVEL,,}" == "warn" && ( "$LEVEL" == "DEBUG" || "$LEVEL" == "INFO" ) ]]; then
        return 0
    elif [[ "${LOG_LEVEL,,}" == "error" && "$LEVEL" != "ERROR" ]]; then
        return 0
    fi

    echo "[$(date '+%F %T')] [$LEVEL] $*"
}

log_info()  { log INFO  "$@"; }
log_warn()  { log WARN  "$@"; }
log_error() { log ERROR "$@"; }
log_debug() { log DEBUG "$@"; }

# -------- Helpers --------

wait_for_stable() {
    FILE="$1"
    LAST_SIZE=0

    log_info "Waiting for file to stabilize: $FILE"

    while true; do
        [[ ! -f "$FILE" ]] && {
            log_warn "File disappeared while waiting: $FILE"
            return 1
        }

        SIZE=$(stat -c%s "$FILE" 2>/dev/null || echo 0)
        log_debug "Current size: $SIZE bytes"

        if [[ "$SIZE" -eq "$LAST_SIZE" ]]; then
            sleep 5
            SIZE2=$(stat -c%s "$FILE" 2>/dev/null || echo 0)

            if [[ "$SIZE" -eq "$SIZE2" ]]; then
                log_info "File is stable: $FILE ($SIZE bytes)"
                break
            fi
        fi

        LAST_SIZE="$SIZE"
        sleep 2
    done
}

is_mp3_cd() {
    ISO="$1"

    log_info "Mounting ISO for inspection: $ISO"
    mount -o loop,ro "$ISO" "$MOUNT"

    COUNT=$(find "$MOUNT" -type f -iname "*.mp3" | wc -l)
    OTHER_COUNT=$(find "$MOUNT" -type f ! -iname "*.mp3" | wc -l)

    log_info "MP3 files found: $COUNT"
    if [[ "$OTHER_COUNT" -gt 0 ]]; then
        log_info "Notice: Found $OTHER_COUNT non-MP3 file(s) in the ISO:"
        find "$MOUNT" -type f ! -iname "*.mp3" | while read -r OTHER_FILE; do
            log_info "  - $(basename "$OTHER_FILE")"
        done
    fi

    umount "$MOUNT"

    if [[ "$COUNT" -gt 0 ]]; then
        return 0
    else
        return 1
    fi
}

extract_mp3s() {
    ISO="$1"
    NAME="$2"

    TMP="$WORK/.extract_$NAME"

    log_info "Extracting MP3s from $ISO → $TMP"

    mkdir -p "$TMP"

    mount -o loop,ro "$ISO" "$MOUNT"

    rsync -av --include="*/" --include="*.mp3" --exclude="*" \
        "$MOUNT/" "$TMP/"

    umount "$MOUNT"

    FILE_COUNT=$(find "$TMP" -type f -iname "*.mp3" | wc -l)
    log_info "Extracted $FILE_COUNT MP3 files"

    # Extract metadata
    ARTISTS=$(find "$TMP" -type f -iname "*.mp3" -exec ffprobe -v quiet -show_entries format_tags=artist -of default=noprint_wrappers=1:nokey=1 {} \; | awk '{$1=$1;print}' | grep -v '^$' | sort -uf || true)
    ALBUMS=$(find "$TMP" -type f -iname "*.mp3" -exec ffprobe -v quiet -show_entries format_tags=album -of default=noprint_wrappers=1:nokey=1 {} \; | awk '{$1=$1;print}' | grep -v '^$' | sort -uf || true)

    ARTIST_COUNT=$(echo "$ARTISTS" | grep -v '^$' | wc -l || true)
    ALBUM_COUNT=$(echo "$ALBUMS" | grep -v '^$' | wc -l || true)

    if [[ "$ARTIST_COUNT" -eq 1 ]]; then
        ARTIST="$ARTISTS"
    else
        ARTIST="various_artists"
    fi

    if [[ "$ALBUM_COUNT" -eq 1 ]]; then
        ALBUM="$ALBUMS"
    else
        ALBUM="unknown_album"
    fi

    # Sanitize names for filesystem
    ARTIST=$(echo "$ARTIST" | sed 's/[^a-zA-Z0-9_-]/_/g' | sed 's/^_*//;s/_*$//')
    ALBUM=$(echo "$ALBUM" | sed 's/[^a-zA-Z0-9_-]/_/g' | sed 's/^_*//;s/_*$//')

    if [[ -z "$ARTIST" ]]; then ARTIST="various_artists"; fi
    if [[ -z "$ALBUM" ]]; then ALBUM="unknown_album"; fi

    DEST="$OUTPUT/$ARTIST/$ALBUM/$NAME"
    log_info "Destination path: $DEST"

    mkdir -p "$DEST"
    mv "$TMP"/* "$DEST/" 2>/dev/null || true
    rmdir "$TMP" 2>/dev/null || true

    chown -R "$TARGET_UID:$TARGET_GID" "$DEST"
    chmod -R 777 "$DEST"

    log_info "Files moved to final destination and chowned: $DEST"
}

mark_processing() {
    touch "$1.processing"
}

unmark_processing() {
    rm -f "$1.processing"
}

is_processing() {
    [[ -f "$1.processing" ]]
}

process_iso() {
    ISO="$1"

    [[ ! -f "$ISO" ]] && return

    if is_processing "$ISO"; then
        log_debug "Already processing (skipped): $ISO"
        return
    fi

    mark_processing "$ISO"

    log_info "---- START processing: $ISO ----"

    if ! wait_for_stable "$ISO"; then
        unmark_processing "$ISO"
        return
    fi

    if ! is_mp3_cd "$ISO"; then
        log_warn "Not an MP3-CD → skipping: $ISO"
        unmark_processing "$ISO"
        return
    fi

    BASENAME=$(basename "$ISO" .iso)
    TARGET_ISO="$WORK/$BASENAME.iso"

    if [[ "$ISO" != "$TARGET_ISO" ]]; then
        log_info "Moving ISO → $TARGET_ISO"
        mv "$ISO" "$TARGET_ISO"
        mv "$ISO.processing" "$TARGET_ISO.processing" 2>/dev/null || true
        
        SRC_DIR=$(dirname "$ISO")
        SRC_DIR_NAME=$(basename "$SRC_DIR")
        ISO_NAME=$(basename "$ISO")
        
        if [[ "$SRC_DIR_NAME" == "$ISO_NAME" || "$SRC_DIR_NAME" == "$BASENAME" ]]; then
            if [[ "$SRC_DIR_NAME" != "completed" && "$SRC_DIR_NAME" != "unidentified" ]]; then
                rmdir "$SRC_DIR" 2>/dev/null && \
                    log_info "Removed empty directory: $SRC_DIR" || true
            fi
        fi
        
        ISO="$TARGET_ISO"
    fi

    HASH=$(md5sum "$TARGET_ISO" | awk '{print $1}' | cut -c1-8)
    log_info "ISO md5 hash: $HASH"

    extract_mp3s "$TARGET_ISO" "${BASENAME}_${HASH}"

    if [[ "${DELETE_ISO:-true}" == "true" ]]; then
        log_info "Deleting ISO: $TARGET_ISO"
        rm -f "$TARGET_ISO"
    else
        log_info "Moving ISO to finished_iso: $TARGET_ISO"
        mkdir -p "$OUTPUT/finished_iso"
        chmod 777 "$OUTPUT/finished_iso"
        mv "$TARGET_ISO" "$OUTPUT/finished_iso/"
        chown "$TARGET_UID:$TARGET_GID" "$OUTPUT/finished_iso/$(basename "$TARGET_ISO")"
        chmod 777 "$OUTPUT/finished_iso/$(basename "$TARGET_ISO")"
    fi

    unmark_processing "$ISO"

    log_info "---- DONE processing: $BASENAME ----"
}

scan_existing() {
    log_debug "Scanning for existing ISOs..."

    find "$INPUT" "$WORK" -type f -iname "*.iso" | while read ISO
    do
        log_debug "Found ISO: $ISO"
        process_iso "$ISO"
    done
}


periodic_scan() {
    while true; do
        scan_existing
        sleep "$SCAN_INTERVAL"
        log_debug "Periodic scan triggered"
    done
}

# -------- Startup --------

log_info "===== ISO Watcher started ====="
log_info "Input:  $INPUT"
log_info "Work:   $WORK"
log_info "Output: $OUTPUT"

periodic_scan

