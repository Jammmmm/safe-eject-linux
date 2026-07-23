#!/bin/bash
#================================================================================
# Safely unmount and power-off an external HDD with a GUI selector.
# STRICTLY SAFE VERSION: Unmounts via GVfs (gio mount -u) so that file managers
# like Nautilus release their own handles gracefully before any kernel-level
# unmount is attempted — then powers off the drive via udisksctl.
#
# HOW THE FILE MANAGER EJECTS SUCCESSFULLY:
#   Nautilus → GIO g_drive_eject_with_operation()
#            → GVfs daemon releases its own mount handles
#            → kernel unmount succeeds (no busy handles)
#            → udisksctl power-off succeeds
#
# WHY udisksctl power-off ALONE FAILS:
#   udisksctl → kernel unmount syscall directly
#             → GVfs/Nautilus handles still live → EBUSY
#
# REQUIRES: zenity, udisks2, lsof, glib2-tools (gio)
#    Install: sudo apt install zenity udisks2 lsof libglib2.0-bin
#================================================================================

set -uo pipefail

# =============================================================================
# Preflight: verify required tools are present
# =============================================================================
MISSING=()
for TOOL in zenity udisksctl lsof lsblk findmnt gio; do
    command -v "$TOOL" &>/dev/null || MISSING+=("$TOOL")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    MSG="Required tools are not installed: ${MISSING[*]}\n\nInstall with:\n  sudo apt install zenity udisks2 lsof libglib2.0-bin"
    if command -v zenity &>/dev/null; then
        zenity --error --title="Missing Dependencies" --text="$MSG" --width=400
    else
        echo -e "$MSG" >&2
    fi
    exit 1
fi

# =============================================================================
# STEP 1: Identify all system disks to exclude
# =============================================================================
declare -A SYSTEM_DISKS

for MP in / /boot /boot/efi /usr /var /home; do
    SOURCE=$(findmnt -n -o SOURCE "$MP" 2>/dev/null) || continue
    [[ -z "$SOURCE" ]] && continue
    PKNAME=$(lsblk -no pkname "$SOURCE" 2>/dev/null) || continue
    [[ -n "$PKNAME" ]] && SYSTEM_DISKS["$PKNAME"]=1
done

# =============================================================================
# STEP 2: Build the list of candidate (non-system) drives
# =============================================================================
DRIVES_LIST=()

while IFS= read -r LINE; do
    NAME=$(awk '{print $1}' <<< "$LINE")
    SIZE=$(awk '{print $2}' <<< "$LINE")
    MODEL=$(awk '{$1=$2=""; sub(/^[[:space:]]*/,""); print}' <<< "$LINE")
    LABEL=$(lsblk -n -o LABEL "/dev/${NAME}" | awk 'NF { print " (" $0 ")"; exit }')

    [[ "$NAME" == loop* ]] && continue
    [[ -v SYSTEM_DISKS["$NAME"] ]] && continue

    DISPLAY_MODEL="${MODEL:-Unknown Device}"
    DISPLAY_MODEL="${DISPLAY_MODEL//&/&amp;}"
    DISPLAY_MODEL="${DISPLAY_MODEL//</&lt;}"
    DISPLAY_MODEL="${DISPLAY_MODEL//>/&gt;}"

    DRIVES_LIST+=("/dev/${NAME}" "(${SIZE}) — ${DISPLAY_MODEL}${LABEL}")
done < <(lsblk -d -n -o NAME,SIZE,MODEL)

