#!/usr/bin/env bash
# MAIA — instalador global (sin clonar el repo), estilo Codex CLI / Claude Code.
# Instala el comando `maia` vía `uv tool install` desde el feed privado de Azure Artifacts.
# Compatible: macOS (bash 3.2+) · Linux. Ver docs/v2/PUBLISHING.md para el lado de publicación.
#
# Uso:
#   curl -fsSL https://raw.githubusercontent.com/IA-IDS/maia-installer/main/install.sh | bash
#   MAIA_ARTIFACTS_PAT=<pat> bash install.sh        # no interactivo (CI/scripted) —
#     en un shell interactivo, prefiere `read -s` (no lo tipees en la línea de comandos:
#     queda en el historial de la shell en texto plano).
#
# Verificado contra doc oficial (no adivinado):
#   - Formato del feed: learn.microsoft.com "Publish and download Python packages with Azure Artifacts"
#   - Auth por índice de uv: docs.astral.sh/uv/concepts/indexes + reference/environment
#     (UV_INDEX_<NAME>_USERNAME/PASSWORD, credenciales embebidas en la URL del índice)
#   - Ruta de config global de uv: docs.astral.sh/uv/concepts/configuration-files
#     (~/.config/uv/uv.toml en macOS/Linux)
#
# Manejo del PAT (revisión de seguridad, corregido): nunca se pasa como argumento de línea
# de comandos (visible vía `ps`/`/proc/<pid>/cmdline` a otros usuarios de la misma máquina) —
# solo vive en una variable de shell y en ~/.config/uv/uv.toml, que queda con permisos 600
# (solo el dueño puede leerlo) justo después de escribirlo.

set -euo pipefail

ORG="erikramosids"
PROJECT="maia-for-developers"
FEED="maia-sdlc"
PACKAGE="maia-sdlc"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
warn() { echo -e "  ${YELLOW}→${RESET} $*"; }
err()  { echo -e "  ${RED}✗${RESET} $*" >&2; }

echo -e "${BOLD}MAIA — instalador global${RESET} (feed: ${FEED})"
echo

# ─── 1) uv (gestor de Python que ya usa este proyecto) ───────────────────────
if ! command -v uv >/dev/null 2>&1; then
  warn "uv no está instalado — instalándolo (astral.sh/uv, oficial)..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
if ! command -v uv >/dev/null 2>&1; then
  err "uv se instaló pero no está en el PATH de esta shell — abre una terminal nueva y reintenta."
  exit 1
fi
ok "uv disponible ($(uv --version))"

# ─── 2) PAT del feed (scope: Packaging → Read) ───────────────────────────────
PAT="${MAIA_ARTIFACTS_PAT:-}"
if [ -z "$PAT" ]; then
  echo
  echo "  El feed de MAIA es privado (Azure Artifacts) — necesitas un Personal Access Token."
  echo "  Genéralo en: https://dev.azure.com/${ORG}/_usersSettings/tokens"
  echo "  Scope requerido: Packaging → Read"
  echo
  read -r -s -p "  Pega tu PAT: " PAT
  echo
fi
if [ -z "$PAT" ]; then
  err "Sin PAT no se puede autenticar contra el feed privado."
  exit 1
fi

# ─── 3) Configura el índice, con credenciales embebidas (patrón oficial de uv) ─
UV_CONFIG_DIR="$HOME/.config/uv"
UV_CONFIG_FILE="$UV_CONFIG_DIR/uv.toml"
( umask 077 && mkdir -p "$UV_CONFIG_DIR" )
AUTHED_INDEX_URL="https://pat:${PAT}@pkgs.dev.azure.com/${ORG}/${PROJECT}/_packaging/${FEED}/pypi/simple/"

# Refuerza permisos SIEMPRE, no solo cuando reescribimos — un uv.toml dejado con permisos
# laxos por una corrida anterior (o por otra herramienta) debe corregirse en cada ejecución,
# no solo la primera vez que este script escribe el índice (bug real: una corrida anterior de
# este script podía dejarlo así y una corrida posterior que solo detecta "ya configurado" nunca
# volvía a corregirlo).
if [ -f "$UV_CONFIG_FILE" ]; then
  chmod 600 "$UV_CONFIG_FILE"
fi

if [ -f "$UV_CONFIG_FILE" ] && grep -q "name = \"${FEED}\"" "$UV_CONFIG_FILE" 2>/dev/null; then
  warn "~/.config/uv/uv.toml ya tiene el índice '${FEED}' — no lo duplico (bórralo a mano si el PAT venció)."
else
  # Escribe en un archivo temporal (mktemp lo crea con permisos 600 desde su creación —
  # comportamiento estándar de GNU coreutils/BSD) y muévelo encima con `mv` (atómico en el
  # mismo filesystem) — así el PAT nunca queda, ni por un instante, en un archivo con permisos
  # abiertos: evita la carrera de "escribir el secreto primero, restringir permisos después"
  # (TOCTOU) que tenía la versión anterior (`>> archivo` seguido de `chmod`).
  UV_CONFIG_TMP="$(mktemp "${UV_CONFIG_DIR}/.uv.toml.XXXXXX")"
  trap 'rm -f "$UV_CONFIG_TMP"' EXIT
  if [ -f "$UV_CONFIG_FILE" ]; then
    cat "$UV_CONFIG_FILE" > "$UV_CONFIG_TMP"
  fi
  {
    echo ""
    echo "[[index]]"
    echo "name = \"${FEED}\""
    echo "url = \"${AUTHED_INDEX_URL}\""
  } >> "$UV_CONFIG_TMP"
  chmod 600 "$UV_CONFIG_TMP"
  mv "$UV_CONFIG_TMP" "$UV_CONFIG_FILE"
  trap - EXIT
  ok "Índice '${FEED}' agregado a ~/.config/uv/uv.toml (permisos 600 — solo tú puedes leerlo)"
fi

# ─── 4) Instala `maia` como tool global ──────────────────────────────────────
# Sin --index aquí a propósito: el PAT NUNCA va como argumento de línea de comandos (ver nota
# de seguridad arriba). uv ya descubre el índice recién declarado en ~/.config/uv/uv.toml.
echo
echo "  Instalando ${PACKAGE} desde el feed..."
uv tool install "$PACKAGE" --force

echo
ok "Listo — \`maia --version\` debería funcionar en cualquier repositorio, sin clonar este."
echo "  Actualizar después:  uv tool upgrade ${PACKAGE}"
echo "  Próximo paso:        maia install   (integra MAIA en tu cliente de IA)"
