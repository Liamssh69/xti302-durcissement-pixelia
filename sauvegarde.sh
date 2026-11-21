#!/bin/bash
# sauvegarde.sh
# Sauvegarde /srv et /etc sur le 2e disque (monte sur /sauvegardes) avec rsync (exigence B1)
# - chaque lancement cree un dossier date : /sauvegardes/2026-11-18_0230
# - incremental : --link-dest fait un lien dur vers la version d'avant pour les fichiers
#   qui ont pas change, donc ils sont pas recopies et prennent pas de place en plus
# - -A et -X gardent les ACL et les attributs etendus
# - on garde les 7 dernieres versions, les plus vieilles sont supprimees
# Lancement : sudo sauvegarde.sh   (lance tout seul tous les jours par sauvegarde.timer)

set -euo pipefail

DEST=/sauvegardes
GARDER=7
JOURNAL=/var/log/sauvegarde.log

log() {
    echo "$(date '+%F %T') $1" | tee -a "$JOURNAL"
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Erreur : lancer en root (sudo)" >&2
    exit 1
fi

# si le disque est pas monte on sauvegarderait sur le disque systeme, donc on arrete
if ! mountpoint -q "$DEST"; then
    log "ERREUR : $DEST n'est pas monte, sauvegarde annulee"
    exit 1
fi

version="$DEST/$(date +%F_%H%M%S)"
# si on lance 2 fois dans la meme seconde le dossier existe deja, on attend 1 s
while [ -e "$version" ]; do
    sleep 1
    version="$DEST/$(date +%F_%H%M%S)"
done
precedente="$DEST/derniere"

log "debut de la sauvegarde vers $version"

# la premiere fois il y a pas de version precedente, donc pas de --link-dest
if [ -d "$precedente" ]; then
    rsync -aAXH --delete --link-dest="$precedente" /srv /etc "$version/"
else
    rsync -aAXH --delete /srv /etc "$version/"
fi

# "derniere" pointe toujours vers la sauvegarde la plus recente
ln -sfn "$version" "$precedente"

# on supprime les plus vieilles versions pour en garder que 7
# (les noms commencent par la date donc ls les trie du plus vieux au plus recent)
for vieille in $(ls -d "$DEST"/20* | head -n -"$GARDER"); do
    rm -rf "$vieille"
    log "ancienne version supprimee : $vieille"
done

log "sauvegarde terminee : $version"
