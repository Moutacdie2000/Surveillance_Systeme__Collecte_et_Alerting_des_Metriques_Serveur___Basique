# surveillance-systeme

Outil de **supervision système** léger, écrit en Bash, qui surveille en continu
les ressources vitales d'un hôte Linux, **CPU, mémoire (RAM), disques et charge
système**, et déclenche des **alertes simples** dès qu'un seuil configurable est
dépassé.

Conçu sans dépendance lourde : il s'appuie uniquement sur le pseudo-système de
fichiers `/proc` et sur les commandes Linux standards (`df`, `ps`, `uptime`,
`nproc`, `awk`). Aucun agent, aucune base de données, aucun service tiers requis.

---

## Objectif

Disposer d'un script unique, facile à auditer et à déployer (cron ou systemd),
capable de répondre à une question simple : **« mon serveur est-il en bonne
santé en ce moment ? »**, et de prévenir automatiquement (journal + webhook)
lorsqu'une ressource sort des clous.

---

## Ce que ça démontre

- **Scripting Bash de qualité production** : `set -euo pipefail`, découpage en
  bibliothèques réutilisables (`lib/`), fonctions documentées, gestion des
  signaux, codes de sortie explicites, propreté `shellcheck`.
- **Connaissance du système Linux** : lecture brute de `/proc/stat`,
  `/proc/meminfo`, `/proc/loadavg`, `/proc/uptime`, calcul d'un pourcentage CPU
  par échantillonnage, relativisation de la charge au nombre de cœurs.
- **Observabilité pragmatique** : sortie humaine (tableau coloré) **et** sortie
  machine (`--json`) pour l'intégration dans une chaîne d'outils.
- **Alerting réaliste mais hors-ligne par défaut** : journalisation systématique
  et webhook `curl` optionnel, avec un **MODE DÉMO** qui affiche le payload sans
  jamais toucher au réseau, parfait pour une démonstration reproductible.
- **Industrialisation** : exemples prêts à l'emploi pour **cron** et pour une
  **unité systemd + timer** durcie.

---

## Prérequis

- Un système **Linux** (le script lit `/proc` ; il échoue proprement ailleurs,
  par exemple sur macOS).
- **Bash 4+** et les coreutils habituels (`awk`, `df`, `ps`, `date`, `hostname`).
- **`curl`** uniquement si vous activez l'envoi vers un webhook (facultatif).

Aucune installation n'est nécessaire : le dépôt est autonome.

---

## Structure du projet

```
surveillance-systeme/
├── monitor.sh                 # Script principal (collecte, seuils, rendu, alertes)
├── thresholds.conf            # Seuils CPU/RAM/DISK + configuration du canal d'alerte
├── lib/
│   ├── log.sh                 # Journalisation horodatée et colorée
│   ├── metrics.sh             # Collecte des métriques via /proc, df, ps, uptime
│   └── alerting.sh            # Émission des alertes (journal + webhook / MODE DÉMO)
├── systemd/
│   ├── surveillance-systeme.service   # Unité oneshot (--once)
│   └── surveillance-systeme.timer     # Déclencheur périodique
├── crontab.example            # Exemples de planification cron
├── README.md
├── LICENSE                    # MIT
└── .gitignore
```

---

## Installation rapide

```bash
# 1. Rendre le script exécutable.
chmod +x monitor.sh

# 2. (Optionnel) Adapter les seuils et le canal d'alerte.
$EDITOR thresholds.conf

# 3. Lancer une première collecte.
./monitor.sh --once
```

---

## Usage

```text
monitor.sh [OPTIONS]

MODES (défaut : --once) :
  -o, --once              Une seule collecte puis sortie.
  -w, --watch [SECONDES]  Boucle, rafraîchit toutes les SECONDES (défaut 5).

OPTIONS :
  -c, --config FICHIER    Fichier de seuils (défaut : ./thresholds.conf).
  -j, --json              Sortie JSON au lieu du tableau lisible.
  -n, --no-alert          Lecture seule : n'émet aucune alerte.
      --sample SECONDES   Fenêtre de mesure CPU (défaut 1, décimales acceptées).
      --top N             Nombre de processus les plus gourmands (défaut 5).
      --no-color          Désactive les couleurs.
  -h, --help              Affiche l'aide.
```

