#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Variables globales
LOCKFILE="/var/run/repair_debian.lock"
LOGDIR="/var/log/repair_debian"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/repair_$(date +%Y%m%d_%H%M%S).log"
CRYPT_NAME="cryptroot"

# Fonction de log avec timestamp et sauvegarde dans fichier log
log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"
}

# Gestion d'erreur : log l'erreur, nettoyage et sortie du script
error_exit() {
  log "ERREUR: $*"
  cleanup
  exit 1
}

# Tentative de démontage safe, avec fallback démontage lazy si nécessaire
safe_umount() {
  local target=$1
  if mountpoint -q "$target"; then
    log "Démontage de $target..."
    if ! umount "$target"; then
      log "Echec démontage $target, tentative forcée (lazy)..."
      umount -l "$target" || log "Impossible de démonter $target"
    fi
  else
    log "$target non monté, passage."
  fi
}

# Nettoyage complet à la fin ou en cas d'erreur : démontage, fermeture LUKS, suppression lockfile
cleanup() {
  log "Nettoyage..."
  safe_umount /mnt/dev
  safe_umount /mnt/proc
  safe_umount /mnt/sys
  safe_umount /mnt/boot/efi
  safe_umount /mnt/boot
  safe_umount /mnt

  if cryptsetup status "$CRYPT_NAME" &>/dev/null; then
    log "Fermeture volume LUKS $CRYPT_NAME..."
    cryptsetup luksClose "$CRYPT_NAME" || log "Impossible fermer $CRYPT_NAME"
  fi

  if [ -f "$LOCKFILE" ]; then
    rm -f "$LOCKFILE"
    log "Lockfile supprimé."
  fi
  log "Nettoyage terminé."
}
trap cleanup EXIT INT TERM

# Empêche l'exécution multiple du script via un lockfile
acquire_lock() {
  if [ -e "$LOCKFILE" ]; then
    error_exit "Script déjà en cours (lock: $LOCKFILE)"
  else
    echo $$ > "$LOCKFILE"
    log "Lock acquis."
  fi
}

# Vérifie la présence des paquets nécessaires, installe si manquant via apt
check_and_install() {
  local pkgs=(cryptsetup lvm2 grub-common grub-pc grub-efi-amd64 dosfstools e2fsprogs)
  local missing=()
  for p in "${pkgs[@]}"; do
    if ! command -v "$p" >/dev/null 2>&1; then
      missing+=("$p")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    log "Packages manquants détectés : ${missing[*]}"
    log "Tentative d'installation automatique via apt..."
    apt update && apt install -y "${missing[@]}" || error_exit "Installation des dépendances échouée"
  else
    log "Toutes les dépendances sont installées."
  fi
}

