#!/bin/bash
# verifier.sh
# Teste toutes les exigences et affiche [OK] ou [KO] pour chaque test
# Ne modifie rien sur le systeme (sauf un fichier de test qu'on supprime)
# Lancement : sudo ./verifier.sh
# Code de sortie : 0 si tout est OK, 1 sinon
#
# Pas de set -e ici : les tests lancent expres des commandes qui echouent
# (ex : commercial qui essaie de lire /srv/projets), le script s'arreterait.
# Pas de pipefail non plus : avec "commande | grep -q" ca peut donner des faux KO.

CSV="comptes.csv"
total=0
reussis=0

cd "$(dirname "$0")" || exit 1

if [ "$(id -u)" -ne 0 ]; then
    echo "Erreur : lancer en root (sudo)" >&2
    exit 1
fi

ok() {
    total=$((total + 1))
    reussis=$((reussis + 1))
    echo -e "\e[32m[OK]\e[0m $1 $2"
}

ko() {
    total=$((total + 1))
    echo -e "\e[31m[KO]\e[0m $1 $2"
}

# affiche OK si la commande juste avant a marche, KO sinon
resultat() {
    if [ $? -eq 0 ]; then ok "$1" "$2"; else ko "$1" "$2"; fi
}

# premier utilisateur du csv qui a ce groupe principal
utilisateur_du_groupe() {
    grep ";$1;" "$CSV" | head -n 1 | cut -d';' -f1
}

DEV=$(utilisateur_du_groupe dev)
DESIGN=$(utilisateur_du_groupe design)
COMMERCIAL=$(utilisateur_du_groupe commercial)
FREELANCE=$(utilisateur_du_groupe freelance)

# lire un dossier = droit r + x, ecrire dedans = droit w + x
peut_lire()   { sudo -u "$1" test -r "$2" -a -x "$2"; }
peut_ecrire() { sudo -u "$1" test -w "$2" -a -x "$2"; }

# valeur d'une option ssh dans la config finale (sshd -T affiche tout en minuscules)
option_ssh() { sshd -T | grep "^$1 " | cut -d' ' -f2-; }


test_C1() {
    # chaque compte du csv existe et a les bons groupes
    erreur=0
    while IFS=';' read -r login _ groupe autres; do
        if ! id "$login" > /dev/null 2>&1; then
            ko "C1" "le compte $login n'existe pas"
            erreur=1
            continue
        fi
        if [ "$(id -gn "$login")" != "$groupe" ]; then
            ko "C1" "$login n'a pas $groupe comme groupe principal"
            erreur=1
        fi
        for g in $(echo "$autres" | tr ',' ' '); do
            if ! id -nG "$login" | grep -qw "$g"; then
                ko "C1" "$login n'est pas dans le groupe $g"
                erreur=1
            fi
        done
    done < <(tail -n +2 "$CSV" | tr -d '\r')
    if [ $erreur -eq 0 ]; then
        ok "C1" "tous les comptes du CSV existent avec les bons groupes"
    fi

    erreur=0
    for g in admins support acces_ssh dev design commercial freelance; do
        getent group "$g" > /dev/null || erreur=1
    done
    [ $erreur -eq 0 ]
    resultat "C1" "les 7 groupes existent"

    LC_ALL=C chage -l "$FREELANCE" | grep "Account expires" | grep -qv never
    resultat "C1" "le compte freelance $FREELANCE a une date d'expiration"
}