Affichez l'aide complète à tout moment :

```bash
./monitor.sh --help
```

### Exemples concrets

**Collecte unique, tableau lisible :**

```bash
./monitor.sh --once
```

```text
== Surveillance système ==  2026-06-03T20:14:07+0200  (hôte : web-01, uptime : 3j 4h 12min)

RESSOURCE  VALEUR       SEUILS (W/C)           ÉTAT
--------------------------------------------------------
CPU        12.5%        80/90%                 OK
RAM        63.8%        80/90%                 OK
Charge     0.42         ratio 1.0/2.0          OK
  (load 1/5/15 : 0.42 / 0.55 / 0.60, 4 cœurs, ratio 0.10)

MONTAGE                  USAGE    UTILISÉ / TOTAL      ÉTAT
--------------------------------------------------------------
/                        46%      21.3Go / 49.0Go      OK
/boot                    22%      0.2Go / 1.0Go        OK

PID      %CPU    %MEM    COMMANDE
----------------------------------------------------
1421     8.3     4.1     node
988      2.1     1.7     postgres
...
```

**Sortie JSON (pour ingestion par un autre outil) :**

```bash
./monitor.sh --once --json
```

```json
{"timestamp":"2026-06-03T20:14:07+0200","host":"web-01","uptime":"3j 4h 12min","cpu":{"usage_percent":12.5,"warn":80,"crit":90,"state":"OK"},"memory":{"usage_percent":63.8,"used_kb":5300000,"total_kb":8160000,"warn":80,"crit":90,"state":"OK"},"load":{"avg1":0.42,"avg5":0.55,"avg15":0.60,"cpu_count":4,"ratio":0.10,"warn_ratio":1.0,"crit_ratio":2.0,"state":"OK"},"disks":[...],"top_processes":[...],"alerts_raised":0}
```

**Surveillance continue (rafraîchissement live toutes les 10 s) :**

```bash
./monitor.sh --watch 10
```

L'écran se rafraîchit en place ; `Ctrl-C` arrête proprement la surveillance.

**Profil de seuils dédié, en lecture seule (sans alerte) :**

```bash
./monitor.sh --once --config /etc/surveillance/db.conf --no-alert
```

---

## Configuration des seuils (`thresholds.conf`)

Le fichier est « sourcé » tel quel : ce sont des variables shell (pas d'espace
autour du `=`). Principales clés :

| Variable                          | Rôle                                                        | Défaut |
|-----------------------------------|-------------------------------------------------------------|--------|
| `CPU_WARN` / `CPU_CRIT`           | Seuils d'usage CPU (%)                                       | 80 / 90 |
| `MEM_WARN` / `MEM_CRIT`           | Seuils d'usage mémoire (%)                                   | 80 / 90 |
| `DISK_WARN` / `DISK_CRIT`         | Seuils d'occupation disque (%) appliqués à **chaque** montage | 80 / 90 |
| `LOAD_WARN_RATIO` / `LOAD_CRIT_RATIO` | Seuils de charge exprimés en ratio `charge_1min / cœurs` | 1.0 / 2.0 |
| `ALERT_LOG_FILE`                  | Fichier où sont journalisées les alertes                    | `/var/log/surveillance-systeme/alerts.log` |
| `ALERT_WEBHOOK_URL`               | URL POST JSON (vide ⇒ **MODE DÉMO**)                        | *(vide)* |
| `ALERT_WEBHOOK_TIMEOUT`           | Délai max de l'appel `curl` (s)                             | 5 |
| `ALERT_DEMO_MODE`                 | Force le MODE DÉMO même si une URL est présente (`1`)       | 0 |

> Le **ratio de charge** rend le seuil indépendant de la taille de la machine :
> `1.0` signifie « charge 1 min égale au nombre de cœurs » (machine saturée).

---

## Alerting : journal, webhook et MODE DÉMO

Toute alerte est **systématiquement journalisée** (fichier `ALERT_LOG_FILE` +
sortie d'erreur colorée). Ensuite :

- **Si `ALERT_WEBHOOK_URL` est renseignée** et que `curl` est disponible,
  l'alerte est envoyée en **HTTP POST JSON** (compatible Slack, Discord,
  Mattermost ou tout endpoint acceptant du JSON).
