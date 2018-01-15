#!/bin/bash
#
# Merge Ephemeral Disks using RAID-0
# Copyright (c) Alexey Baikov <sysboss [at] mail.ru>
#
# This script will discover all ephemeral drives on an EC2 node
# and merge them using RAID-0 stripe
#
# EC2 Instance types supported:
#  - C (compute-intensive)

MOUNT_POINT="/dev/mnt"
METADATA_URL_BASE="http://169.254.169.254/2016-09-02"

# You must be a root user
if [[ $(id -u) -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Verify all required tools installed
TOOLS="curl partprobe mdadm"
for i in ${TOOLS}; do
    if ! which $i > /dev/null; then
        echo "$i is required."
        exit 2
    fi
done

function log {
    local msg=$1
    local datetime="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "${datetime}   ${msg}" #| tee -a ${LOGDIR}/boot.log
}

# Get instance purpose
INSTANCE_TYPE="$(curl -s http://169.254.169.254/latest/meta-data/instance-type | egrep -o '^[a-z]')"

case "${INSTANCE_TYPE}" in
"c")
    DRIVE_PREFIX="xvd"
    ;;
"i")
    DRIVE_PREFIX=""
    ;;
*)
    echo "${INSTANCE_TYPE}-Type instance in not supported or missing ephemeral disk(s)"
    exit 2
    ;;
esac

# Discover available drives
# exclude root drive
root_drive=$(mount | egrep " on / " | egrep -o "^/dev/[a-z]*")

# Discover available ephemerals
ephemerals=$(curl -s ${METADATA_URL_BASE}/meta-data/block-device-mapping/ | grep ephemeral)

ephemerals_count=0
ephemerals_array=""

for drive in ${ephemerals}; do
    device_name=$(curl -s ${METADATA_URL_BASE}/meta-data/block-device-mapping/${drive})

    # fix drive prefix
    device_name=$(echo ${device_name} | sed "s/sd/${DRIVE_PREFIX}/")
    device_path="/dev/${device_name}"

    # verify device exist
    if [ -b ${device_path} ]; then
        if [ "${device_path}" != "${root_drive}" ]; then
            log "Detected ephemeral disk: ${device_path}"

            ephemerals_array="${ephemerals_array} ${device_path}"
            ephemerals_count=$((ephemerals_count + 1))
        else
            log "WARNING ${device_path} is a root drive. skipping"
        fi
    else
        log "WARNING Ephemeral drive ${drive} (${drive_path}) does not exist. skipping"
    fi
done

if [ "${ephemerals_count}" == 0 ]; then
    log "No ephemeral disk detected. exiting"
    exit 0
fi

log "${ephemerals_count} ephemeral disks detected"

# ephemeral0 is typically mounted for us already. umount it
umount /mnt 2>/dev/null

# overwrite first few blocks in case there is a filesystem, otherwise mdadm will prompt for input
for drive in $ephemerals_array; do
    log "Formatting ${drive}"
    dd if=/dev/zero of=$drive bs=4096 count=1024
done

partprobe

log "Creating software RAID0 (stripe)"
mdadm --create --verbose /dev/md0 --level=0 -c256 --raid-devices=${ephemerals_count} ${ephemerals_array}

if [ $? -ne 0 ]; then
    log "ERROR Failed to create software raid"
    exit 2
fi

sleep 1

if [ ! -b /dev/md0 ]; then
    log "ERROR Raid device /dev/md0 not found"
    exit 2
fi

# save configuration
echo DEVICE ${ephemerals_array} | tee /etc/mdadm.conf
mdadm --detail --scan | tee -a /etc/mdadm.conf

blockdev --setra 65536 /dev/md0

log "Create a ext4 filesystem for a RAID device /dev/md0"
mkfs.ext4 /dev/md0

# mount raid device
log "Mounting raid device to ${MOUNT_POINT}"
mount /dev/md0 ${MOUNT_POINT}

if [ $? -ne 0 ]; then
    log "ERROR Failed to mount raid device /dev/md0 to ${MOUNT_POINT}"
    exit 2
fi

# Remove ephemerals from fstab
sed -i "/${DRIVE_PREFIX}b/d" /etc/fstab

# Mount raid on reboot
echo "/dev/md0    ${MOUNT_POINT} ext4 noatime 0 0" > /etc/fstab

log "Success!"
exit 0