# Menu interactif simple pour sélectionner une option dans une liste
menu_select() {
  local prompt=$1
  shift
  local options=("$@")
  local opt

  echo
  echo "$prompt"
  for i in "${!options[@]}"; do
    echo "  $((i+1))) ${options[i]}"
  done

  while true; do
    read -rp "Choix [1-${#options[@]}] : " opt
    if [[ "$opt" =~ ^[1-9][0-9]*$ ]] && (( opt >= 1 && opt <= ${#options[@]} )); then
      echo "${options[$((opt-1))]}"
      return
    else
      echo "Choix invalide."
    fi
  done
}

# Détecte si le système a booté en mode UEFI ou BIOS legacy
detect_boot_mode() {
  if [ -d /sys/firmware/efi ]; then
    log "Mode boot détecté : UEFI"
    BOOT_MODE="UEFI"
  else
    log "Mode boot détecté : LEGACY BIOS"
    BOOT_MODE="LEGACY"
  fi
}

# Recherche la partition EFI pour les systèmes UEFI
detect_efi_partition() {
  EFI_PART=""
  # Par défaut, on cherche partition EFI montée
  EFI_PART=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || true)
  if [ -n "$EFI_PART" ]; then
    log "Partition EFI montée détectée: $EFI_PART"
    return
  fi
  # Sinon, chercher par label 'EFI' ou type vfat avec partition esp
  EFI_PART=$(lsblk -plno NAME,PARTLABEL,PARTTYPE,FSTYPE | grep -i -E 'efi|esp|vfat' | head -n1 | awk '{print $1}')
  if [ -n "$EFI_PART" ]; then
    log "Partition EFI détectée : $EFI_PART"
  else
    log "Pas de partition EFI détectée."
  fi
}

# Ouvre une partition LUKS si présente, sinon retourne la partition brute
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

# Active les volumes logiques LVM si présents sur le device donné
activate_lvm() {
  local dev=$1
  if pvs 2>/dev/null | grep -q "$dev"; then
    log "LVM détecté sur $dev, activation des volumes logiques..."
    vgchange -ay
    return 0
  else
    log "Pas de LVM détecté sur $dev."
    return 1
  fi
}

# Lance une vérification fsck forcée sur la partition spécifiée
check_fs() {
  local part=$1
  log "Vérification système fichiers sur $part"
  fsck -f -y "$part"
}

# Monte la racine, /boot (si séparé) et la partition EFI (en UEFI)
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

  log "Montage bind /dev, /proc, /sys"
  mount --bind /dev /mnt/dev
  mount --bind /proc /mnt/proc
  mount --bind /sys /mnt/sys
}

# Démontage complet et safe de tous les points de montage utilisés
umount_all() {
  safe_umount /mnt/dev
  safe_umount /mnt/proc
  safe_umount /mnt/sys
  safe_umount /mnt/boot/efi
  safe_umount /mnt/boot
  safe_umount /mnt
}

# Réinstallation de GRUB selon mode boot sur le disque sélectionné
reinstall_grub() {
  local disk=$1
  log "Réinstallation GRUB sur $disk en mode $BOOT_MODE"
  if [ "$BOOT_MODE" = "UEFI" ]; then
    chroot /mnt /bin/bash -c "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck"
  else
    chroot /mnt /bin/bash -c "grub-install $disk"
  fi
  chroot /mnt /bin/bash -c "update-grub"
}

# Fonction principale orchestrant toutes les étapes
main() {
  acquire_lock
  check_and_install

  log "Détection des disques disponibles..."
  mapfile -t DISKS < <(lsblk -dn -o NAME,SIZE,MODEL | awk '{print "/dev/"$1 " - " $2 " " $3}')

  DISK=$(menu_select "Sélectionne le disque à réparer :" "${DISKS[@]}")
  DISK_NAME=$(echo "$DISK" | cut -d' ' -f1)

  log "Partitions du disque $DISK_NAME :"
  mapfile -t PARTS < <(lsblk -ln -o NAME,SIZE,TYPE,MOUNTPOINT "$DISK_NAME" | grep part | awk '{print "/dev/"$1 " - " $2}')

  PART_ROOT=$(menu_select "Sélectionne la partition racine (peut être LUKS) :" "${PARTS[@]}")
  PART_ROOT_NAME=$(echo "$PART_ROOT" | cut -d' ' -f1)

  DEV_AFTER_LUKS=$(open_luks "$PART_ROOT_NAME")

  if activate_lvm "$DEV_AFTER_LUKS"; then
    log "Volumes logiques LVM disponibles :"
    mapfile -t LVs < <(lvs --noheadings -o lv_path | sed 's/^ *//g')
    if [ ${#LVs[@]} -eq 0 ]; then
      error_exit "Aucun volume logique LVM trouvé."
    fi
    LV_ROOT=$(menu_select "Sélectionne le volume logique racine :" "${LVs[@]}")
    ROOT_PART="$LV_ROOT"
  else
    ROOT_PART="$DEV_AFTER_LUKS"
  fi

  log "Partitions du disque $DISK_NAME :"
  mapfile -t PARTS2 < <(lsblk -ln -o NAME,SIZE,TYPE,MOUNTPOINT "$DISK_NAME" | grep part | awk '{print "/dev/"$1 " - " $2}')
  BOOT_PART=$(menu_select "Sélectionne la partition /boot (vide si pas séparée) :" "Aucune" "${PARTS2[@]}")

  if [[ "$BOOT_PART" == "Aucune" ]]; then
    BOOT_PART=""
  else
    BOOT_PART=$(echo "$BOOT_PART" | cut -d' ' -f1)
  fi

  detect_boot_mode

  check_fs "$ROOT_PART"
  [ -z "$BOOT_PART" ] || check_fs "$BOOT_PART"

  mount_all "$ROOT_PART" "$BOOT_PART"

  reinstall_grub "$DISK_NAME"

  umount_all

  if cryptsetup status "$CRYPT_NAME" &>/dev/null; then
    log "Fermeture volume LUKS $CRYPT_NAME..."
    cryptsetup luksClose "$CRYPT_NAME"
  fi

  rm -f "$LOCKFILE"
  log "Réparation terminée avec succès."
}

main "$@"
