# Dossier - Projet XTI302-CYB : durcir un serveur Linux et le prouver

**Groupe :** Liam Veauclin + [Mathias magnus]
**Contexte choisi :** A - Agence web Pixelia
**Serveur :** VM Debian 13 minimale (sans interface graphique), SSH, 2e disque de 2 Go pour les sauvegardes

Tout est reconstruit par `installer.sh` à partir du snapshot « vierge » et vérifié par `verifier.sh`
(61 tests, code de sortie 0 si tout est conforme).

---

## 1. Tableau de conformité

Les numéros ANSSI renvoient au guide ANSSI-BP-028 v2.0 (*Recommandations de configuration d'un système GNU/Linux*)
et à la note ANSSI *Usage sécurisé d'(Open)SSH*.

| ID | Ce qu'on a fait | Test(s) dans verifier.sh | ANSSI |
|----|-----------------|--------------------------|-------|
| C1 | `creer_comptes.sh` crée les 7 groupes et les comptes à partir de `comptes.csv`. Idempotent : il vérifie avec `getent`/`id` avant de créer. Comptes freelance expirés au 31/01/2027 (`chage -E`). | `test_C1` : chaque compte du CSV existe avec ses groupes, les 7 groupes existent, le freelance a une date d'expiration | R30 (pas de comptes inutiles) |
| C2 | Dossiers `/srv` en 770 root + ACL (`setfacl -m`) et ACL par défaut (`setfacl -d -m`) selon le tableau Pixelia. `freelance` a seulement `x` sur `/srv/projets` pour atteindre `externe`. | `test_C2` : 12 tests « peut / ne peut pas » avec `sudo -u`, ACL par défaut présentes, fichier créé par un dev lisible par design mais pas par commercial | R50 (restreindre l'accès aux fichiers sensibles) |
| C3 | `config/sudoers.d/xti302` : `%admins` a tous les droits, `support` peut seulement lancer `/usr/local/sbin/analyse_logs.sh`. Fichier validé par `visudo -cf`. Groupe `sudo` de Debian vidé. `analyse_logs.sh` appartient à root (755). | `test_C3` : admins dans sudoers, support a une seule commande, script non modifiable par support, aucun autre compte n'a sudo, groupe sudo vide | R38 (groupe dédié à sudo) |
| C4 | `passwd -l root`, homes en 700. | `test_C4` : root verrouillé, aucun home accessible aux autres | R33 (imputabilité : on passe par des comptes nominatifs) |
| S1 | `PubkeyAuthentication yes`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`. Clés publiques dans `config/keys/`, installées par `creer_comptes.sh`. | `test_S1` (3 tests via `sshd -T`) | Guide OpenSSH : authentification par clé |
| S2 | `PermitRootLogin no` | `test_S2` | Guide OpenSSH : pas de connexion root |
| S3 | `AllowGroups acces_ssh` (admins + support) | `test_S3` | Guide OpenSSH : restreindre les utilisateurs autorisés |
| S4 | `MaxAuthTries 3`, `ClientAliveInterval 300` + `ClientAliveCountMax 2` (10 min) | `test_S4` | R32 (expiration des sessions) |
| S5 | Config dans `/etc/ssh/sshd_config.d/10-durcissement.conf`, `sshd -t` avant `systemctl restart ssh` | `test_S5` : fichier présent, `sshd -t` valide | - |
| J1 | fail2ban, prison `sshd` (backend systemd, 5 échecs en 10 min = ban 15 min, action nftables) | `test_J1` : service actif, prison sshd active, maxretry raisonnable | R79 (surveiller les services exposés) |
| J2 | `config/nftables.conf` : politique `drop` en entrée, autorisé : loopback, connexions établies, ICMP, port 22. `systemctl enable nftables`. | `test_J2` : policy drop, port 22 autorisé, connexions établies autorisées, service activé au démarrage | R80 (réduire la surface d'attaque réseau) |
| J3 | `Storage=persistent` dans `/etc/systemd/journald.conf.d/persistant.conf`, dossier `/var/log/journal` | `test_J3` : réglage présent, journal écrit sur le disque | R71 (système de journalisation) |
| J4 | `analyse_logs.sh [seuil] [période]` : échecs par IP, comptes visés, connexions réussies, code 2 si une IP dépasse le seuil | `test_J4` : installé, code 0 sous le seuil, refuse un seuil invalide | R71 |
| D1 | `unattended-upgrades` + `config/apt/20auto-upgrades` | `test_D1` : paquet installé, mises à jour automatiques activées | R61 (mises à jour régulières) |
| D2 | Seul SSH est joignable (`ss -tulpn`), voir partie 2 | `test_D2` | R62 (désactiver les services inutiles) |
| D3 | Aucun fichier modifiable par tous hors `/tmp` et `/var/tmp`. SUID listés dans `config/suid_autorises.txt` | `test_D3` : pas de fichier modifiable par tous, pas de SUID inconnu | R56, R57 (éviter les exécutables setuid) |
| B1 | 2e disque formaté une seule fois (test `blkid`), monté sur `/sauvegardes`. `sauvegarde.sh` : `rsync -aAXH --link-dest`, une version datée par exécution, 7 versions gardées | `test_B1` : disque monté, script installé, versions datées, 7 max, /etc et /srv présents, ACL gardées, incrémental (même inode) | - |
| B2 | `sauvegarde.timer` (systemd, chaque nuit, `Persistent=true`), journal `/var/log/sauvegarde.log` | `test_B2` : timer actif, journal non vide | - |
| B3 | `/sauvegardes` en `root:admins` 750 | `test_B3` : droits corrects, support et dev ne peuvent pas lire | R50 |
| B4 | Restauration testée et documentée (partie 4) | (test manuel) | - |

---

## 2. Choix techniques

| Réglage | Valeur | Pourquoi |
|---------|--------|----------|
| `MaxAuthTries` | 3 | Le sujet demande 4 max. 3 essais suffisent pour une faute de frappe et ralentissent un bruteforce. |
| Session inactive | 300 s × 2 = 10 min | Une session oubliée ouverte se ferme toute seule. Le sujet demande 15 min max. |
| fail2ban | 5 échecs en 10 min, ban 15 min | Assez pour bloquer un robot qui teste en boucle, sans bannir quelqu'un qui se trompe une ou deux fois. Si on se bannit soi-même : `fail2ban-client set sshd unbanip IP`. |
| fail2ban `backend` | systemd | Debian 13 minimale n'a pas de `/var/log/auth.log`, les logs SSH sont dans journald. |
| Pare-feu | table à nous, pas de `flush ruleset` | `flush ruleset` effacerait aussi la table de fail2ban. On redémarre fail2ban après nftables pour qu'il remette ses règles. |
| Seuil `analyse_logs.sh` | 10 échecs par IP sur 24 h | En dessous, ça peut être des erreurs normales. Au-dessus, c'est clairement une attaque. Paramétrable : `analyse_logs.sh 20 "1 hour ago"`. |
| Expiration freelance | 31/01/2027 | Fin du semestre : un prestataire ne garde pas un accès oublié. |
| Journal | persistant, 200 Mo max | On garde l'historique après un redémarrage (utile pour enquêter) sans remplir le disque. |
| Sauvegarde | timer systemd plutôt que cron | Rien à installer, journalisé, et `Persistent=true` relance la sauvegarde au démarrage si la VM était éteinte à l'heure prévue. |
| Versions gardées | 7 | Une semaine de retour en arrière avec une sauvegarde par jour. |
| Montage du disque | `LABEL=sauvegardes`, option `nofail` | Le label marche même si le disque change de nom (sdb, sdc...). `nofail` : la VM démarre même si le disque est absent. |
| `sauvegarde.sh` | s'arrête si `/sauvegardes` n'est pas monté | Sinon il sauvegarderait sur le disque système sans qu'on s'en rende compte. |
| `verifier.sh` | sans `set -e` ni `pipefail` | Les tests lancent exprès des commandes qui échouent (un commercial qui lit `/srv/projets`) : `set -e` arrêterait le script au premier refus. |

### Écoutes réseau (D2)

`ss -tulpn` montre :

- **22/tcp** : SSH, le seul service voulu ;
- **68/udp** : client DHCP (IPv4), la VM l'utilise pour récupérer son adresse IP ;
- **546/udp** : client DHCPv6, sur une adresse `fe80::` (locale au réseau), même rôle en IPv6.

Les deux clients DHCP n'acceptent que les réponses d'un serveur DHCP. Ce ne sont pas des services proposés aux autres machines.

### Fichiers SUID (D3)

Un fichier SUID s'exécute avec les droits de son propriétaire (ici root), il faut donc une vraie raison :

| Fichier | Raison |
|---------|--------|
| `/usr/bin/passwd` | changer son mot de passe = écrire dans `/etc/shadow` |
| `/usr/bin/sudo`, `/usr/bin/su` | devenir root ou un autre utilisateur après vérification |
| `/usr/bin/chfn`, `/usr/bin/chsh` | changer son nom complet ou son shell dans `/etc/passwd` |
| `/usr/bin/gpasswd`, `/usr/bin/newgrp` | gestion des mots de passe de groupe, changer de groupe actif |
| `/usr/bin/mount`, `/usr/bin/umount` | monter un périphérique autorisé par `/etc/fstab` |
| `/usr/lib/dbus-1.0/dbus-daemon-launch-helper` | démarrer des services système à la demande de dbus |
| `/usr/lib/openssh/ssh-keysign` | authentification SSH par clé d'hôte |

`verifier.sh` compare la liste actuelle avec `config/suid_autorises.txt` : un nouveau SUID est signalé en KO.

---

## 3. Défense : ce que la configuration rend plus difficile

1. **Bruteforce SSH** : mot de passe refusé (clé uniquement), 3 essais par connexion, puis fail2ban bannit l'IP après 5 échecs. Pare-feu : seul le port 22 est ouvert.
2. **Vol de mot de passe** : un mot de passe volé ne permet pas de se connecter en SSH, il faut la clé privée. Root n'a plus de mot de passe utilisable.
3. **Utilisateur curieux** : les homes sont en 700, les ACL sur `/srv` limitent chaque groupe à ses dossiers (un commercial ne voit pas les projets, un dev ne voit pas les clients), les sauvegardes ne sont lisibles que par les admins.
4. **Compte freelance ou support compromis** : freelance n'a ni SSH ni sudo, et son compte expire en fin de semestre. support ne peut lancer qu'un seul script en root, et ce script appartient à root : il ne peut pas le modifier pour devenir root.
5. **Suppression ou chiffrement de fichiers (rançongiciel, erreur)** : sauvegardes versionnées, on peut revenir à une version de la veille ou de la semaine passée.

**Ce que la configuration ne couvre pas :**

- **la clé privée d'un admin volée** sur son PC : l'attaquant a les mêmes droits que l'admin (pas de double authentification) ;
- **la sauvegarde est sur la même machine** : si la VM est détruite ou entièrement chiffrée, on perd aussi les sauvegardes. En vrai il faudrait la règle 3-2-1 (3 copies, 2 supports, 1 hors site) ;
- **pas d'alerte en temps réel** : `analyse_logs.sh` donne un rapport mais n'envoie pas de mail ;
- **une faille dans OpenSSH lui-même** : limitée par les mises à jour automatiques, mais pas empêchée.

---

## 4. Procédure de restauration (B4)

Exemple testé : un fichier de `/srv/projets` supprimé par erreur.

1. Lister les versions disponibles :
   ```
   sudo ls /sauvegardes
   ```
   Les dossiers sont nommés par date (`2026-11-18_105550`) ; `derniere` pointe vers la plus récente.

2. Vérifier que le fichier est bien dans la version choisie :
   ```
   sudo ls -l /sauvegardes/2026-11-18_105550/srv/projets/
   ```

3. Le remettre en place en gardant ses droits et ses ACL (`-a`) :
   ```
   sudo cp -a /sauvegardes/2026-11-18_105550/srv/projets/site.txt /srv/projets/
   ```

4. Vérifier le contenu et les droits :
   ```
   sudo cat /srv/projets/site.txt
   sudo getfacl /srv/projets/site.txt
   ```

**Test réalisé :** `jdupont` crée `/srv/projets/site.txt` (« maquette v1 »), on lance `sauvegarde.sh`, on supprime le fichier,
puis on le copie depuis `/sauvegardes/derniere`. Résultat : le contenu « maquette v1 » est revenu et les ACL d'origine
(`group:dev:rwx`, `group:design:r-x`) sont conservées.

Pour restaurer un dossier entier, même principe avec `rsync -aAX` :
```
sudo rsync -aAX /sauvegardes/2026-11-18_105550/srv/projets/ /srv/projets/
```
