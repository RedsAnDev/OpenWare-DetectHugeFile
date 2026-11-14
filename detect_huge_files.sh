#!/bin/bash
# DetectHugeFile — Copyright (C) 2026 Andrea Rossi
# Software libero: GNU General Public License v3 o successiva.
# Questo programma è distribuito SENZA ALCUNA GARANZIA. Vedi LICENSE e <https://www.gnu.org/licenses/>.
# detect_huge_files.sh — elenca (SOLO LETTURA, non cancella nulla) i file/cartelle
# giganti su macOS che di solito si possono eliminare per recuperare spazio.
#
# Uso:
#   ./detect_huge_files.sh [-p PATH] [-s MIN_MB] [-n TOP] [-o REPORT.txt] [-a]
#
#   -p PATH     radice della scansione file giganti (default: $HOME)
#   -s MIN_MB   soglia minima in MB per i file singoli (default: 500)
#   -n TOP      quanti file mostrare al massimo (default: 100)
#   -o FILE     salva anche il report su file
#   -a          scansione completa del disco (/) — richiede sudo e Full Disk Access
#
# Suggerimento: per vedere anche le cartelle protette, dai "Accesso completo al disco"
# al Terminale (Impostazioni di Sistema > Privacy e sicurezza).

set -u

ROOT="$HOME"
MIN_MB=500
TOP=100
OUT=""
ALL=0

while getopts "p:s:n:o:ah" opt; do
  case "$opt" in
    p) ROOT="$OPTARG" ;;
    s) MIN_MB="$OPTARG" ;;
    n) TOP="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    a) ALL=1; ROOT="/" ;;
    h|*) sed -n '2,15p' "$0"; exit 0 ;;
  esac
done

if [ "$(uname)" != "Darwin" ]; then
  echo "Questo script è pensato per macOS." >&2
  exit 1
fi

# Tee verso file se richiesto
if [ -n "$OUT" ]; then
  exec > >(tee "$OUT") 2>&1
fi

human() { # byte -> leggibile
  awk -v b="$1" 'BEGIN{
    split("B KB MB GB TB",u," "); i=1;
    while (b>=1024 && i<5) { b/=1024; i++ }
    printf "%.1f %s", b, u[i] }'
}

hr()  { printf '%*s\n' 78 '' | tr ' ' '-'; }
sec() { echo; hr; echo "## $1"; hr; }

free_before=$(df -k / | awk 'NR==2{print $4*1024}')
echo "Spazio libero attuale: $(human "$free_before")"
echo "Radice scansione: $ROOT   |   soglia: ${MIN_MB} MB   |   top: $TOP"

###############################################################################
# 1. Posizioni note, di norma sicure da svuotare (cache, build, backup vecchi)
###############################################################################
sec "1) Cartelle tipicamente recuperabili (dimensione)"

