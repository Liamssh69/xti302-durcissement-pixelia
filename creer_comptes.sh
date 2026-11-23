#!/bin/bash
# creer_comptes.sh
# Cree les groupes, les utilisateurs (depuis comptes.csv), installe les cles SSH
# et cree les dossiers de /srv avec les ACL (contexte A Pixelia)
# Exigences : C1, C2
# Lancement : sudo ./creer_comptes.sh [fichier_csv]

set -euo pipefail

CSV="${1:-comptes.csv}"
DATE_FIN_FREELANCE="2027-01-31"

# --- verifications de depart ---
if [ "$(id -u)" -ne 0 ]; then
    echo "Erreur : ce script doit etre lance en root" >&2
    exit 1
fi

if [ ! -f "$CSV" ]; then
    echo "Erreur : fichier $CSV introuvable" >&2
    exit 1
fi

if ! command -v setfacl > /dev/null; then
    echo "Erreur : il faut installer le paquet acl" >&2
    exit 1
fi


# cree le groupe seulement s'il existe pas deja (pour pouvoir relancer le script)
creer_groupe() {
    if ! getent group "$1" > /dev/null; then
        groupadd "$1"
        echo "groupe $1 cree"
    fi
}


# copie la cle publique config/keys/<login>.pub dans le authorized_keys du compte
installer_cle() {
    login=$1
    cle="config/keys/$login.pub"

    if [ ! -f "$cle" ]; then
        return 0
    fi

    mkdir -p "/home/$login/.ssh"
    cp "$cle" "/home/$login/.ssh/authorized_keys"
    chown -R "$login:" "/home/$login/.ssh"
    chmod 700 "/home/$login/.ssh"
    chmod 600 "/home/$login/.ssh/authorized_keys"
    echo "cle installee pour $login"
}


# cree (ou met a jour) un utilisateur
creer_utilisateur() {
    login=$1
    nom=$2
    groupe=$3
    autres_groupes=$4

    if id "$login" > /dev/null 2>&1; then
        # il existe deja : on met juste a jour son nom et son groupe principal
        usermod -c "$nom" -g "$groupe" "$login"
    else
        useradd -m -s /bin/bash -c "$nom" -g "$groupe" "$login"
        echo "utilisateur $login cree"
    fi

    # -a pour ajouter sans enlever les groupes qu'il a deja
    if [ -n "$autres_groupes" ]; then
        usermod -aG "$autres_groupes" "$login"
    fi

    # C4 : les autres ne peuvent pas lire le home
    chmod 700 "/home/$login"

    # particularite Pixelia : les freelances expirent a la fin du semestre
    if [ "$groupe" = "freelance" ]; then
        chage -E "$DATE_FIN_FREELANCE" "$login"
    fi

    installer_cle "$login"
}


# met les droits sur un dossier de /srv
# $1 = dossier, $2 = droits des groupes ex : "g:dev:rwx,g:design:rx"
droits_dossier() {
    mkdir -p "$1"
    chown root:root "$1"
    chmod 770 "$1"
    setfacl -b "$1"                              # on efface les anciennes ACL
    setfacl -m "g::---,o::---,$2" "$1"           # droits sur le dossier
    setfacl -d -m "g::---,o::---,$2" "$1"        # droits par defaut pour les nouveaux fichiers
    echo "droits mis sur $1"
}


# --- 1. les groupes ---
for g in admins support acces_ssh dev design commercial freelance; do
    creer_groupe "$g"
done

# --- 2. les utilisateurs ---
# sed '$a\' ajoute un retour a la ligne a la fin s'il manque (sinon la derniere ligne est ignoree)
# tail -n +2 pour sauter la ligne d'en-tete, tr pour enlever les \r si le csv vient de windows
sed '$a\' "$CSV" | tail -n +2 | tr -d '\r' | while IFS=';' read -r login nom groupe autres; do
    if [ -n "$login" ]; then
        creer_utilisateur "$login" "$nom" "$groupe" "$autres"
    fi
done

# --- 3. les dossiers de /srv (tableau du contexte A) ---
droits_dossier /srv/projets          "g:dev:rwx,g:design:rx"
droits_dossier /srv/projets/externe  "g:dev:rwx,g:design:rx,g:freelance:rwx"
droits_dossier /srv/maquettes        "g:dev:rx,g:design:rwx,g:commercial:rx"
droits_dossier /srv/clients          "g:commercial:rwx"

# les freelances doivent pouvoir passer par /srv/projets pour aller dans externe
# x = traverser le dossier, mais sans r ils peuvent pas voir ce qu'il y a dedans
setfacl -m "g:freelance:x" /srv/projets

echo "creer_comptes.sh termine"
