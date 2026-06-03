#!/usr/bin/env bash
# lib/log.sh, Helpers de journalisation horodatée et colorée.
#
# Ce fichier est destiné à être « sourcé » par les autres scripts du projet.
# Il fournit des fonctions de log uniformes (info/avertissement/erreur/debug)
# avec horodatage ISO-8601 et couleurs ANSI désactivables automatiquement
# lorsque la sortie n'est pas un terminal (ex. redirection vers un fichier).

# Empêche le double chargement si le fichier est sourcé plusieurs fois.
if [[ -n "${__LIB_LOG_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
__LIB_LOG_SOURCED=1

# ----------------------------------------------------------------------------
# Gestion des couleurs
# ----------------------------------------------------------------------------
# Les couleurs sont activées uniquement si :
#   - la sortie d'erreur standard est un terminal,
#   - et la variable d'environnement NO_COLOR n'est pas définie
#     (cf. convention https://no-color.org/).
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  readonly LOG_COLOR_RESET=$'\033[0m'
  readonly LOG_COLOR_DIM=$'\033[2m'
  readonly LOG_COLOR_RED=$'\033[31m'
  readonly LOG_COLOR_GREEN=$'\033[32m'
  readonly LOG_COLOR_YELLOW=$'\033[33m'
  readonly LOG_COLOR_BLUE=$'\033[34m'
  readonly LOG_COLOR_CYAN=$'\033[36m'
else
  readonly LOG_COLOR_RESET=""
  readonly LOG_COLOR_DIM=""
  readonly LOG_COLOR_RED=""
  readonly LOG_COLOR_GREEN=""
  readonly LOG_COLOR_YELLOW=""
  readonly LOG_COLOR_BLUE=""
  readonly LOG_COLOR_CYAN=""
fi

# Niveau de verbosité. Mettre LOG_DEBUG=1 dans l'environnement pour activer
# les messages de débogage.
: "${LOG_DEBUG:=0}"

# Renvoie l'horodatage courant au format ISO-8601 (secondes).
__log_timestamp() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

# Fonction interne générique d'écriture d'un message de log.
# $1 = couleur, $2 = niveau (texte), $3.. = message.
# Tous les logs sont écrits sur la sortie d'erreur standard (stderr) afin de
# ne pas polluer la sortie standard (réservée aux données : tableau, JSON…).
__log_emit() {
  local color="$1"
  local level="$2"
  shift 2
  printf '%s%s [%s]%s %s\n' \
    "${color}" "$(__log_timestamp)" "${level}" "${LOG_COLOR_RESET}" "$*" >&2
}

# Message d'information (vert).
log_info() {
  __log_emit "${LOG_COLOR_GREEN}" "INFO " "$*"
}

# Message d'avertissement (jaune).
log_warn() {
  __log_emit "${LOG_COLOR_YELLOW}" "WARN " "$*"
}

# Message d'erreur (rouge).
log_error() {
  __log_emit "${LOG_COLOR_RED}" "ERROR" "$*"
}

# Message de débogage (gris), affiché uniquement si LOG_DEBUG=1.
log_debug() {
  [[ "${LOG_DEBUG}" == "1" ]] || return 0
  __log_emit "${LOG_COLOR_DIM}" "DEBUG" "$*"
}

# Message neutre/structurel (cyan), utile pour les bannières.
log_note() {
  __log_emit "${LOG_COLOR_CYAN}" "NOTE " "$*"
}

# Affiche un message d'erreur puis quitte avec le code fourni (défaut 1).
# Usage : log_fatal "message" [code]
log_fatal() {
  local msg="$1"
  local code="${2:-1}"
  log_error "${msg}"
  exit "${code}"
}