KNOWN=(
  "$HOME/.Trash|Cestino"
  "$HOME/Library/Caches|Cache utente"
  "$HOME/Library/Logs|Log utente"
  "$HOME/Library/Developer/Xcode/DerivedData|Xcode DerivedData"
  "$HOME/Library/Developer/Xcode/Archives|Xcode Archives"
  "$HOME/Library/Developer/Xcode/iOS DeviceSupport|Xcode iOS DeviceSupport"
  "$HOME/Library/Developer/Xcode/watchOS DeviceSupport|Xcode watchOS DeviceSupport"
  "$HOME/Library/Developer/CoreSimulator|Simulatori iOS"
  "$HOME/Library/Developer/XCPm|Xcode Previews"
  "$HOME/Library/Application Support/MobileSync/Backup|Backup iPhone/iPad"
  "$HOME/Library/Mail Downloads|Allegati Mail scaricati"
  "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads|Allegati Mail (sandbox)"
  "$HOME/Library/Application Support/Code/CachedData|VS Code cache"
  "$HOME/Library/Application Support/Slack/Cache|Slack cache"
  "$HOME/Library/Group Containers/group.com.apple.AppleSpell|Dizionari"
  "$HOME/Library/Containers/com.docker.docker/Data|Docker Desktop (immagini/volumi)"
  "$HOME/.docker|Docker config/cache"
  "$HOME/.npm|npm cache"
  "$HOME/.yarn/cache|Yarn cache"
  "$HOME/Library/Caches/Yarn|Yarn cache"
  "$HOME/.pnpm-store|pnpm store"
  "$HOME/.cache|~/.cache (pip, huggingface, ecc.)"
  "$HOME/.cache/huggingface|Modelli HuggingFace"
  "$HOME/.ollama/models|Modelli Ollama"
  "$HOME/.gradle/caches|Gradle cache"
  "$HOME/.m2/repository|Maven repository"
  "$HOME/.cargo/registry|Cargo registry"
  "$HOME/.rustup/toolchains|Toolchain Rust"
  "$HOME/.gem|Gem Ruby"
  "$HOME/.cocoapods|CocoaPods"
  "$HOME/.android|Android (AVD/cache)"
  "$HOME/Library/Android/sdk|Android SDK"
  "$HOME/go/pkg/mod|Go modules"
  "$HOME/.conda|Conda"
  "$HOME/miniconda3/pkgs|Conda pkgs"
  "$HOME/anaconda3/pkgs|Anaconda pkgs"
  "$HOME/.local/share/virtualenvs|Pipenv venv"
  "$HOME/Downloads|Download"
  "$HOME/Movies|Film"
  "$HOME/Library/Application Support/Steam|Steam"
  "/Library/Caches|Cache di sistema"
  "/Library/Updates|Aggiornamenti scaricati"
  "/private/var/log|Log di sistema"
  "/Library/Logs/DiagnosticReports|Crash report"
  "$HOME/Library/Logs/DiagnosticReports|Crash report utente"
)

tmp_known=$(mktemp)
for entry in "${KNOWN[@]}"; do
  p="${entry%%|*}"; label="${entry#*|}"
  [ -e "$p" ] || continue
  kb=$(du -sk "$p" 2>/dev/null | awk '{print $1}')
  [ -n "$kb" ] && [ "$kb" -gt 10240 ] && printf '%s\t%s\t%s\n' "$((kb*1024))" "$label" "$p" >> "$tmp_known"
done
if [ -s "$tmp_known" ]; then
  sort -rn "$tmp_known" | while IFS=$'\t' read -r b label p; do
    printf '%10s  %-34s %s\n' "$(human "$b")" "$label" "$p"
  done
else
  echo "(nessuna cartella > 10 MB trovata, oppure permessi mancanti)"
fi
rm -f "$tmp_known"

###############################################################################
# 2. Snapshot locali Time Machine e Homebrew / Docker (via comandi)
###############################################################################
sec "2) Snapshot Time Machine locali"
if command -v tmutil >/dev/null 2>&1; then
  snaps=$(tmutil listlocalsnapshots / 2>/dev/null)
  if [ -n "$snaps" ]; then
    echo "$snaps"
    echo "→ Per rimuoverli:  sudo tmutil deletelocalsnapshots <data>"
  else
    echo "(nessuno)"
  fi
fi

sec "3) Homebrew"
if command -v brew >/dev/null 2>&1; then
  c=$(brew --cache 2>/dev/null)
  [ -d "$c" ] && printf '%10s  cache brew: %s\n' "$(human $(( $(du -sk "$c" | awk '{print $1}') * 1024 )))" "$c"
  echo "→ Per pulire:  brew cleanup -s --prune=all"
else
  echo "(brew non installato)"
fi

sec "4) Docker"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker system df
  echo "→ Per pulire:  docker system prune -a --volumes   (attenzione: rimuove tutto ciò che non è in uso)"
else
  echo "(docker non installato o non in esecuzione)"
fi

###############################################################################
# 5. Directory rigenerabili (node_modules, venv, build, target, Pods...)
###############################################################################
sec "5) Cartelle rigenerabili di progetto (node_modules, .venv, target, build, Pods, ...)"
tmp_dirs=$(mktemp)
find "$ROOT" -xdev \
  \( -path "$HOME/Library" -o -path "$HOME/.Trash" -o -path "/System" -o -path "/Volumes" \) -prune -o \
  -type d \( -name node_modules -o -name .venv -o -name venv -o -name __pycache__ \
             -o -name target -o -name Pods -o -name .gradle -o -name build \
             -o -name dist -o -name .next -o -name .nuxt -o -name .terraform \
             -o -name .tox -o -name DerivedData \) \
  -prune -print 2>/dev/null |
