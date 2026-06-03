#!/usr/bin/env bash
# lib/metrics.sh — Collecte des métriques système via /proc, df, uptime, ps.
#
# Ce module ne dépend d'aucun outil externe non standard : il s'appuie
# uniquement sur le pseudo-système de fichiers /proc et sur les commandes
# POSIX/coreutils habituelles (df, ps, uptime, nproc, awk).
#
# Toutes les fonctions « metric_* » écrivent leur résultat sur la sortie
# standard sous une forme facilement consommable par monitor.sh.

if [[ -n "${__LIB_METRICS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
__LIB_METRICS_SOURCED=1

# ----------------------------------------------------------------------------
# CPU
# ----------------------------------------------------------------------------
# Lit une ligne agrégée "cpu" depuis /proc/stat et renvoie le total de jiffies
# ainsi que les jiffies inactifs (idle + iowait).
# Sortie : "<total> <idle>"
__metric_cpu_sample() {
  # Champs de /proc/stat ligne "cpu" :
  # user nice system idle iowait irq softirq steal guest guest_nice
  local cpu user nice system idle iowait irq softirq steal _rest
  # shellcheck disable=SC2034  # certaines variables ne servent qu'au parsing
  read -r cpu user nice system idle iowait irq softirq steal _rest \
    < <(grep -E '^cpu ' /proc/stat)

  local idle_all=$(( idle + iowait ))
  local non_idle=$(( user + nice + system + irq + softirq + steal ))
  local total=$(( idle_all + non_idle ))
  printf '%s %s\n' "${total}" "${idle_all}"
}

# Calcule le pourcentage d'utilisation CPU global sur une fenêtre de mesure.
# $1 = durée d'échantillonnage en secondes (défaut 1 ; accepte les décimales).
# Sortie : pourcentage avec une décimale, ex. "12.5".
metric_cpu_usage() {
  local interval="${1:-1}"

  local sample1 sample2
  sample1="$(__metric_cpu_sample)"
  sleep "${interval}"
  sample2="$(__metric_cpu_sample)"

  local total1 idle1 total2 idle2
  read -r total1 idle1 <<<"${sample1}"
  read -r total2 idle2 <<<"${sample2}"

  local total_delta=$(( total2 - total1 ))
  local idle_delta=$(( idle2 - idle1 ))

  # Évite toute division par zéro (machine au repos absolu / lecture identique).
  if (( total_delta <= 0 )); then
    printf '0.0\n'
    return 0
  fi

  awk -v td="${total_delta}" -v idd="${idle_delta}" \
    'BEGIN { printf "%.1f", (td - idd) / td * 100 }'
}

# ----------------------------------------------------------------------------
# Mémoire
# ----------------------------------------------------------------------------
# Renvoie l'usage mémoire à partir de /proc/meminfo.
# Sortie : "<total_ko> <used_ko> <pct_used>"
# La mémoire « utilisée » suit la définition moderne :
#   used = MemTotal - MemAvailable
metric_mem_usage() {
  local total avail
  total="$(awk '/^MemTotal:/  { print $2; exit }' /proc/meminfo)"
  avail="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)"

  # Repli si MemAvailable est absent (noyaux très anciens) : on l'approxime.
  if [[ -z "${avail}" ]]; then
    local free buffers cached
    free="$(awk '/^MemFree:/  { print $2; exit }' /proc/meminfo)"
    buffers="$(awk '/^Buffers:/ { print $2; exit }' /proc/meminfo)"
    cached="$(awk '/^Cached:/  { print $2; exit }' /proc/meminfo)"
    avail=$(( free + buffers + cached ))
  fi

  local used=$(( total - avail ))
  local pct
  pct="$(awk -v u="${used}" -v t="${total}" \
    'BEGIN { if (t > 0) printf "%.1f", u / t * 100; else printf "0.0" }')"

  printf '%s %s %s\n' "${total}" "${used}" "${pct}"
}

# ----------------------------------------------------------------------------
# Charge système (load average)
# ----------------------------------------------------------------------------
# Renvoie les trois moyennes de charge depuis /proc/loadavg.
# Sortie : "<1min> <5min> <15min>"
metric_loadavg() {
  local l1 l5 l15 _rest
  read -r l1 l5 l15 _rest </proc/loadavg
  printf '%s %s %s\n' "${l1}" "${l5}" "${l15}"
}

# Renvoie le nombre de CPU logiques (pour relativiser la charge).
metric_cpu_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  else
    grep -c '^processor' /proc/cpuinfo
  fi
}

# ----------------------------------------------------------------------------
# Disque
# ----------------------------------------------------------------------------
# Énumère les systèmes de fichiers « réels » et leur taux d'occupation.
# On exclut les pseudo-systèmes de fichiers (tmpfs, proc, sysfs, etc.) afin de
# se concentrer sur l'espace de stockage pertinent.
# Sortie (une ligne par montage) :
#   "<montage> <pct_used> <used_human> <size_human>"
metric_disk_usage() {
  # -P : format POSIX (une ligne par FS, colonnes stables)
  # -x : exclut les types de FS virtuels.
  df -P -x tmpfs -x devtmpfs -x proc -x sysfs -x overlay \
        -x squashfs -x udev -x cgroup -x cgroup2 -x debugfs \
        -x mqueue -x tracefs -x configfs -x pstore 2>/dev/null \
    | awk 'NR > 1 {
        pct = $5; gsub(/%/, "", pct);
        # $6 = point de montage, $3 = utilisé (Ko), $2 = taille (Ko)
        printf "%s %s %s %s\n", $6, pct, $3, $2
      }'
}

# ----------------------------------------------------------------------------
# Disponibilité (uptime)
# ----------------------------------------------------------------------------
# Renvoie la durée de fonctionnement depuis /proc/uptime, formatée lisiblement.
# Sortie : "<secondes_entieres> <texte_humain>"
metric_uptime() {
  local up_seconds _idle
  read -r up_seconds _idle </proc/uptime
  # /proc/uptime fournit des secondes en décimal ; on tronque à l'entier.
  up_seconds="${up_seconds%.*}"

  local days hours minutes
  days=$(( up_seconds / 86400 ))
  hours=$(( (up_seconds % 86400) / 3600 ))
  minutes=$(( (up_seconds % 3600) / 60 ))

  local human=""
  (( days > 0 ))  && human+="${days}j "
  (( hours > 0 )) && human+="${hours}h "
  human+="${minutes}min"

  printf '%s %s\n' "${up_seconds}" "${human}"
}

# ----------------------------------------------------------------------------
# Processus les plus gourmands
# ----------------------------------------------------------------------------
# Renvoie les N processus consommant le plus de CPU (puis de mémoire).
# $1 = nombre de processus à retourner (défaut 5).
# Sortie (une ligne par processus, séparée par des tabulations) :
#   "<pid>\t<%cpu>\t<%mem>\t<commande>"
metric_top_processes() {
  local count="${1:-5}"

  # On s'appuie sur ps qui agrège déjà %cpu et %mem par processus.
  # --no-headers : pas d'en-tête ; --sort=-%cpu : tri décroissant CPU.
  # comm tronqué via awk pour rester lisible dans le tableau.
  ps -eo pid,pcpu,pmem,comm --no-headers --sort=-pcpu 2>/dev/null \
    | head -n "${count}" \
    | awk '{
        cmd = $4;
        for (i = 5; i <= NF; i++) cmd = cmd " " $i;
        if (length(cmd) > 24) cmd = substr(cmd, 1, 23) "…";
        printf "%s\t%s\t%s\t%s\n", $1, $2, $3, cmd;
      }'
}