test_C2() {
    peut_ecrire "$DEV" /srv/projets
    resultat "C2" "dev peut ecrire dans /srv/projets"
    peut_lire "$DESIGN" /srv/projets
    resultat "C2" "design peut lire /srv/projets"
    ! peut_ecrire "$DESIGN" /srv/projets
    resultat "C2" "design ne peut pas ecrire dans /srv/projets"
    ! peut_lire "$COMMERCIAL" /srv/projets
    resultat "C2" "commercial ne peut pas lire /srv/projets"
    ! peut_lire "$FREELANCE" /srv/projets
    resultat "C2" "freelance ne peut pas lister /srv/projets"
    peut_ecrire "$FREELANCE" /srv/projets/externe
    resultat "C2" "freelance peut ecrire dans /srv/projets/externe"
    peut_ecrire "$DESIGN" /srv/maquettes
    resultat "C2" "design peut ecrire dans /srv/maquettes"
    peut_lire "$COMMERCIAL" /srv/maquettes
    resultat "C2" "commercial peut lire /srv/maquettes"
    ! peut_ecrire "$DEV" /srv/maquettes
    resultat "C2" "dev ne peut pas ecrire dans /srv/maquettes"
    ! peut_lire "$FREELANCE" /srv/maquettes
    resultat "C2" "freelance ne peut pas lire /srv/maquettes"
    peut_ecrire "$COMMERCIAL" /srv/clients
    resultat "C2" "commercial peut ecrire dans /srv/clients"
    ! peut_lire "$DEV" /srv/clients
    resultat "C2" "dev ne peut pas lire /srv/clients"

    # ACL par defaut : getfacl -d affiche que les droits par defaut
    erreur=0
    for d in /srv/projets /srv/projets/externe /srv/maquettes /srv/clients; do
        getfacl -cd "$d" 2> /dev/null | grep -q "^group:[a-z]" || erreur=1
    done
    [ $erreur -eq 0 ]
    resultat "C2" "ACL par defaut presentes sur les 4 dossiers"

    # on cree un fichier en tant que dev et on regarde qui peut le lire
    fichier=/srv/projets/test_verifier.txt
    sudo -u "$DEV" touch "$fichier" 2> /dev/null && sudo -u "$DESIGN" test -r "$fichier" && ! sudo -u "$COMMERCIAL" test -r "$fichier"
    resultat "C2" "un nouveau fichier de dev est lisible par design mais pas par commercial"
    rm -f "$fichier"
}


test_C3() {
    grep -q "^%admins" /etc/sudoers.d/* 2> /dev/null
    resultat "C3" "le groupe admins a sudo via /etc/sudoers.d/"

    # support doit avoir une seule commande : analyse_logs.sh
    commandes=$(LC_ALL=C sudo -l -U support | grep "^ *(")
    [ "$(echo "$commandes" | wc -l)" -eq 1 ] && echo "$commandes" | grep -q "analyse_logs.sh"
    resultat "C3" "support peut lancer seulement analyse_logs.sh"

    [ "$(stat -c %U /usr/local/sbin/analyse_logs.sh 2> /dev/null)" = "root" ] && ! sudo -u support test -w /usr/local/sbin/analyse_logs.sh
    resultat "C3" "analyse_logs.sh appartient a root et support ne peut pas le modifier"

    # tous les autres comptes (uid >= 1000) ne doivent pas avoir sudo
    fautifs=""
    for u in $(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd); do
        if id -nG "$u" | grep -qw admins || [ "$u" = "support" ]; then
            continue
        fi
        LC_ALL=C sudo -l -U "$u" | grep -q "not allowed" || fautifs="$fautifs $u"
    done
    [ -z "$fautifs" ]
    resultat "C3" "aucun autre compte n'a sudo $fautifs"

    [ -z "$(getent group sudo | cut -d: -f4)" ]
    resultat "C3" "le groupe sudo de Debian est vide"
}


test_C4() {
    passwd -S root | grep -q " L "
    resultat "C4" "le compte root est verrouille"

    # le dernier chiffre des droits (= les autres) doit etre 0
    erreur=0
    for d in /home/*/; do
        droits=$(stat -c %a "$d")
        [ "${droits: -1}" = "0" ] || erreur=1
    done
    [ $erreur -eq 0 ]
    resultat "C4" "les homes ne sont pas accessibles aux autres"
}