- **Sinon (URL vide ou `ALERT_DEMO_MODE=1`)**, le projet bascule en **MODE DÉMO** :
  aucune connexion réseau n'est tentée, mais le **payload qui aurait été envoyé**
  est affiché. La chaîne d'alerte est ainsi démontrable totalement hors-ligne.

Exemple de payload JSON émis pour une alerte :

```json
{"timestamp":"2026-06-03T20:14:07+0200","host":"web-01","severity":"CRITIQUE","metric":"CPU","value":"92.0%","threshold":"80/90%","message":"Utilisation CPU élevée"}
```

### Tester rapidement le déclenchement d'alertes

Forcez des seuils volontairement bas pour voir le mécanisme en action, sans
réseau :

```bash
CPU_WARN=0 CPU_CRIT=1 MEM_WARN=0 MEM_CRIT=1 DISK_WARN=0 DISK_CRIT=1 \
LOAD_WARN_RATIO=0 LOAD_CRIT_RATIO=0 \
./monitor.sh --once
```

Le tableau affichera des états `WARN`/`CRIT` et le **MODE DÉMO** imprimera les
payloads correspondants.

---

## Codes de sortie

| Code | Signification                                  |
|------|------------------------------------------------|
| `0`  | Tout est sous les seuils (aucune alerte).      |
| `1`  | Erreur d'exécution (option invalide, `/proc` absent…). |
| `2`  | Au moins une alerte a été déclenchée.          |

Le code `2` permet à un ordonnanceur de détecter une anomalie. L'unité systemd
fournie déclare `SuccessExitStatus=2` pour ne pas considérer une alerte comme un
échec du service.

---

## Planification

### Avec cron

Voir [`crontab.example`](crontab.example). Exemple : une collecte toutes les
5 minutes (seules les alertes, écrites sur `stderr`, remonteront par mail si
`MAILTO` est défini) :

```cron
NO_COLOR=1
*/5 * * * * /opt/surveillance-systeme/monitor.sh --once --config /opt/surveillance-systeme/thresholds.conf >/dev/null
```

### Avec systemd (recommandé)

Le couple [`systemd/surveillance-systeme.service`](systemd/surveillance-systeme.service)
+ [`systemd/surveillance-systeme.timer`](systemd/surveillance-systeme.timer)
exécute une collecte toutes les 5 minutes via une unité `oneshot` durcie.

```bash
# En root, après avoir copié le projet dans /opt/surveillance-systeme :
sudo cp systemd/surveillance-systeme.service /etc/systemd/system/
sudo cp systemd/surveillance-systeme.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now surveillance-systeme.timer

# Vérifications :
systemctl list-timers surveillance-systeme.timer
journalctl -u surveillance-systeme.service -f
```

> Adaptez les chemins `WorkingDirectory` / `ExecStart` dans le fichier
> `.service` si vous installez ailleurs que `/opt/surveillance-systeme`.

---

## Détails d'implémentation

- **CPU** : deux lectures de `/proc/stat` espacées de `--sample` secondes ; le
  pourcentage est `(Δactif / Δtotal) × 100`. Une mesure instantanée est donc
  impossible (il faut un intervalle), c'est volontaire et conforme à la façon
  dont `top` procède.
- **Mémoire** : `used = MemTotal − MemAvailable` (définition moderne), avec repli
  sur `MemFree + Buffers + Cached` pour les très vieux noyaux.
- **Disque** : `df -P` en excluant les pseudo-systèmes de fichiers (`tmpfs`,
  `overlay`, `squashfs`, …) ; le seuil s'applique à chaque montage réel.
- **Charge** : `/proc/loadavg` (1/5/15 min), relativisée au nombre de cœurs
  (`nproc`) pour produire un ratio comparable entre machines.
- **Processus** : `ps -eo pid,pcpu,pmem,comm --sort=-pcpu`, top N tronqué.

---

## Licence

Distribué sous licence **MIT**. Voir le fichier [LICENSE](LICENSE).

Copyright (c) 2026 Noumabeu Moutacdie Jordan.
