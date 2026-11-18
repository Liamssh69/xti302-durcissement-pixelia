#!/bin/bash
# analyse_logs.sh
# Rapport sur les connexions SSH (exigence J4, version de base a finir en seance 4)
# Sur Debian 13 minimale il y a pas de /var/log/auth.log, les logs SSH sont dans journald
# Lancement : sudo analyse_logs.sh [seuil]
# Code de sortie : 0 = rien d'anormal, 2 = une IP depasse le seuil d'echecs

set -euo pipefail

SEUIL=${1:-10}

if [ "$(id -u)" -ne 0 ]; then
    echo "Erreur : lancer en root (sudo)" >&2
    exit 1
fi

# les logs ssh des dernieres 24h
logs=$(journalctl -u ssh --since "24 hours ago" --no-pager -o cat || true)

echo "=== Echecs par IP ==="
echo "$logs" | grep -E "Failed|Invalid user" | grep -oE "from [0-9.]+" | sort | uniq -c | sort -rn || true

echo "=== Comptes vises ==="
echo "$logs" | grep "Invalid user" | awk '{print $3}' | sort | uniq -c | sort -rn || true

echo "=== Connexions reussies ==="
echo "$logs" | grep "Accepted" || true

# nombre d'echecs de l'IP qui en a le plus
max=$(echo "$logs" | grep -E "Failed|Invalid user" | grep -oE "from [0-9.]+" | sort | uniq -c | sort -rn | head -n 1 | awk '{print $1}')
max=${max:-0}

if [ "$max" -gt "$SEUIL" ]; then
    echo "ALERTE : $max echecs depuis la meme IP (seuil : $SEUIL)"
    exit 2
fi
echo "OK : $max echecs max par IP (seuil : $SEUIL)"
