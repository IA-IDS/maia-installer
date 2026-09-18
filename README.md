# maia-installer

Instalador global de [`maia`](https://dev.azure.com/erikramosids/maia-for-developers) (MAIA SDLC) —
distribuido como paquete privado en un feed de Azure Artifacts. Este repo solo contiene los scripts
de instalación (sin código fuente de MAIA), para poder publicarse públicamente sin exponer el
producto.

## Instalar

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/IA-IDS/maia-installer/main/install.sh | bash
```

**Windows (PowerShell):**

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://raw.githubusercontent.com/IA-IDS/maia-installer/main/install.ps1 | iex"
```

El script te pedirá un Personal Access Token (scope `Packaging → Read`) la primera vez — instrucciones
en pantalla. Después de instalar, `maia --version` funciona en cualquier repositorio, sin necesidad de
clonar el código fuente de MAIA.

## Actualizar

```bash
uv tool upgrade maia-sdlc
```

## Fuente

El código fuente de `install.sh`/`install.ps1` vive en el repo principal de MAIA (privado); este repo
es solo un espejo público de esos dos archivos para poder servir el `curl | bash`. Ver
`docs/v2/PUBLISHING.md` en el repo principal para el contexto completo de publicación.
