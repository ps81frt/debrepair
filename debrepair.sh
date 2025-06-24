#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# === CONFIG ===
LOCKFILE="/var/run/repair_debian.lock"
LOGDIR="/var/log/repair_debian"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/repair_$(date +%Y%m%d_%H%M%S).log"
CRYPT_NAME="cryptroot"  # nom utilisé pour luksOpen

# === UTILITAIRES ===

log() {
  echo "[$(date '+%F %T')] $*"
}

error_exit() {
  log "ERREUR: $*"
  cleanup
  exit 1
}

safe_umount() {
  local target=$1
  if mountpoint -q "$target"; then
    log "Démontage de $target..."
    if ! umount "$target"; then
      log "Échec du démontage de $target, tentative forcée (lazy)..."
      umount -l "$target" || log "Impossible de démonter $target"
    fi
  else
    log "$target non monté, passage."
  fi
}

check_command() {
  command -v "$1" >/dev/null 2>&1 || error_exit "Commande requise manquante: $1"
}

cleanup() {
  log "Nettoyage en cours..."
  safe_umount /mnt/dev
  safe_umount /mnt/proc
  safe_umount /mnt/sys
  safe_umount /mnt/boot/efi
  safe_umount /mnt/boot
  safe_umount /mnt

  if cryptsetup status "$CRYPT_NAME" &>/dev/null; then
    log "Fermeture volume LUKS $CRYPT_NAME..."
    cryptsetup luksClose "$CRYPT_NAME" || log "Impossible de fermer $CRYPT_NAME"
  fi

  if [ -f "$LOCKFILE" ]; then
    rm -f "$LOCKFILE"
    log "Fichier lock supprimé."
  fi
  log "Nettoyage terminé."
}
trap cleanup EXIT INT TERM

acquire_lock() {
  if [ -e "$LOCKFILE" ]; then
    error_exit "Script déjà en cours d'exécution (lock: $LOCKFILE)"
  else
    echo $$ > "$LOCKFILE"
    log "Lock acquis ($LOCKFILE)."
  fi
}

# === DÉTECTION DU MODE DE BOOT ===
detect_boot_mode() {
  if [ -d /sys/firmware/efi ]; then
    log "Mode de démarrage : UEFI détecté"
    BOOT_MODE="UEFI"
  else
    log "Mode de démarrage : Legacy BIOS détecté"
    BOOT_MODE="LEGACY"
  fi
}

# === DÉTECTION PARTITION EFI (UEFI) ===
detect_efi_partition() {
  # Recherche partition EFI montée ou labelée "EFI"
  EFI_PART=""
  EFI_MOUNTPOINT=$(findmnt -n -o TARGET -T /boot/efi || true)
  if [ -n "$EFI_MOUNTPOINT" ]; then
    EFI_PART=$(findmnt -n -o SOURCE -T "$EFI_MOUNTPOINT")
    log "Partition EFI déjà montée sur $EFI_MOUNTPOINT : $EFI_PART"
  else
    # Recherche par label dans partitions du disque
    EFI_PART=$(lsblk -lno NAME,PARTLABEL | grep -i efi | awk '{print $1}' | head -n1)
    if [ -n "$EFI_PART" ]; then
      EFI_PART="/dev/$EFI_PART"
      log "Partition EFI détectée (non montée) : $EFI_PART"
    else
      log "Partition EFI introuvable."
    fi
  fi
}

# === DÉTECTION ET DÉVERROUILLAGE LUKS ===
open_luks() {
  local part=$1
  if cryptsetup isLuks "$part" 2>/dev/null; then
    log "LUKS détecté sur $part, déverrouillage..."
    cryptsetup luksOpen "$part" "$CRYPT_NAME"
    echo "/dev/mapper/$CRYPT_NAME"
  else
    log "Pas de LUKS sur $part."
    echo "$part"
  fi
}

# === DÉTECTION LVM ===
activate_lvm() {
  local dev=$1
  if pvs | grep -q "$dev"; then
    log "LVM détecté sur $dev, activation des volumes logiques..."
    vgchange -ay
    return 0
  else
    log "Pas de LVM détecté sur $dev."
    return 1
  fi
}

# === VÉRIFICATION FS ===
check_fs() {
  local part=$1
  log "Vérification du système de fichiers sur $part"
  fsck -f -y "$part"
}

