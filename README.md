# Script de Réparation Système Debian — Support LVM, LUKS, BIOS & UEFI  
*Version 1.0.0* | *Date : 2025-06-24*

---

## Table des matières

- [Présentation](#présentation)  
- [Objectifs et philosophie](#objectifs-et-philosophie)  
- [Fonctionnalités avancées](#fonctionnalités-avancées)  
- [Architecture technique](#architecture-technique)  
- [Prérequis techniques](#prérequis-techniques)  
- [Installation et déploiement](#installation-et-déploiement)  
- [Utilisation détaillée](#utilisation-détaillée)  
- [Gestion des environnements](#gestion-des-environnements)  
- [Sécurité et conformité](#sécurité-et-conformité)  
- [Gestion des erreurs, logs et monitoring](#gestion-des-erreurs-logs-et-monitoring)  
- [Extensibilité et maintenance](#extensibilité-et-maintenance)  
- [Scénarios d’utilisation](#scénarios-dutilisation)  
- [Limitations et avertissements](#limitations-et-avertissements)  
- [Contribution et roadmap](#contribution-et-roadmap)  
- [Licence et mentions légales](#licence-et-mentions-légales)  
- [Contacts et support](#contacts-et-support)  

---

## Présentation

Ce script Bash, conçu pour les environnements Debian et dérivés, est un outil complet d’analyse, diagnostic et réparation des systèmes affectés par des problèmes liés aux disques, aux partitions, au gestionnaire de volumes logiques (LVM) et au chiffrement des volumes (LUKS).  

Conçu pour des administrateurs systèmes professionnels, ce script offre une interface interactive robuste, garantissant la sécurité et la fiabilité des opérations sensibles tout en automatisant les tâches complexes.

---

## Objectifs et philosophie

- **Automatisation intelligente** : minimiser les interventions manuelles tout en conservant un contrôle strict par l’administrateur.  
- **Polyvalence maximale** : gérer tous les types de configurations courantes et avancées (partitions classiques, LVM, LUKS, BIOS Legacy, UEFI).  
- **Sécurité renforcée** : privilégier la sécurité des données, éviter toute opération destructive sans confirmation explicite, protéger les saisies sensibles (passphrases LUKS).  
- **Transparence** : fournir des logs détaillés, afficher les étapes critiques, permettre une reprise facile après interruption.  
- **Compatibilité et portabilité** : conçu pour fonctionner sur Debian stable et ses dérivés, dans divers environnements matériels.

---

## Fonctionnalités avancées

- **Détection automatisée** des disques et partitions, avec identification précise des volumes LVM et LUKS.  
- **Activation intelligente** des volumes LVM, prise en charge multi-groupe et multi-volume.  
- **Gestion complète du chiffrement LUKS** : détection, demande sécurisée des passphrases, déchiffrement, montage.  
- **Montage et démontage sûrs** des partitions, avec gestion des points de montage et verrouillage (lock).  
- **Vérification systématique** des systèmes de fichiers via `fsck` adapté au type de FS détecté (ext4, xfs, btrfs, etc.).  
- **Réparation automatique** du chargeur de démarrage GRUB, avec prise en charge BIOS Legacy et UEFI, gestion des EFI System Partitions (ESP).  
- **Installation automatique** des dépendances critiques (`lvm2`, `cryptsetup`, `grub-pc`, `grub-efi`, etc.), avec vérification et mise à jour.  
- **Interface utilisateur interactive** avec menus clairs, aide contextuelle, validation de chaque action.  
- **Logging exhaustif** dans un fichier dédié (`/var/log/repair_debian.log`), avec rotation et gestion des erreurs.  
- **Gestion des erreurs robuste** : reprise en cas d’interruption, rollback partiel, alertes utilisateur.  
- **Support complet BIOS/UEFI**, avec détection automatique et ajustement des procédures.

---

## Architecture technique

- **Langage** : Bash, pour compatibilité maximale en environnement Linux natif.  
- **Modularité** : découpage en fonctions dédiées, chacune documentée et testée indépendamment.  
- **Gestion des dépendances** : vérification en début d’exécution, installation automatique si nécessaires via `apt`.  
- **Détection matérielle** : exploitation de `lsblk`, `blkid`, `cryptsetup`, `lvm` pour la collecte des infos système.  
- **Interface utilisateur** : menu interactif via `select` ou équivalent Bash, complété par des confirmations explicites.  
- **Sécurité** : protection des passphrases, vérification des droits root, gestion stricte des permissions.  
- **Logging** : sortie standard et fichiers logs synchronisés, avec niveaux de verbosité configurables.

---

## Prérequis techniques

- Debian stable ou dérivé (Ubuntu, etc.) avec Bash ≥ 4.0  
- Accès root (direct ou via sudo)  
- Connexion internet recommandée pour installation paquets  
- Espace disque suffisant pour monter volumes et écrire logs  
- Terminal supportant UTF-8 pour affichage optimal

---

## Installation et déploiement

1. Télécharger le script :  
   ```bash
   wget https://raw.githubusercontent.com/ps81frt/debrepair/refs/heads/main/debrepair.sh -O /usr/local/bin/debrepair.sh