if [[ ${#DRIVES_LIST[@]} -eq 0 ]]; then
    zenity --error \
           --title="No Drives Found" \
           --text="No suitable external or secondary drives were found.\n\nOnly system drives are currently attached." \
           --width=380
    exit 1
fi

# =============================================================================
# STEP 3: Show the GUI drive selector
# =============================================================================
CHOSEN_DRIVE=$(zenity --list \
                      --title="Safely Eject Drive" \
                      --text="Select the drive you want to safely eject:" \
                      --column="Device" \
                      --column="Information" \
                      "${DRIVES_LIST[@]}" \
                      --width=520 --height=300)

[[ -z "$CHOSEN_DRIVE" ]] && exit 0

# =============================================================================
# STEP 4: Validate the chosen drive
# =============================================================================
if [[ ! -b "$CHOSEN_DRIVE" ]]; then
    zenity --error \
           --title="Invalid Device" \
           --text="'${CHOSEN_DRIVE}' is not a valid block device.\n\nCannot proceed." \
           --width=380
    exit 1
fi

CHOSEN_NAME=$(basename "$CHOSEN_DRIVE")
CHOSEN_PKNAME=$(lsblk -no pkname "$CHOSEN_DRIVE" 2>/dev/null || true)

for CHECK_NAME in "$CHOSEN_NAME" "${CHOSEN_PKNAME:-}"; do
    [[ -z "$CHECK_NAME" ]] && continue
    if [[ -v SYSTEM_DISKS["$CHECK_NAME"] ]]; then
        zenity --error \
               --title="Safety Check Failed" \
               --text="<b>Refusing to eject ${CHOSEN_DRIVE}.</b>\n\nThis drive appears to contain system partitions.\nEjecting it could crash or corrupt your system." \
               --width=420
        exit 1
    fi
done

# =============================================================================
# STEP 5: Unmount via GVfs, then power off
#
# gio mount -u <mountpoint>
#   → goes through the GVfs daemon
#   → GVfs notifies registered clients (Nautilus, Thunar, etc.) to release
#     their own file handles on that mount
#   → only then issues the kernel unmount
#   → this is the same path as clicking Eject in the file manager
#
# udisksctl power-off  (called AFTER all GVfs mounts are released)
#   → no live handles remain → kernel unmount succeeds → drive spins down
# =============================================================================
RESULT_FILE=$(mktemp /tmp/eject-drive.XXXXXX)
PIPE_STATUS_FILE=$(mktemp /tmp/eject-pipe.XXXXXX)
trap 'rm -f "$RESULT_FILE" "$PIPE_STATUS_FILE"' EXIT

(
    set -uo pipefail

    echo "10"
    echo "# Syncing pending writes to disk..."
    sync
    sleep 1

    # ------------------------------------------------------------------
    # 5a: Collect all mounted partitions on this drive
    # ------------------------------------------------------------------
    # Each line: "<device> <mountpoint>"
    readarray -t PART_MOUNTS < <(
        lsblk -plno NAME,MOUNTPOINT "$CHOSEN_DRIVE" \
            | awk '$2 != "" {print $1, $2}' \
            | sort -u
    )

    TOTAL=${#PART_MOUNTS[@]}
    STEP=0

    for ENTRY in "${PART_MOUNTS[@]}"; do
        PART=$(awk '{print $1}' <<< "$ENTRY")
        MPOINT=$(awk '{print $2}' <<< "$ENTRY")
        STEP=$(( STEP + 1 ))
        PROGRESS=$(( 20 + (STEP * 40 / (TOTAL > 0 ? TOTAL : 1)) ))

        echo "$PROGRESS"
        echo "# Unmounting ${PART} (${MPOINT})..."

        # Primary: unmount via GVfs — releases file manager handles gracefully
        if GIO_ERR=$(gio mount -u "$MPOINT" 2>&1); then
            continue
        fi

        # Fallback: direct udisksctl unmount (for partitions not managed by GVfs)
        if UDISKS_ERR=$(udisksctl unmount -b "$PART" 2>&1); then
            continue
        fi

        # Both failed — report the gio error (more user-relevant) and the
        # udisksctl error for diagnostics
        printf 'FAILED:Could not unmount %s (%s):\ngio: %s\nudisksctl: %s' \
               "$PART" "$MPOINT" "$GIO_ERR" "$UDISKS_ERR" > "$RESULT_FILE"
        exit 1
    done

    echo "70"
    echo "# Powering off the drive..."

    if ! POWEROFF_ERR=$(udisksctl power-off -b "$CHOSEN_DRIVE" 2>&1); then
        # Check if the drive disappeared (some USB bridges auto-disconnect after
        # the last partition is unmounted — this is a success, not a failure)
        if ! lsblk "$CHOSEN_DRIVE" &>/dev/null; then
            printf 'SUCCESS' > "$RESULT_FILE"
        else
            printf 'FAILED_POWEROFF:%s' "$POWEROFF_ERR" > "$RESULT_FILE"
        fi
        exit 0
    fi

    printf 'SUCCESS' > "$RESULT_FILE"
    echo "90"
    echo "# Finalising..."
    sleep 1
    echo "100"
    echo "# Done! Safe to unplug."
    sleep 1

) | zenity --progress \
           --title="Ejecting ${CHOSEN_DRIVE}..." \
           --text="Preparing..." \
           --percentage=0 \
           --auto-close \
           --no-cancel \
           --width=440

echo "${PIPESTATUS[1]}" > "$PIPE_STATUS_FILE"

# =============================================================================
# STEP 6: Result handling with diagnostics
# =============================================================================
RESULT=$(cat "$RESULT_FILE" 2>/dev/null || true)
PIPE_EXIT=$(cat "$PIPE_STATUS_FILE" 2>/dev/null || echo "0")

if [[ -z "$RESULT" && "$PIPE_EXIT" != "0" ]]; then
    zenity --warning \
           --title="Eject Status Unknown" \
           --text="The eject dialog was closed before the operation completed.\n\n<b>Do not unplug the drive</b> until you verify its status.\n\nRun <tt>lsblk</tt> in a terminal to check." \
           --width=460
    exit 1
fi

case "$RESULT" in
    SUCCESS)
        zenity --info \
               --title="Drive Ejected" \
               --text="<b>It is now safe to unplug:</b>\n\n<b>${CHOSEN_DRIVE}</b>" \
               --width=340
        ;;

    FAILED_POWEROFF:*)
        # Partitions unmounted cleanly but the hardware power-off command failed.
        # This is common on USB bridges that ignore the ATA power-off command.
        # The drive is safe to unplug even without the spin-down signal.
        ERROR_DETAIL="${RESULT#FAILED_POWEROFF:}"
        zenity --warning \
               --title="Unmounted — Spin-Down Unavailable" \
               --text="<b>${CHOSEN_DRIVE}</b> has been unmounted safely, but the hardware power-off command was not supported by this drive's USB bridge.\n\nThe drive is safe to unplug.\n\n<small><tt>${ERROR_DETAIL}</tt></small>" \
               --width=520
        ;;

    FAILED:*)
        ERROR_DETAIL="${RESULT#FAILED:}"

        # Diagnostics: find which processes are still holding the drive open
        readarray -t DEVICES < <(lsblk -plno NAME     "$CHOSEN_DRIVE" 2>/dev/null || true)
        readarray -t MOUNTS  < <(lsblk -plno MOUNTPOINT "$CHOSEN_DRIVE" 2>/dev/null \
                                  | grep -v '^[[:space:]]*$' | sort -u || true)
        TARGETS=( "${DEVICES[@]}" "${MOUNTS[@]}" )
        BLOCKER_TABLE=""

        if [[ ${#TARGETS[@]} -gt 0 ]]; then
            RAW_LSOF=$(lsof -w -n -P -F pcun "${TARGETS[@]}" 2>/dev/null | awk '
                /^p/ { pid=substr($0,2) }
                /^c/ { cmd=substr($0,2) }
                /^u/ { usr=substr($0,2) }
                /^n/ { file=substr($0,2); print pid "|" cmd "|" usr "|" file }' | sort -u)

            if [[ -n "$RAW_LSOF" ]]; then
                BLOCKER_TABLE="$(printf '%-7s  %-14s  %-10s  %s\n' PID COMMAND USER FILE)\n"
                BLOCKER_TABLE+="$(printf '%-7s  %-14s  %-10s  %s\n' --- ------- ---- ----)\n"
                while IFS="|" read -r P C U F; do
                    F="${F//&/&amp;}"; F="${F//</&lt;}"; F="${F//>/&gt;}"
                    C="${C//&/&amp;}"; C="${C//</&lt;}"; C="${C//>/&gt;}"
                    U="${U//&/&amp;}"; U="${U//</&lt;}"; U="${U//>/&gt;}"
                    BLOCKER_TABLE+="$(printf '%-7s  %-14s  %-10s  %s\n' "$P" "$C" "$U" "$F")\n"
                done <<< "$RAW_LSOF"
                BLOCKER_SECTION="\n\n<b>Processes still holding the drive open:</b>\n<tt>${BLOCKER_TABLE}</tt>\n<b>Action required:</b> Close these applications and try again."
            else
                BLOCKER_SECTION="\n\n<i>No open files detected. A background service (thumbnail cache, automounter) may be holding a lock. Close your file manager, wait a moment, and retry.</i>"
            fi
        else
            BLOCKER_SECTION=""
        fi

        zenity --error \
               --title="Eject Failed" \
               --text="<b>Could not safely eject ${CHOSEN_DRIVE}.</b>${BLOCKER_SECTION}\n\n<small><tt>${ERROR_DETAIL}</tt></small>" \
               --width=720
        exit 1
        ;;

    *)
        zenity --error \
               --title="Unexpected Error" \
               --text="An unexpected error occurred.\n\n<b>Do not unplug the drive</b> until you verify its status.\n\nRun <tt>lsblk</tt> in a terminal to check." \
               --width=460
        exit 1
        ;;
esac

exit 0