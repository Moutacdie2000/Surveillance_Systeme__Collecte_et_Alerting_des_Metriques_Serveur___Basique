#!/usr/bin/env bash
# monitor.sh, Surveillance système (CPU / RAM / disque / charge) et alertes.
#
# Outil de supervision « zéro dépendance lourde » : il collecte les métriques
# vitales d'un hôte Linux à partir de /proc, df, ps et uptime, les compare à des
# seuils configurables, affiche un tableau lisible (ou du JSON) et déclenche des
# alertes (journal + webhook optionnel, sinon MODE DÉMO sans réseau).
#
# Deux modes d'exécution :
#   --once               une seule collecte puis sortie (idéal pour cron/systemd).
#   --watch <intervalle> boucle infinie, rafraîchissement toutes les N secondes.
#
# Auteur  : Noumabeu Moutacdie Jordan
# Licence : MIT (voir le fichier LICENSE)

set -euo pipefail

# ----------------------------------------------------------------------------
# Localisation du script et chargement des bibliothèques (lib/)
# ----------------------------------------------------------------------------
# On résout le répertoire réel du script (en suivant un éventuel lien
# symbolique) afin de pouvoir l'appeler depuis n'importe où, y compris cron.
__resolve_script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [[ -h "${src}" ]]; do
    local dir
    dir="$(cd -P "$(dirname -- "${src}")" >/dev/null 2>&1 && pwd)"
    src="$(readlink -- "${src}")"
    [[ "${src}" != /* ]] && src="${dir}/${src}"
  done
  cd -P "$(dirname -- "${src}")" >/dev/null 2>&1 && pwd
}

SCRIPT_DIR="$(__resolve_script_dir)"
readonly SCRIPT_DIR
readonly LIB_DIR="${SCRIPT_DIR}/lib"

# shellcheck source=lib/log.sh
source "${LIB_DIR}/log.sh"
# shellcheck source=lib/metrics.sh
source "${LIB_DIR}/metrics.sh"
# shellcheck source=lib/alerting.sh
source "${LIB_DIR}/alerting.sh"

# ----------------------------------------------------------------------------
# Valeurs par défaut (surchargées par thresholds.conf et les options CLI)
# ----------------------------------------------------------------------------
readonly DEFAULT_CONFIG="${SCRIPT_DIR}/thresholds.conf"

# Seuils par défaut au cas où le fichier de configuration serait absent ou
# incomplet : le script reste pleinement fonctionnel sans configuration.
: "${CPU_WARN:=80}"
: "${CPU_CRIT:=90}"
: "${MEM_WARN:=80}"
: "${MEM_CRIT:=90}"
: "${DISK_WARN:=80}"
: "${DISK_CRIT:=90}"
: "${LOAD_WARN_RATIO:=1.0}"
: "${LOAD_CRIT_RATIO:=2.0}"

# Paramètres internes ajustables.
CONFIG_FILE="${DEFAULT_CONFIG}"   # chemin du fichier de configuration
MODE="once"                        # once | watch
WATCH_INTERVAL=5                   # secondes entre deux collectes en --watch
OUTPUT_JSON=0                      # 1 = sortie JSON, 0 = tableau humain
CPU_SAMPLE_INTERVAL=1              # fenêtre de mesure CPU (secondes)
TOP_COUNT=5                        # nombre de processus gourmands affichés
NO_ALERT=0                         # 1 = ne déclenche aucune alerte (lecture seule)

# Compteur d'alertes de la collecte courante (utilisé pour le code de sortie).
ALERTS_RAISED=0

# ----------------------------------------------------------------------------
# Aide / usage
# ----------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
surveillance-systeme, monitor.sh

Surveille CPU, mémoire, disque et charge système, puis déclenche des alertes
simples au-dessus de seuils configurables.

USAGE :
  monitor.sh [OPTIONS]

MODES (mutuellement exclusifs ; défaut : --once) :
  -o, --once              Effectue une seule collecte puis quitte.
  -w, --watch [SECONDES]  Boucle et rafraîchit toutes les SECONDES (défaut 5).

OPTIONS :
  -c, --config FICHIER    Fichier de seuils à charger (défaut : ./thresholds.conf).
  -j, --json              Sortie au format JSON (au lieu du tableau lisible).
  -n, --no-alert          Mode lecture seule : n'émet aucune alerte.
      --sample SECONDES   Fenêtre de mesure du CPU (défaut 1, accepte décimales).
      --top N             Nombre de processus les plus gourmands (défaut 5).
      --no-color          Désactive les couleurs (équivaut à NO_COLOR=1).
  -h, --help              Affiche cette aide et quitte.

CODES DE SORTIE :
  0   Tout est sous les seuils (aucune alerte).
  1   Erreur d'exécution (mauvaise option, plateforme non supportée…).
  2   Au moins une alerte a été déclenchée (seuil dépassé).

EXEMPLES :
  # Collecte unique, tableau lisible :
  ./monitor.sh --once

  # Collecte unique en JSON (pour ingestion par un autre outil) :
  ./monitor.sh --once --json

  # Surveillance continue toutes les 10 secondes :
  ./monitor.sh --watch 10

  # Utiliser un profil de seuils dédié sans émettre d'alerte :
  ./monitor.sh --once --config /etc/surveillance/db.conf --no-alert

VARIABLES D'ENVIRONNEMENT :
  NO_COLOR=1    Désactive les couleurs ANSI.
  LOG_DEBUG=1   Active les messages de débogage.

Le canal d'alerte (journal, webhook ou MODE DÉMO) se configure dans le fichier
de seuils. Sans URL de webhook, le projet reste 100 % hors-ligne (MODE DÉMO).
USAGE
}

# ----------------------------------------------------------------------------
# Analyse des arguments
# ----------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o|--once)
        MODE="once"
        shift
        ;;
      -w|--watch)
        MODE="watch"
        shift
        # L'intervalle est optionnel : s'il est présent et numérique, on le prend.
        if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
          WATCH_INTERVAL="$1"
          shift
        fi
        ;;
      -c|--config)
        [[ $# -ge 2 ]] || log_fatal "Option $1 : argument manquant." 1
        CONFIG_FILE="$2"
        shift 2
        ;;
      -j|--json)
        OUTPUT_JSON=1
        shift
        ;;
      -n|--no-alert)
        NO_ALERT=1
        shift
        ;;
      --sample)
        [[ $# -ge 2 ]] || log_fatal "Option $1 : argument manquant." 1
        CPU_SAMPLE_INTERVAL="$2"
        shift 2
        ;;
      --top)
        [[ $# -ge 2 ]] || log_fatal "Option $1 : argument manquant." 1
        TOP_COUNT="$2"
        shift 2
        ;;
      --no-color)
        # Pris en compte par lib/log.sh au chargement ; ici on ne peut que
        # neutraliser les variables déjà fixées pour les prochains affichages.
        export NO_COLOR=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        log_error "Option inconnue : $1"
        usage >&2
        exit 1
        ;;
      *)
        log_error "Argument inattendu : $1"
        usage >&2
        exit 1
        ;;
    esac
  done

  # Validations croisées.
  if [[ "${MODE}" == "watch" ]]; then
    if ! [[ "${WATCH_INTERVAL}" =~ ^[0-9]+$ ]] || (( WATCH_INTERVAL < 1 )); then
      log_fatal "L'intervalle de --watch doit être un entier >= 1." 1
    fi
  fi
  if ! [[ "${TOP_COUNT}" =~ ^[0-9]+$ ]] || (( TOP_COUNT < 1 )); then
    log_fatal "--top doit être un entier >= 1." 1
  fi
  if ! [[ "${CPU_SAMPLE_INTERVAL}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    log_fatal "--sample doit être un nombre (entier ou décimal)." 1
  fi
}

# ----------------------------------------------------------------------------
# Pré-requis plateforme
# ----------------------------------------------------------------------------
# Ce script s'appuie sur /proc (spécifique à Linux). On vérifie sa présence
# pour échouer proprement (ex. lancement par erreur sur macOS).
check_platform() {
  if [[ ! -r /proc/stat || ! -r /proc/meminfo || ! -r /proc/loadavg ]]; then
    log_error "Plateforme non supportée : /proc est introuvable ou illisible."
    log_error "Ce script nécessite un système Linux (pseudo-FS /proc)."
    exit 1
  fi
}

# ----------------------------------------------------------------------------
# Chargement de la configuration
# ----------------------------------------------------------------------------
load_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    # On vérifie la lisibilité avant de sourcer pour un message d'erreur clair.
    [[ -r "${CONFIG_FILE}" ]] \
      || log_fatal "Fichier de configuration illisible : ${CONFIG_FILE}" 1
    log_debug "Chargement de la configuration : ${CONFIG_FILE}"
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
  else
    log_warn "Fichier de configuration absent (${CONFIG_FILE}) : seuils par défaut."
  fi
}

# ----------------------------------------------------------------------------
# Évaluation des seuils
# ----------------------------------------------------------------------------
# Compare une valeur (décimale) à des seuils WARN/CRIT et renvoie le niveau.
# $1 = valeur, $2 = seuil warn, $3 = seuil crit.
# Sortie : "OK" | "WARN" | "CRIT".
classify() {
  local value="$1" warn="$2" crit="$3"
  awk -v v="${value}" -v w="${warn}" -v c="${crit}" 'BEGIN {
    if (v + 0 >= c + 0)      print "CRIT";
    else if (v + 0 >= w + 0) print "WARN";
    else                     print "OK";
  }'
}

# Traduit un niveau interne en sévérité humaine pour l'alerte.
severity_label() {
  case "$1" in
    CRIT) printf 'CRITIQUE' ;;
    WARN) printf 'AVERTISSEMENT' ;;
    *)    printf 'OK' ;;
  esac
}

# Colore une cellule d'état pour le tableau (no-op si couleurs désactivées).
colorize_state() {
  local state="$1"
  case "${state}" in
    CRIT) printf '%sCRIT%s' "${LOG_COLOR_RED}"    "${LOG_COLOR_RESET}" ;;
    WARN) printf '%sWARN%s' "${LOG_COLOR_YELLOW}" "${LOG_COLOR_RESET}" ;;
    *)    printf '%sOK%s'   "${LOG_COLOR_GREEN}"  "${LOG_COLOR_RESET}" ;;
  esac
}

# Déclenche une alerte si le niveau l'exige et si les alertes sont activées.
# $1 = niveau (WARN/CRIT), $2 = métrique, $3 = valeur, $4 = seuil, $5 = message.
maybe_alert() {
  local level="$1" metric="$2" value="$3" threshold="$4" message="$5"
  [[ "${level}" == "OK" ]] && return 0
  ALERTS_RAISED=$(( ALERTS_RAISED + 1 ))
  [[ "${NO_ALERT}" == "1" ]] && return 0
  alert_trigger "$(severity_label "${level}")" \
    "${metric}" "${value}" "${threshold}" "${message}"
}

# ----------------------------------------------------------------------------
# Conversion d'unités
# ----------------------------------------------------------------------------
# Convertit des kilo-octets en une chaîne lisible (Ko/Mo/Go/To).
kb_to_human() {
  local kb="$1"
  awk -v kb="${kb}" 'BEGIN {
    split("Ko Mo Go To Po", u, " ");
    i = 1; v = kb + 0;
    while (v >= 1024 && i < 5) { v /= 1024; i++; }
    printf "%.1f%s", v, u[i];
  }'
}

# ----------------------------------------------------------------------------
# Collecte d'une « photographie » complète du système
# ----------------------------------------------------------------------------
# Les résultats sont stockés dans des variables globales pour être ensuite
# rendus soit en tableau, soit en JSON, sans recollecter.
declare -g SNAP_TIMESTAMP=""
declare -g SNAP_HOST=""
declare -g SNAP_UPTIME_HUMAN=""
declare -g SNAP_CPU_PCT=""
declare -g SNAP_CPU_STATE=""
declare -g SNAP_MEM_PCT=""
declare -g SNAP_MEM_USED_KB=""
declare -g SNAP_MEM_TOTAL_KB=""
declare -g SNAP_MEM_STATE=""
declare -g SNAP_LOAD1=""
declare -g SNAP_LOAD5=""
declare -g SNAP_LOAD15=""
declare -g SNAP_CPU_COUNT=""
declare -g SNAP_LOAD_RATIO=""
declare -g SNAP_LOAD_STATE=""
declare -ga SNAP_DISKS=()       # éléments : "mount|pct|used_kb|size_kb|state"
declare -ga SNAP_TOP=()         # éléments : "pid|pcpu|pmem|cmd"

collect_snapshot() {
  SNAP_TIMESTAMP="$(date +"%Y-%m-%dT%H:%M:%S%z")"
  SNAP_HOST="$(hostname 2>/dev/null || echo "inconnu")"

  # Uptime.
  local up_seconds up_human
  read -r up_seconds up_human < <(metric_uptime)
  SNAP_UPTIME_HUMAN="${up_human}"

  # CPU (mesure bloquante de CPU_SAMPLE_INTERVAL secondes).
  SNAP_CPU_PCT="$(metric_cpu_usage "${CPU_SAMPLE_INTERVAL}")"
  SNAP_CPU_STATE="$(classify "${SNAP_CPU_PCT}" "${CPU_WARN}" "${CPU_CRIT}")"

  # Mémoire.
  read -r SNAP_MEM_TOTAL_KB SNAP_MEM_USED_KB SNAP_MEM_PCT < <(metric_mem_usage)
  SNAP_MEM_STATE="$(classify "${SNAP_MEM_PCT}" "${MEM_WARN}" "${MEM_CRIT}")"

  # Charge système relativisée au nombre de cœurs.
  read -r SNAP_LOAD1 SNAP_LOAD5 SNAP_LOAD15 < <(metric_loadavg)
  SNAP_CPU_COUNT="$(metric_cpu_count)"
  SNAP_LOAD_RATIO="$(awk -v l="${SNAP_LOAD1}" -v c="${SNAP_CPU_COUNT}" \
    'BEGIN { if (c + 0 > 0) printf "%.2f", l / c; else printf "0.00" }')"
  SNAP_LOAD_STATE="$(classify "${SNAP_LOAD_RATIO}" \
    "${LOAD_WARN_RATIO}" "${LOAD_CRIT_RATIO}")"

  # Disques (un état par montage).
  SNAP_DISKS=()
  local mount pct used_kb size_kb dstate
  while read -r mount pct used_kb size_kb; do
    [[ -z "${mount}" ]] && continue
    dstate="$(classify "${pct}" "${DISK_WARN}" "${DISK_CRIT}")"
    SNAP_DISKS+=("${mount}|${pct}|${used_kb}|${size_kb}|${dstate}")
  done < <(metric_disk_usage)

  # Processus les plus gourmands.
  SNAP_TOP=()
  local pid pcpu pmem cmd
  while IFS=$'\t' read -r pid pcpu pmem cmd; do
    [[ -z "${pid}" ]] && continue
    SNAP_TOP+=("${pid}|${pcpu}|${pmem}|${cmd}")
  done < <(metric_top_processes "${TOP_COUNT}")
}

# ----------------------------------------------------------------------------
# Déclenchement des alertes à partir de la photographie courante
# ----------------------------------------------------------------------------
evaluate_and_alert() {
  ALERTS_RAISED=0

  maybe_alert "${SNAP_CPU_STATE}" "CPU" "${SNAP_CPU_PCT}%" \
    "${CPU_WARN}/${CPU_CRIT}%" "Utilisation CPU élevée"

  maybe_alert "${SNAP_MEM_STATE}" "RAM" "${SNAP_MEM_PCT}%" \
    "${MEM_WARN}/${MEM_CRIT}%" "Utilisation mémoire élevée"

  maybe_alert "${SNAP_LOAD_STATE}" "LOAD" \
    "${SNAP_LOAD1} (ratio ${SNAP_LOAD_RATIO})" \
    "${LOAD_WARN_RATIO}/${LOAD_CRIT_RATIO}" \
    "Charge système élevée (${SNAP_CPU_COUNT} cœurs)"

  local entry mount pct used_kb size_kb dstate
  if (( ${#SNAP_DISKS[@]} > 0 )); then
    for entry in "${SNAP_DISKS[@]}"; do
      IFS='|' read -r mount pct used_kb size_kb dstate <<<"${entry}"
      maybe_alert "${dstate}" "DISK:${mount}" "${pct}%" \
        "${DISK_WARN}/${DISK_CRIT}%" "Espace disque faible sur ${mount}"
    done
  fi
}

# ----------------------------------------------------------------------------
# Rendu : tableau lisible
# ----------------------------------------------------------------------------
render_table() {
  local bold="" reset=""
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    bold=$'\033[1m'
    reset=$'\033[0m'
  fi

  printf '%s== Surveillance système ==%s  %s  (hôte : %s, uptime : %s)\n' \
    "${bold}" "${reset}" "${SNAP_TIMESTAMP}" "${SNAP_HOST}" "${SNAP_UPTIME_HUMAN}"
  printf '\n'

  # Tableau synthétique des ressources globales.
  printf '%-10s %-12s %-22s %-8s\n' \
    "RESSOURCE" "VALEUR" "SEUILS (W/C)" "ÉTAT"
  printf -- '%.0s-' {1..56}; printf '\n'

  printf '%-10s %-12s %-22s %b\n' \
    "CPU" "${SNAP_CPU_PCT}%" "${CPU_WARN}/${CPU_CRIT}%" \
    "$(colorize_state "${SNAP_CPU_STATE}")"

  printf '%-10s %-12s %-22s %b\n' \
    "RAM" "${SNAP_MEM_PCT}%" "${MEM_WARN}/${MEM_CRIT}%" \
    "$(colorize_state "${SNAP_MEM_STATE}")"

  printf '%-10s %-12s %-22s %b\n' \
    "Charge" "${SNAP_LOAD1}" \
    "ratio ${LOAD_WARN_RATIO}/${LOAD_CRIT_RATIO}" \
    "$(colorize_state "${SNAP_LOAD_STATE}")"

  printf '%s  (load 1/5/15 : %s / %s / %s, %s cœurs, ratio %s)%s\n' \
    "${LOG_COLOR_DIM}" \
    "${SNAP_LOAD1}" "${SNAP_LOAD5}" "${SNAP_LOAD15}" \
    "${SNAP_CPU_COUNT}" "${SNAP_LOAD_RATIO}" \
    "${LOG_COLOR_RESET}"

  # Tableau des disques (par montage).
  printf '\n'
  printf '%-24s %-8s %-20s %-8s\n' "MONTAGE" "USAGE" "UTILISÉ / TOTAL" "ÉTAT"
  printf -- '%.0s-' {1..62}; printf '\n'
  if (( ${#SNAP_DISKS[@]} == 0 )); then
    printf '%s(aucun système de fichiers réel détecté)%s\n' \
      "${LOG_COLOR_DIM}" "${LOG_COLOR_RESET}"
  else
    local entry mount pct used_kb size_kb dstate
    for entry in "${SNAP_DISKS[@]}"; do
      IFS='|' read -r mount pct used_kb size_kb dstate <<<"${entry}"
      printf '%-24s %-8s %-20s %b\n' \
        "${mount}" "${pct}%" \
        "$(kb_to_human "${used_kb}") / $(kb_to_human "${size_kb}")" \
        "$(colorize_state "${dstate}")"
    done
  fi

  # Tableau des processus les plus gourmands.
  printf '\n'
  printf '%-8s %-7s %-7s %-26s\n' "PID" "%CPU" "%MEM" "COMMANDE"
  printf -- '%.0s-' {1..52}; printf '\n'
  if (( ${#SNAP_TOP[@]} == 0 )); then
    printf '%s(impossible de lister les processus)%s\n' \
      "${LOG_COLOR_DIM}" "${LOG_COLOR_RESET}"
  else
    local entry pid pcpu pmem cmd
    for entry in "${SNAP_TOP[@]}"; do
      IFS='|' read -r pid pcpu pmem cmd <<<"${entry}"
      printf '%-8s %-7s %-7s %-26s\n' "${pid}" "${pcpu}" "${pmem}" "${cmd}"
    done
  fi
  printf '\n'
}

# ----------------------------------------------------------------------------
# Rendu : JSON
# ----------------------------------------------------------------------------
# Échappe une chaîne pour une valeur JSON (réutilise la logique d'alerting).
json_escape() {
  __alert_json_escape "$1"
}

render_json() {
  local out="{"
  out+='"timestamp":"'"$(json_escape "${SNAP_TIMESTAMP}")"'",'
  out+='"host":"'"$(json_escape "${SNAP_HOST}")"'",'
  out+='"uptime":"'"$(json_escape "${SNAP_UPTIME_HUMAN}")"'",'

  # CPU.
  out+='"cpu":{"usage_percent":'"${SNAP_CPU_PCT}"','
  out+='"warn":'"${CPU_WARN}"',"crit":'"${CPU_CRIT}"','
  out+='"state":"'"${SNAP_CPU_STATE}"'"},'

  # Mémoire.
  out+='"memory":{"usage_percent":'"${SNAP_MEM_PCT}"','
  out+='"used_kb":'"${SNAP_MEM_USED_KB}"',"total_kb":'"${SNAP_MEM_TOTAL_KB}"','
  out+='"warn":'"${MEM_WARN}"',"crit":'"${MEM_CRIT}"','
  out+='"state":"'"${SNAP_MEM_STATE}"'"},'

  # Charge.
  out+='"load":{"avg1":'"${SNAP_LOAD1}"',"avg5":'"${SNAP_LOAD5}"','
  out+='"avg15":'"${SNAP_LOAD15}"',"cpu_count":'"${SNAP_CPU_COUNT}"','
  out+='"ratio":'"${SNAP_LOAD_RATIO}"','
  out+='"warn_ratio":'"${LOAD_WARN_RATIO}"',"crit_ratio":'"${LOAD_CRIT_RATIO}"','
  out+='"state":"'"${SNAP_LOAD_STATE}"'"},'

  # Disques.
  out+='"disks":['
  local first=1 entry mount pct used_kb size_kb dstate
  if (( ${#SNAP_DISKS[@]} > 0 )); then
    for entry in "${SNAP_DISKS[@]}"; do
      IFS='|' read -r mount pct used_kb size_kb dstate <<<"${entry}"
      (( first )) || out+=','
      first=0
      out+='{"mount":"'"$(json_escape "${mount}")"'",'
      out+='"usage_percent":'"${pct}"','
      out+='"used_kb":'"${used_kb}"',"size_kb":'"${size_kb}"','
      out+='"state":"'"${dstate}"'"}'
    done
  fi
  out+='],'

  # Processus.
  out+='"top_processes":['
  first=1
  local pid pcpu pmem cmd
  if (( ${#SNAP_TOP[@]} > 0 )); then
    for entry in "${SNAP_TOP[@]}"; do
      IFS='|' read -r pid pcpu pmem cmd <<<"${entry}"
      (( first )) || out+=','
      first=0
      out+='{"pid":'"${pid}"',"cpu_percent":'"${pcpu}"','
      out+='"mem_percent":'"${pmem}"',"command":"'"$(json_escape "${cmd}")"'"}'
    done
  fi
  out+='],'

  out+='"alerts_raised":'"${ALERTS_RAISED}"'}'

  printf '%s\n' "${out}"
}

# ----------------------------------------------------------------------------
# Cycle complet : collecte -> alertes -> rendu
# ----------------------------------------------------------------------------
run_cycle() {
  collect_snapshot
  evaluate_and_alert
  if (( OUTPUT_JSON )); then
    render_json
  else
    render_table
  fi
}

# ----------------------------------------------------------------------------
# Boucle de surveillance (--watch)
# ----------------------------------------------------------------------------
# Gestion propre de Ctrl-C / SIGTERM pour quitter sans trace d'erreur.
__watch_running=1
__on_interrupt() {
  __watch_running=0
  log_note "Arrêt demandé, fin de la surveillance."
}

run_watch() {
  trap '__on_interrupt' INT TERM
  log_info "Surveillance en continu (intervalle ${WATCH_INTERVAL}s). Ctrl-C pour quitter."
  while (( __watch_running )); do
    # En mode tableau interactif, on efface l'écran pour un effet « live ».
    if (( ! OUTPUT_JSON )) && [[ -t 1 ]]; then
      clear 2>/dev/null || true
    fi
    run_cycle || true
    # On découpe l'attente en tranches d'1 s pour réagir vite au signal.
    local remaining="${WATCH_INTERVAL}"
    while (( remaining > 0 && __watch_running )); do
      sleep 1
      remaining=$(( remaining - 1 ))
    done
  done
}

# ----------------------------------------------------------------------------
# Point d'entrée
# ----------------------------------------------------------------------------
main() {
  parse_args "$@"
  check_platform
  load_config

  case "${MODE}" in
    once)
      run_cycle
      # Code de sortie 2 si au moins une alerte a été levée (utile pour cron).
      (( ALERTS_RAISED > 0 )) && exit 2
      exit 0
      ;;
    watch)
      run_watch
      exit 0
      ;;
    *)
      log_fatal "Mode interne inconnu : ${MODE}" 1
      ;;
  esac
}

main "$@"
