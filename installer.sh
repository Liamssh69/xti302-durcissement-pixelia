#!/bin/bash
# installer.sh
# Remet toute la config sur la VM vierge (a lancer depuis le dossier du depot)
# Seance 3 (C1 a C4, S1 a S5) + seance 4 (J1 a J4, D1)
# Lancement : sudo ./installer.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Erreur : ce script doit etre lance en root" >&2
    exit 1
fi

cd "$(dirname "$0")"


# --- paquets ---
# on passe par apt seulement si un paquet manque (le wifi de l'ecole bloque souvent)
for paquet in sudo openssh-server acl nftables fail2ban python3-systemd unattended-upgrades; do
    if ! dpkg -s "$paquet" > /dev/null 2>&1; then
        apt-get update || true
        apt-get install -y "$paquet"
    fi
done


# --- comptes, groupes, /srv (C1, C2) ---
bash creer_comptes.sh comptes.csv


# --- sudo (C3) ---
# analyse_logs.sh doit appartenir a root sinon support pourrait le modifier
# et lancer n'importe quoi en root avec sudo
cp analyse_logs.sh /usr/local/sbin/analyse_logs.sh
chown root:root /usr/local/sbin/analyse_logs.sh
chmod 755 /usr/local/sbin/analyse_logs.sh

# on verifie la syntaxe avant de copier, une erreur dans sudoers casse sudo
if ! visudo -cf config/sudoers.d/xti302; then
    echo "Erreur : fichier sudoers invalide" >&2
    exit 1
fi
cp config/sudoers.d/xti302 /etc/sudoers.d/xti302
chmod 440 /etc/sudoers.d/xti302

# personne d'autre ne doit avoir sudo : on vide le groupe sudo de debian
for u in $(getent group sudo | cut -d: -f4 | tr ',' ' '); do
    gpasswd -d "$u" sudo
done


# --- root et homes (C4) ---
passwd -l root
chmod 700 /home/*/


# --- SSH (S1 a S5) ---
# securite : si un admin a pas de cle on touche pas a SSH, sinon on se bloque dehors
for admin in $(getent group admins | cut -d: -f4 | tr ',' ' '); do
    if [ ! -s "/home/$admin/.ssh/authorized_keys" ]; then
        echo "Erreur : $admin n'a pas de cle SSH, je ne modifie pas SSH" >&2
        exit 1
    fi
done

cp config/ssh/sshd_config.d/*.conf /etc/ssh/sshd_config.d/

# S5 : on teste la config avant de redemarrer
if ! sshd -t; then
    echo "Erreur : config SSH invalide, pas de redemarrage" >&2
    exit 1
fi
systemctl restart ssh


# --- journal persistant (J3) ---
mkdir -p /etc/systemd/journald.conf.d /var/log/journal
cp config/journald.conf.d/persistant.conf /etc/systemd/journald.conf.d/
systemctl restart systemd-journald


# --- pare-feu (J2) ---
# nft -c = on verifie la syntaxe sans appliquer
if ! nft -c -f config/nftables.conf; then
    echo "Erreur : config nftables invalide" >&2
    exit 1
fi
cp config/nftables.conf /etc/nftables.conf
systemctl enable nftables
systemctl restart nftables


# --- fail2ban (J1) ---
# on le redemarre APRES nftables pour qu'il remette sa table
cp config/fail2ban/jail.d/sshd.local /etc/fail2ban/jail.d/
systemctl enable fail2ban
systemctl restart fail2ban


# --- mises a jour automatiques (D1) ---
cp config/apt/20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable apt-daily.timer apt-daily-upgrade.timer


echo "installation terminee, lancer : sudo ./verifier.sh"
