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


test_C1
test_C2
test_C3
test_C4
test_S1
test_S2
test_S3
test_S4
test_S5

echo "--- $reussis / $total tests reussis"

if [ $reussis -eq $total ]; then
    exit 0
else
    exit 1
fi
