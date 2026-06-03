#!/usr/bin/env bash
# lib/alerting.sh — Émission d'alertes (journal + webhook optionnel).
#
# Stratégie d'alerte volontairement simple et sans dépendance lourde :
#   - Toute alerte est TOUJOURS journalisée (fichier de log + stderr).
#   - Si un webhook est configuré (variable ALERT_WEBHOOK_URL non vide) ET que
#     curl est disponible, l'alerte est aussi envoyée en HTTP POST (JSON).
#   - Sinon, le projet bascule en MODE DÉMO : aucune connexion réseau n'est
#     tentée, mais le payload qui « aurait été » envoyé est affiché, ce qui
#     permet de démontrer la chaîne d'alerte hors-ligne (utile en portfolio).
#
# Ce module dépend de lib/log.sh (sourcé par l'appelant).

if [[ -n "${__LIB_ALERTING_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
__LIB_ALERTING_SOURCED=1

# Fichier de journal des alertes. Surchargé par thresholds.conf / l'appelant.
: "${ALERT_LOG_FILE:=/tmp/surveillance-systeme-alerts.log}"
# URL de webhook (vide = MODE DÉMO).
: "${ALERT_WEBHOOK_URL:=}"
# Délai maximal (secondes) pour l'appel curl.
: "${ALERT_WEBHOOK_TIMEOUT:=5}"
# Forçage du mode démo même si une URL est présente (utile pour tester).
: "${ALERT_DEMO_MODE:=0}"

# Indique si l'envoi réseau est réellement possible.
# Retour : 0 (vrai) si webhook utilisable, 1 (faux) si mode démo.
__alert_network_enabled() {
  [[ "${ALERT_DEMO_MODE}" != "1" ]] || return 1
  [[ -n "${ALERT_WEBHOOK_URL}" ]]   || return 1
  command -v curl >/dev/null 2>&1   || return 1
  return 0
}

# Échappe une chaîne pour insertion dans une valeur JSON.
# $1 = chaîne brute. Sortie : chaîne échappée (sans guillemets englobants).
__alert_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"   # antislash
  s="${s//\"/\\\"}"   # guillemet double
  s="${s//$'\n'/\\n}" # saut de ligne
  s="${s//$'\t'/\\t}" # tabulation
  s="${s//$'\r'/}"    # retour chariot
  printf '%s' "${s}"
}

# Construit le payload JSON d'une alerte.
# $1 = sévérité, $2 = métrique, $3 = valeur, $4 = seuil, $5 = message.
__alert_build_payload() {
  local severity="$1" metric="$2" value="$3" threshold="$4" message="$5"
  local host iso
  host="$(hostname 2>/dev/null || echo "inconnu")"
  iso="$(date +"%Y-%m-%dT%H:%M:%S%z")"

  printf '{"timestamp":"%s","host":"%s","severity":"%s","metric":"%s","value":"%s","threshold":"%s","message":"%s"}' \
    "$(__alert_json_escape "${iso}")" \
    "$(__alert_json_escape "${host}")" \
    "$(__alert_json_escape "${severity}")" \
    "$(__alert_json_escape "${metric}")" \
    "$(__alert_json_escape "${value}")" \
    "$(__alert_json_escape "${threshold}")" \
    "$(__alert_json_escape "${message}")"
}

# Garantit l'existence du fichier de log d'alertes (création + répertoire).
__alert_ensure_logfile() {
  local dir
  dir="$(dirname -- "${ALERT_LOG_FILE}")"
  if [[ ! -d "${dir}" ]]; then
    mkdir -p -- "${dir}" 2>/dev/null || return 1
  fi
  # touch idempotent ; échec silencieux toléré (on log quand même sur stderr).
  : >>"${ALERT_LOG_FILE}" 2>/dev/null || return 1
  return 0
}

# Point d'entrée principal : déclenche une alerte.
# Usage :
#   alert_trigger <severite> <metrique> <valeur> <seuil> <message>
# Exemple :
#   alert_trigger "CRITIQUE" "CPU" "92.0" "85" "Utilisation CPU élevée"
alert_trigger() {
  local severity="$1" metric="$2" value="$3" threshold="$4" message="$5"

  local payload line
  payload="$(__alert_build_payload "$@")"
  line="[${severity}] ${metric}=${value} (seuil ${threshold}) — ${message}"

  # 1) Journalisation systématique (fichier + stderr coloré).
  if __alert_ensure_logfile; then
    printf '%s %s\n' "$(date +"%Y-%m-%dT%H:%M:%S%z")" "${line}" \
      >>"${ALERT_LOG_FILE}"
  else
    log_warn "Impossible d'écrire dans le journal d'alertes : ${ALERT_LOG_FILE}"
  fi

  case "${severity}" in
    CRITIQUE) log_error "ALERTE ${line}" ;;
    *)        log_warn  "ALERTE ${line}" ;;
  esac

  # 2) Notification réseau ou mode démo.
  if __alert_network_enabled; then
    __alert_send_webhook "${payload}"
  else
    log_note "MODE DÉMO (aucun réseau) — payload qui aurait été envoyé :"
    printf '%s\n' "${payload}" >&2
  fi
}

# Envoie le payload JSON au webhook configuré via curl.
# $1 = payload JSON. Retour : 0 si succès HTTP 2xx, 1 sinon.
__alert_send_webhook() {
  local payload="$1"
  local http_code

  log_info "Envoi de l'alerte au webhook configuré…"

  # -s silencieux, -S affiche les erreurs, --max-time borne la durée,
  # -w récupère le code HTTP, -o /dev/null jette le corps de réponse.
  http_code="$(curl -sS \
    --max-time "${ALERT_WEBHOOK_TIMEOUT}" \
    -o /dev/null \
    -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -X POST \
    --data "${payload}" \
    "${ALERT_WEBHOOK_URL}" 2>/dev/null)" || {
      log_warn "Échec de l'appel curl vers le webhook (réseau indisponible ?)."
      return 1
    }

  if [[ "${http_code}" =~ ^2[0-9][0-9]$ ]]; then
    log_info "Webhook notifié avec succès (HTTP ${http_code})."
    return 0
  fi

  log_warn "Le webhook a répondu un code inattendu : HTTP ${http_code}."
  return 1
}
