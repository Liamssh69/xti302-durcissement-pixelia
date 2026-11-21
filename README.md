# Projet XTI302 - Durcir un serveur Linux et le prouver

Contexte choisi : **A - Agence web Pixelia**

## Prerequis
- VM Debian 13 minimale avec SSH
- un 2e disque de 1 a 2 Go pour les sauvegardes (`/dev/sdb`, a changer dans installer.sh si besoin)
- les cles publiques des comptes qui ont acces en SSH dans `config/keys/<login>.pub`

## Installer
Depuis le dossier du depot, sur la VM :
```
sudo ./installer.sh
```
Attention : le script verrouille root et coupe la connexion SSH par mot de passe.
Garder une session SSH ouverte et tester dans une 2e fenetre avant de fermer.

## Verifier
```
sudo ./verifier.sh
```
Renvoie 0 si tout est bon, 1 sinon.

## Fichiers
- `comptes.csv` : la liste des comptes (pas de mots de passe dedans)
- `creer_comptes.sh` : groupes, comptes, cles, dossiers de /srv avec les ACL
- `installer.sh` : remet toute la config sur une VM vierge
- `verifier.sh` : teste chaque exigence
- `analyse_logs.sh` : rapport des connexions SSH (seul script que support peut lancer en sudo)
- `sauvegarde.sh` : sauvegarde de /srv et /etc sur le 2e disque (rsync, versions datees)
- `config/` : config SSH, sudoers, pare-feu nftables, fail2ban, journald, mises a jour auto, timer de sauvegarde, cles publiques, liste des SUID
- `DOSSIER.md` : conformite, choix techniques, defense, restauration
