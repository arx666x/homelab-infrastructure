#!/bin/bash
# Collect UUIDs from all nodes

NODES=(
    "achim@192.168.11.31:gmkt-01x:master01:nvme1n1p3"
    "achim@192.168.11.32:gmkt-02x:master02:nvme1n1p3"
    "achim@192.168.11.33:gmkt-03x:master03:nvme1n1p3"
    "achim@192.168.11.21:rpi5-01x:worker01:sda3"
    "achim@192.168.11.22:rpi5-02x:worker02:sda3"
    "achim@192.168.11.23:rpi5-03x:worker03:sda3"
    "achim@192.168.11.24:rpi5-04x:worker04:sda3"
    "achim@192.168.11.25:rpi5-05x:worker05:sda3"
)

echo "[master]"
for node in "${NODES[@]}"; do
    IFS=':' read -r ssh host inv part <<< "$node"
    if [[ "$inv" == master* ]]; then
        uuid=$(ssh $ssh "sudo blkid -s UUID -o value /dev/$part" 2>/dev/null)
        [ -n "$uuid" ] && echo "$inv ansible_host=192.168.20.${ssh##*.} mgmt_ip=${ssh#*@} hostname=$host var_disk=${part%p*} var_uuid=$uuid"
    fi
done

echo -e "\n[worker]"
for node in "${NODES[@]}"; do
    IFS=':' read -r ssh host inv part <<< "$node"
    if [[ "$inv" == worker* ]]; then
        uuid=$(ssh $ssh "sudo blkid -s UUID -o value /dev/$part" 2>/dev/null)
        [ -n "$uuid" ] && echo "$inv ansible_host=192.168.20.${ssh##*.} mgmt_ip=${ssh#*@} hostname=$host var_disk=${part%[0-9]*} var_uuid=$uuid"
    fi
done
