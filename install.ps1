#Requires -Version 5.1
# MAIA — instalador global (sin clonar el repo), estilo Codex CLI / Claude Code. Windows PowerShell.
# Instala el comando `maia` via `uv tool install` desde el feed privado de Azure Artifacts.
# Ver docs/v2/PUBLISHING.md para el lado de publicacion. Equivalente Windows de install.sh.
#
# Uso:
#   powershell -ExecutionPolicy ByPass -c "irm https://raw.githubusercontent.com/IA-IDS/maia-installer/main/install.ps1 | iex"
#   $env:MAIA_ARTIFACTS_PAT = "<pat>"; .\install.ps1        # no interactivo (CI/scripted) —
#     PowerShell persiste el historial de comandos en disco (PSReadLine) por default: en una
#     sesion interactiva usa el prompt seguro (Read-Host -AsSecureString), no esta variante.
#
# Verificado contra doc oficial (no adivinado):
#   - Formato del feed: learn.microsoft.com "Publish and download Python packages with Azure Artifacts"
#   - Auth por indice de uv: docs.astral.sh/uv/concepts/indexes + reference/environment
#   - Ruta de config global de uv en Windows: docs.astral.sh/uv/concepts/configuration-files
#     (%APPDATA%\uv\uv.toml)
#
# Manejo del PAT (revision de seguridad, corregido): nunca se pasa como argumento de linea de
# comandos (visible en el Administrador de tareas/Get-Process a otros usuarios de la misma
# maquina) - solo vive en una variable y en el uv.toml, cuyo ACL se restringe al usuario actual
# justo despues de escribirlo.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Org     = "erikramosids"
$Project = "maia-for-developers"
$Feed    = "maia-sdlc"
$Package = "maia-sdlc"

function Write-Ok   { param([string]$Text) Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "  ->  $Text" -ForegroundColor Yellow }
function Write-Err  { param([string]$Text) Write-Host "  [X] $Text" -ForegroundColor Red }

Write-Host "MAIA - instalador global (feed: $Feed)" -ForegroundColor Cyan
Write-Host ""

# --- 1) uv (gestor de Python que ya usa este proyecto) ---------------------
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Warn "uv no esta instalado - instalandolo (astral.sh/uv, oficial)..."
    powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
    $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
}
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Err "uv se instalo pero no esta en el PATH de esta sesion - abre una terminal nueva y reintenta."
    exit 1
}
Write-Ok "uv disponible ($(uv --version))"

# --- 2) PAT del feed (scope: Packaging -> Read) -----------------------------
$Pat = $env:MAIA_ARTIFACTS_PAT
if ([string]::IsNullOrEmpty($Pat)) {
    Write-Host ""
    Write-Host "  El feed de MAIA es privado (Azure Artifacts) - necesitas un Personal Access Token."
    Write-Host "  Generalo en: https://dev.azure.com/$Org/_usersSettings/tokens"
    Write-Host "  Scope requerido: Packaging -> Read"
    Write-Host ""
    $SecurePat = Read-Host "  Pega tu PAT" -AsSecureString
    $Pat = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePat))
}
if ([string]::IsNullOrEmpty($Pat)) {
    Write-Err "Sin PAT no se puede autenticar contra el feed privado."
    exit 1
}

# --- 3) Configura el indice, con credenciales embebidas (patron oficial de uv) -
$UvConfigDir  = Join-Path $env:APPDATA "uv"
$UvConfigFile = Join-Path $UvConfigDir "uv.toml"
New-Item -ItemType Directory -Path $UvConfigDir -Force | Out-Null
$AuthedIndexUrl = "https://pat:$Pat@pkgs.dev.azure.com/$Org/$Project/_packaging/$Feed/pypi/simple/"

function Protect-UvConfigFile {
    param([string]$Path)
    icacls $Path /inheritance:r /grant:r "${env:USERNAME}:F" | Out-Null
}

# Refuerza el ACL SIEMPRE, no solo cuando reescribimos - un uv.toml dejado con permisos
# heredados por una corrida anterior (o por otra herramienta) debe corregirse en cada
# ejecucion, no solo la primera vez que este script escribe el indice.
if (Test-Path $UvConfigFile) {
    Protect-UvConfigFile -Path $UvConfigFile
}