while IFS= read -r d; do
  # target/build/dist: considera solo se ha un manifest "fratello" per ridurre i falsi positivi
  case "$(basename "$d")" in
    target)  [ -f "$(dirname "$d")/Cargo.toml" ] || [ -f "$(dirname "$d")/pom.xml" ] || continue ;;
    build)   [ -f "$(dirname "$d")/package.json" ] || [ -f "$(dirname "$d")/build.gradle" ] || \
             [ -f "$(dirname "$d")/CMakeLists.txt" ] || [ -f "$(dirname "$d")/setup.py" ] || continue ;;
    dist)    [ -f "$(dirname "$d")/package.json" ] || [ -f "$(dirname "$d")/pyproject.toml" ] || continue ;;
  esac
  kb=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
  [ -n "$kb" ] && [ "$kb" -gt 102400 ] && printf '%s\t%s\n' "$((kb*1024))" "$d"
done > "$tmp_dirs"
if [ -s "$tmp_dirs" ]; then
  sort -rn "$tmp_dirs" | head -n 50 | while IFS=$'\t' read -r b d; do
    printf '%10s  %s\n' "$(human "$b")" "$d"
  done
else
  echo "(nessuna > 100 MB)"
fi
rm -f "$tmp_dirs"

###############################################################################
# 6. File singoli giganti
###############################################################################
sec "6) File più grandi (> ${MIN_MB} MB) sotto $ROOT"
echo "(la scansione può richiedere alcuni minuti…)"
tmp_files=$(mktemp)
find "$ROOT" -xdev \
  \( -path /System -o -path /Volumes -o -path /private/var/vm -o -path "*/.Trash/.*" \
     -o -path "$HOME/Library/CloudStorage" -o -path "$HOME/Library/Mobile Documents" \) -prune -o \
  -type f -size +"${MIN_MB}"M -print0 2>/dev/null |
  xargs -0 stat -f '%z%t%Sm%t%N' -t '%Y-%m-%d' 2>/dev/null > "$tmp_files"

if [ -s "$tmp_files" ]; then
  sort -rn "$tmp_files" | head -n "$TOP" | while IFS=$'\t' read -r b date path; do
    ext="${path##*.}"; hint=""
    case "$(echo "$ext" | tr '[:upper:]' '[:lower:]')" in
      dmg|pkg|iso|ipsw)       hint="[installer/immagine — spesso cancellabile]" ;;
      zip|tar|gz|tgz|7z|rar|xz|bz2) hint="[archivio — verifica se già estratto]" ;;
      mov|mp4|mkv|avi|m4v)    hint="[video]" ;;
      vmdk|vdi|qcow2|vhdx|hdd|pvm|utm) hint="[disco macchina virtuale]" ;;
      log|crash|ips|hprof|dmp) hint="[log/dump — cancellabile]" ;;
      gguf|safetensors|ckpt|bin|pt|onnx) hint="[modello ML]" ;;
      sqlite|db)              hint="[database — attenzione]" ;;
    esac
    printf '%10s  %s  %s %s\n' "$(human "$b")" "$date" "$path" "$hint"
  done
  total=$(awk -F'\t' '{s+=$1} END{print s+0}' "$tmp_files")
  echo
  echo "File trovati: $(wc -l < "$tmp_files" | tr -d ' ')   |   totale: $(human "$total")"
else
  echo "(nessun file sopra soglia, o permessi insufficienti)"
fi
rm -f "$tmp_files"

###############################################################################
# 7. Installer / immagini disco in Download e Applicazioni
###############################################################################
sec "7) Installer e archivi in ~/Downloads e /Applications (> 50 MB)"
find "$HOME/Downloads" /Applications -maxdepth 2 \
  \( -iname '*.dmg' -o -iname '*.pkg' -o -iname '*.iso' -o -iname '*.zip' -o -iname 'Install macOS*' \) \
  -size +50M -print0 2>/dev/null |
  xargs -0 stat -f '%z%t%N' 2>/dev/null | sort -rn | head -n 30 |
  while IFS=$'\t' read -r b p; do printf '%10s  %s\n' "$(human "$b")" "$p"; done

echo
hr
echo "Fatto. Nessun file è stato modificato o cancellato."
echo "Controlla sempre il contenuto prima di eliminare; usa il Cestino (non rm) quando possibile."
