#!/bin/bash
# analyse_logs.sh
# Rapport sur les connexions SSH (exigence J4)
# Sur Debian 13 minimale il y a pas de /var/log/auth.log, les logs SSH sont dans journald
# Lancement : sudo analyse_logs.sh [seuil] [periode]
#   seuil   : nombre d'echecs max pour une IP avant alerte (defaut 10)
#   periode : depuis quand on regarde (defaut "24 hours ago")
# Code de sortie : 0 = rien d'anormal, 1 = erreur, 2 = une IP depasse le seuil

set -euo pipefail

SEUIL=${1:-10}
PERIODE=${2:-"24 hours ago"}

if [ "$(id -u)" -ne 0 ]; then
    echo "Erreur : lancer en root (sudo)" >&2
    exit 1
fi

if ! [[ "$SEUIL" =~ ^[0-9]+$ ]]; then
    echo "Erreur : le seuil doit etre un nombre" >&2
    exit 1
fi

# les logs ssh de la periode
logs=$(journalctl -u ssh --since "$PERIODE" --no-pager -o cat || true)

# les lignes d'echec. Comme on a mis "cle uniquement", les echecs ressemblent a :
#   Invalid user toto from 1.2.3.4 port 5555
#   Connection closed by authenticating user liam 1.2.3.4 port 5555 [preauth]
#   Failed publickey for liam from 1.2.3.4 port 5555 ssh2
echecs=$(echo "$logs" | grep -E "Invalid user|Failed |Connection closed by (authenticating|invalid) user" || true)

echo "=== Rapport SSH depuis : $PERIODE ==="
echo
echo "--- Echecs par IP ---"
echo "$echecs" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | sort | uniq -c | sort -rn || true

echo
echo "--- Comptes vises ---"
echo "$echecs" | grep -oE "(user|for) [a-zA-Z0-9._-]+" | awk '{print $2}' | grep -v "^invalid$" | sort | uniq -c | sort -rn || true

echo
echo "--- Connexions reussies ---"
echo "$logs" | grep "Accepted" | awk '{print $4, "depuis", $6}' || true

# l'IP qui a le plus d'echecs
max=$(echo "$echecs" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | sort | uniq -c | sort -rn | head -n 1 | awk '{print $1}' || true)
max=${max:-0}

echo
if [ "$max" -gt "$SEUIL" ]; then
    echo "ALERTE : $max echecs depuis la meme IP (seuil : $SEUIL)"
    exit 2
fi
echo "OK : $max echecs max par IP (seuil : $SEUIL)"
exit 0
