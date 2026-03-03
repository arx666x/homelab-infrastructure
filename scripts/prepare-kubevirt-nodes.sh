#!/bin/bash
# =============================================================================
# KubeVirt Node-Vorbereitung fuer AMD64-Nodes (GMKtec NucBox M5 Ultra)
#
# Nutzung:
#   ./scripts/prepare-kubevirt-nodes.sh                 # alle AMD64-Nodes
#   ./scripts/prepare-kubevirt-nodes.sh 192.168.20.11   # einzelner Node
#   SSH_USER=root ./scripts/prepare-kubevirt-nodes.sh   # anderer SSH-User
# =============================================================================
set -euo pipefail

AMD64_NODES=("192.168.20.31" "192.168.20.32" "192.168.20.33")

if [ $# -eq 1 ]; then
  AMD64_NODES=("$1")
  echo "==> Einzelner Node: $1"
fi

SSH_USER="${SSH_USER:-achim.reckeweg}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

REMOTE='
set -euo pipefail
H=$(hostname)
log()  { echo "[$H] $*"; }
ok()   { echo "[$H] [OK] $*"; }
fail() { echo "[$H] [FEHLER] $*" >&2; exit 1; }

log "=== KubeVirt Node-Vorbereitung ==="

# 1. CPU-Vendor bestimmen (zuverlaessiger als vmx/svm Flag-Matching)
VENDOR=$(grep -m1 "vendor_id" /proc/cpuinfo | awk "{print \$3}")
log "CPU vendor_id: $VENDOR"

if [ "$VENDOR" = "AuthenticAMD" ]; then
  KVM_MOD="kvm_amd"
elif [ "$VENDOR" = "GenuineIntel" ]; then
  KVM_MOD="kvm_intel"
else
  fail "Unbekannter CPU-Vendor: $VENDOR"
fi
log "KVM-Modul: $KVM_MOD"

# Kreuzcheck: Virtualisierungs-Flag muss vorhanden sein
VIRT=$(grep -m1 -oE "vmx|svm" /proc/cpuinfo || true)
[ -z "$VIRT" ] && fail "Kein vmx/svm Flag - Virtualisierung im BIOS aktiviert?"
log "Virtualisierungs-Flag: $VIRT"

# 2. KVM-Module laden (idempotent)
log "Lade KVM-Module..."
lsmod | grep -q "^kvm "      && ok "kvm bereits geladen"      || sudo modprobe kvm
lsmod | grep -q "^${KVM_MOD} " && ok "$KVM_MOD bereits geladen" || sudo modprobe "$KVM_MOD"
ok "Module aktiv: kvm + $KVM_MOD"

# 3. Dauerhaftes Laden konfigurieren
sudo tee /etc/modules-load.d/kubevirt-kvm.conf > /dev/null << MEOF
# KVM fuer KubeVirt - generiert durch prepare-kubevirt-nodes.sh
kvm
$KVM_MOD
MEOF
ok "/etc/modules-load.d/kubevirt-kvm.conf geschrieben"

# 4. /dev/kvm pruefen und Berechtigungen setzen
[ ! -e /dev/kvm ] && fail "/dev/kvm fehlt trotz geladenem Modul - BIOS pruefen"
sudo tee /etc/udev/rules.d/99-kvm.rules > /dev/null << UEOF
KERNEL=="kvm", GROUP="kvm", MODE="0666"
UEOF
sudo udevadm control --reload-rules && sudo udevadm trigger
ok "/dev/kvm: $(ls -la /dev/kvm)"

# 5. qemu-utils installieren
if dpkg -l qemu-utils 2>/dev/null | grep -q "^ii"; then
  ok "qemu-utils bereits installiert: $(qemu-img --version | head -1)"
else
  sudo apt-get update -qq && sudo apt-get install -y -qq qemu-utils
  ok "qemu-utils installiert: $(qemu-img --version | head -1)"
fi

# 6. Hugepages (2048 x 2MB = 4GB fuer Windows-AD VM)
HCONF="/etc/sysctl.d/99-kubevirt.conf"
if [ -f "$HCONF" ] && grep -q "nr_hugepages" "$HCONF"; then
  ok "Hugepages: $(grep HugePages_Total /proc/meminfo)"
else
  sudo tee "$HCONF" > /dev/null << SEOF
vm.nr_hugepages = 2048
SEOF
  sudo sysctl -p "$HCONF" > /dev/null
  ok "Hugepages gesetzt: $(grep HugePages_Total /proc/meminfo)"
fi

# 7. Abschlusspruefung
echo ""
log "=== Ergebnis ==="
ok "Vendor    : $VENDOR"
ok "kvm       : $(lsmod | grep "^kvm " | awk "{print \$1,\$2}")"
ok "$KVM_MOD : $(lsmod | grep "^${KVM_MOD} " | awk "{print \$1,\$2}")"
ok "/dev/kvm  : $(ls -la /dev/kvm)"
ok "qemu-img  : $(qemu-img --version | head -1)"
ok "Hugepages : $(grep HugePages_Total /proc/meminfo)"
echo ""
ok "Node bereit fuer KubeVirt."
'

FAILED=()
SUCCESS=()

echo "==> KubeVirt Node-Vorbereitung"
echo "==> User: $SSH_USER | Nodes: ${AMD64_NODES[*]}"
echo ""

for NODE in "${AMD64_NODES[@]}"; do
  echo "--- $NODE ---"
  if ssh $SSH_OPTS "${SSH_USER}@${NODE}" "echo 'SSH OK'" 2>/dev/null; then
    if ssh $SSH_OPTS "${SSH_USER}@${NODE}" bash -s <<< "$REMOTE"; then
      SUCCESS+=("$NODE")
    else
      echo "[!!] Fehler auf $NODE"
      FAILED+=("$NODE")
    fi
  else
    echo "[!!] SSH nicht erreichbar: $NODE"
    FAILED+=("$NODE")
  fi
  echo ""
done

echo "=== ZUSAMMENFASSUNG ==="
[ ${#SUCCESS[@]} -gt 0 ] && printf "  [OK] %s\n" "${SUCCESS[@]}"
[ ${#FAILED[@]}  -gt 0 ] && printf "  [!!] %s\n" "${FAILED[@]}" && exit 1
echo "Alle Nodes vorbereitet."