# Si ya existe una entrada para este feed (de una corrida anterior), la REEMPLAZA con el PAT que
# el usuario acaba de dar, en vez de descartarlo en silencio. Bug real reproducido: un usuario
# volvio a correr el instalador con un PAT nuevo porque el primero habia vencido/se pego mal; el
# script detectaba "ya configurado", NUNCA escribia el PAT recien pegado, y seguia usando el
# viejo - la instalacion fallaba con 401 (index no se pudo consultar) y parecia un problema del
# PAT nuevo cuando en realidad nunca se uso. Pegar un PAT es una senal explicita de "quiero
# (re)configurar esto", no algo para ignorar. Remove-UvIndexBlock quita SOLO el bloque
# `[[index]]` de este feed (por nombre), preservando cualquier otro indice configurado.
function Remove-UvIndexBlock {
    param([string]$Path, [string]$FeedName)
    if (-not (Test-Path $Path)) { return "" }
    $raw = Get-Content -Path $Path -Raw
    if ([string]::IsNullOrEmpty($raw)) { return "" }
    $allLines = $raw -split "\r?\n"
    $output = New-Object System.Collections.Generic.List[string]
    $block = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    $matchFeed = $false
    foreach ($line in $allLines) {
        if ($line -eq "[[index]]") {
            if ($inBlock -and -not $matchFeed) { $output.AddRange($block) }
            $block = New-Object System.Collections.Generic.List[string]
            $block.Add($line)
            $inBlock = $true
            $matchFeed = $false
            continue
        }
        if ($inBlock) {
            $block.Add($line)
            if ($line -eq "name = `"$FeedName`"") { $matchFeed = $true }
            continue
        }
        $output.Add($line)
    }
    if ($inBlock -and -not $matchFeed) { $output.AddRange($block) }
    return ($output -join "`n")
}

$CleanedContent = Remove-UvIndexBlock -Path $UvConfigFile -FeedName $Feed

# Escribe en un archivo temporal, restringe su ACL ANTES de escribir el PAT, y recien
# entonces lo mueve encima del destino - asi el PAT nunca queda, ni un instante, en un
# archivo con el ACL heredado/abierto (evita la carrera "escribir el secreto primero,
# restringir permisos despues" que tenia la version anterior).
$TmpFile = Join-Path $UvConfigDir ("uv.toml." + [System.IO.Path]::GetRandomFileName())
try {
    New-Item -ItemType File -Path $TmpFile -Force | Out-Null
    Protect-UvConfigFile -Path $TmpFile
    if ($CleanedContent) {
        Set-Content -Path $TmpFile -Value $CleanedContent -NoNewline
    }
    Add-Content -Path $TmpFile -Value "`n[[index]]`nname = `"$Feed`"`nurl = `"$AuthedIndexUrl`""
    Move-Item -Path $TmpFile -Destination $UvConfigFile -Force
} finally {
    if (Test-Path $TmpFile) { Remove-Item -Path $TmpFile -Force }
}
# Move-Item no garantiza preservar el ACL del origen en todos los casos - reafirma en el
# destino final, defensivo.
Protect-UvConfigFile -Path $UvConfigFile
Write-Ok "Indice '$Feed' escrito en $UvConfigFile con el PAT actual (ACL restringido a $env:USERNAME)"

# --- 4) Instala `maia` como tool global -------------------------------------
# Sin --index aqui a proposito: el PAT NUNCA va como argumento de linea de comandos (ver nota
# de seguridad arriba). uv ya descubre el indice recien declarado en el uv.toml global.
Write-Host ""
Write-Host "  Instalando $Package desde el feed..."
uv tool install $Package --force

Write-Host ""
Write-Ok "Listo - 'maia --version' deberia funcionar en cualquier repositorio, sin clonar este."
Write-Host "  Actualizar despues:  uv tool upgrade $Package"
Write-Host "  Proximo paso:        maia install   (integra MAIA en tu cliente de IA)"