test_S1() {
    [ "$(option_ssh passwordauthentication)" = "no" ]
    resultat "S1" "connexion par mot de passe refusee"
    [ "$(option_ssh kbdinteractiveauthentication)" = "no" ]
    resultat "S1" "KbdInteractiveAuthentication desactive"
    [ "$(option_ssh pubkeyauthentication)" = "yes" ]
    resultat "S1" "connexion par cle activee"
}

test_S2() {
    [ "$(option_ssh permitrootlogin)" = "no" ]
    resultat "S2" "connexion root refusee"
}

test_S3() {
    [ "$(option_ssh allowgroups)" = "acces_ssh" ]
    resultat "S3" "seul le groupe acces_ssh peut se connecter"
}

test_S4() {
    essais=$(option_ssh maxauthtries)
    [ "$essais" -le 4 ]
    resultat "S4" "MaxAuthTries = $essais (max 4)"

    intervalle=$(option_ssh clientaliveinterval)
    nombre=$(option_ssh clientalivecountmax)
    duree=$((intervalle * nombre))
    [ "$duree" -gt 0 ] && [ "$duree" -le 900 ]
    resultat "S4" "session inactive coupee apres $duree s (max 900)"
}

test_S5() {
    ls /etc/ssh/sshd_config.d/*.conf > /dev/null 2>&1
    resultat "S5" "config placee dans /etc/ssh/sshd_config.d/"
    sshd -t
    resultat "S5" "sshd -t valide la config"
}


test_J1() {
    systemctl is-active --quiet fail2ban
    resultat "J1" "fail2ban est lance"
    fail2ban-client status sshd > /dev/null 2>&1
    resultat "J1" "la prison sshd de fail2ban est active"
    essais=$(fail2ban-client get sshd maxretry 2> /dev/null)
    [ -n "$essais" ] && [ "$essais" -le 10 ]
    resultat "J1" "ban apres $essais echecs"
}

test_J2() {
    nft list chain inet filtre entree 2> /dev/null | grep -q "policy drop"
    resultat "J2" "politique par defaut du pare-feu : drop"
    nft list chain inet filtre entree 2> /dev/null | grep -q "tcp dport 22 accept"
    resultat "J2" "SSH autorise dans le pare-feu"
    nft list chain inet filtre entree 2> /dev/null | grep -q "ct state established,related accept"
    resultat "J2" "connexions deja etablies autorisees"
    systemctl is-enabled --quiet nftables
    resultat "J2" "le pare-feu se relance au demarrage"
}

test_J3() {
    grep -qs "^Storage=persistent" /etc/systemd/journald.conf.d/*.conf
    resultat "J3" "journald configure en persistant"
    [ -d /var/log/journal ] && [ -n "$(ls -A /var/log/journal)" ]
    resultat "J3" "le journal est bien ecrit sur le disque (/var/log/journal)"
}

test_J4() {
    [ -x /usr/local/sbin/analyse_logs.sh ]
    resultat "J4" "analyse_logs.sh est installe"
    /usr/local/sbin/analyse_logs.sh 999999 > /dev/null 2>&1
    resultat "J4" "analyse_logs.sh renvoie 0 sous le seuil"
    /usr/local/sbin/analyse_logs.sh abc > /dev/null 2>&1
    [ $? -eq 1 ]
    resultat "J4" "analyse_logs.sh refuse un seuil invalide"
}

test_D1() {
    dpkg -s unattended-upgrades > /dev/null 2>&1
    resultat "D1" "unattended-upgrades est installe"
    apt-config dump | grep -q 'APT::Periodic::Unattended-Upgrade "1"'
    resultat "D1" "les mises a jour automatiques sont activees"
}


test_B1() {
    mountpoint -q /sauvegardes && grep -q "LABEL=sauvegardes" /etc/fstab
    resultat "B1" "le 2e disque est monte sur /sauvegardes (et dans fstab)"
    [ -x /usr/local/sbin/sauvegarde.sh ] && [ "$(stat -c %U /usr/local/sbin/sauvegarde.sh)" = "root" ]
    resultat "B1" "sauvegarde.sh est installe et appartient a root"

    nb=$(ls -d /sauvegardes/20* 2> /dev/null | wc -l)
    [ "$nb" -ge 1 ]
    resultat "B1" "il y a au moins une version datee ($nb)"
    [ "$nb" -le 7 ]
    resultat "B1" "pas plus de 7 versions gardees"

    [ -f /sauvegardes/derniere/etc/hostname ] && [ -d /sauvegardes/derniere/srv/projets ]
    resultat "B1" "/etc et /srv sont dans la derniere sauvegarde"

    getfacl -c /sauvegardes/derniere/srv/projets 2> /dev/null | grep -q "^group:dev:rwx"
    resultat "B1" "les ACL sont conservees dans la sauvegarde"

    # incremental : un fichier qui a pas change = meme inode (lien dur) dans les 2 dernieres versions
    if [ "$nb" -ge 2 ]; then
        v1=$(ls -d /sauvegardes/20* | tail -n 2 | head -n 1)
        v2=$(ls -d /sauvegardes/20* | tail -n 1)
        [ "$(stat -c %i "$v1/etc/hostname")" = "$(stat -c %i "$v2/etc/hostname")" ]
        resultat "B1" "sauvegarde incrementale (fichiers inchanges pas recopies)"
    else
        ko "B1" "sauvegarde incrementale : lancer sauvegarde.sh 2 fois pour tester"
    fi
}

test_B2() {
    systemctl is-enabled --quiet sauvegarde.timer && systemctl is-active --quiet sauvegarde.timer
    resultat "B2" "la sauvegarde est planifiee (sauvegarde.timer)"
    [ -s /var/log/sauvegarde.log ]
    resultat "B2" "les sauvegardes sont journalisees (/var/log/sauvegarde.log)"
}

test_B3() {
    [ "$(stat -c '%U:%G %a' /sauvegardes)" = "root:admins 750" ]
    resultat "B3" "/sauvegardes en root:admins 750"
    ! sudo -u support test -r /sauvegardes && ! sudo -u "$DEV" test -r /sauvegardes
    resultat "B3" "support et dev ne peuvent pas lire les sauvegardes"
}

test_D2() {
    # on enleve : SSH (22), ce qui ecoute que en local, et les clients DHCP (68 en IPv4, 546 en IPv6)
    # qui servent a la VM pour recuperer son adresse IP
    autres=$(ss -tulnH | awk '{print $5}' | grep -vE ":22$|^127\.|^\[::1\]|:68$|:546$" | tr '\n' ' ')
    [ -z "$autres" ]
    resultat "D2" "aucun service joignable a part SSH $autres"
}

test_D3() {
    # -xdev : on reste sur le disque systeme (pas /proc, /sys...), -type f : vrais fichiers (pas les liens)
    modifiables=$(find / -xdev -type f -perm -0002 ! -path "/tmp/*" ! -path "/var/tmp/*" 2> /dev/null)
    [ -z "$modifiables" ]
    resultat "D3" "aucun fichier modifiable par tous hors /tmp ${modifiables:+($modifiables)}"

    # les fichiers SUID doivent etre ceux qu'on a listes et expliques dans le dossier
    if [ -f config/suid_autorises.txt ]; then
        en_trop=$(find / -xdev -type f -perm -4000 2> /dev/null | sort | comm -23 - <(sort config/suid_autorises.txt))
        [ -z "$en_trop" ]
        resultat "D3" "pas de fichier SUID inconnu ${en_trop:+($en_trop)}"
    else
        ko "D3" "config/suid_autorises.txt manquant"
    fi
}


test_C1
test_C2
test_C3
test_C4
test_S1
test_S2
test_S3
test_S4
test_S5
test_J1
test_J2
test_J3
test_J4
test_D1
test_B1
test_B2
test_B3
test_D2
test_D3

echo "--- $reussis / $total tests reussis"

if [ $reussis -eq $total ]; then
    exit 0
else
    exit 1
fi