# === MONTAGE ===
mount_all() {
  local root=$1
  local boot=$2

  log "Montage racine $root sur /mnt"
  mount "$root" /mnt

  if [ -n "$boot" ]; then
    log "Montage /boot $boot"
    mkdir -p /mnt/boot
    mount "$boot" /mnt/boot
  fi

  if [ "$BOOT_MODE" = "UEFI" ]; then
    detect_efi_partition
    if [ -n "$EFI_PART" ]; then
      log "Montage partition EFI $EFI_PART sur /mnt/boot/efi"
      mkdir -p /mnt/boot/efi
      mount "$EFI_PART" /mnt/boot/efi
    else
      log "Aucune partition EFI montée - risque pour démarrage UEFI"
    fi
  fi

  log "Montage des pseudo-systèmes /dev, /proc, /sys"
  mount --bind /dev /mnt/dev
  mount --bind /proc /mnt/proc
  mount --bind /sys /mnt/sys
}

# === DÉMONTAGE ===
umount_all() {
  safe_umount /mnt/dev
  safe_umount /mnt/proc
  safe_umount /mnt/sys
  safe_umount /mnt/boot/efi
  safe_umount /mnt/boot
  safe_umount /mnt
}

# === RÉINSTALLATION GRUB ===
reinstall_grub() {
  local disk=$1
  log "Réinstallation de GRUB sur $disk en mode $BOOT_MODE..."

  if [ "$BOOT_MODE" = "UEFI" ]; then
    chroot /mnt /bin/bash -c "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck"
  else
    chroot /mnt /bin/bash -c "grub-install $disk"
  fi

  chroot /mnt /bin/bash -c "update-grub"
}

# === SCRIPT PRINCIPAL ===

main() {
  acquire_lock

  # Vérifier commandes indispensables
  for cmd in cryptsetup vgchange lvs lsblk fsck grub-install update-grub; do
    check_command "$cmd"
  done

  # Liste des disques
  log "Disques disponibles :"
  lsblk -d -o NAME,SIZE,MODEL

  read -rp "Indique le disque à réparer (ex: sda) : " DISK
  DISK="/dev/$DISK"
  [ -b "$DISK" ] || error_exit "Disque $DISK introuvable."

  # Partitions disque
  log "Partitions sur $DISK :"
  lsblk "$DISK"

  read -rp "Indique la partition racine (LUKS ou non) (ex: sda2) : " PART_ROOT
  PART_ROOT="/dev/$PART_ROOT"
  [ -b "$PART_ROOT" ] || error_exit "Partition $PART_ROOT introuvable."

  DEV_AFTER_LUKS=$(open_luks "$PART_ROOT")

  if activate_lvm "$DEV_AFTER_LUKS"; then
    log "Volumes logiques LVM disponibles :"
    lvs --noheadings -o lv_path

    read -rp "Indique le volume logique racine (ex: /dev/vgname/lvroot) : " LV_ROOT
    [ -b "$LV_ROOT" ] || error_exit "Volume logique $LV_ROOT introuvable."

    ROOT_PART="$LV_ROOT"
  else
    ROOT_PART="$DEV_AFTER_LUKS"
  fi

  # Partition /boot optionnelle
  log "Partitions disponibles :"
  lsblk

  read -rp "Indique la partition /boot séparée (vide si non existante) : " BOOT_PART
  if [ -n "$BOOT_PART" ]; then
    BOOT_PART="/dev/$BOOT_PART"
    [ -b "$BOOT_PART" ] || error_exit "/boot spécifié non trouvé."
  else
    BOOT_PART=""
  fi

  detect_boot_mode

  # fsck
  check_fs "$ROOT_PART"
  [ -z "$BOOT_PART" ] || check_fs "$BOOT_PART"

  # Montage
  mount_all "$ROOT_PART" "$BOOT_PART"

  # Réinstallation grub
  reinstall_grub "$DISK"

  # Nettoyage
  umount_all

  if cryptsetup status "$CRYPT_NAME" &>/dev/null; then
    log "Fermeture du volume LUKS $CRYPT_NAME..."
    cryptsetup luksClose "$CRYPT_NAME"
  fi

  rm -f "$LOCKFILE"
  log "Réparation terminée avec succès. Redémarrage possible."
}

main "$@"
