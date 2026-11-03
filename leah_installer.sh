#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# LEAH.OS v5.0 - SAFE CORE INSTALLER
# Raspberry Pi 3 / 32-bit Raspbian Stretch compatible
# No package installation, OS upgrades or model downloads.
# ============================================================

VERSION="5.0"

LEAH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DATA_DIR="$LEAH_DIR/data"
ASSET_DIR="$LEAH_DIR/assets"
MODEL_DIR="$LEAH_DIR/models"
VOICE_DIR="$LEAH_DIR/voices"

ASSISTANT="$LEAH_DIR/assistant.py"
AVATAR="$ASSET_DIR/leah_avatar.png"
LAUNCHER="$LEAH_DIR/run_leah.sh"

echo "================================================"
echo "       LEAH.OS // CORE INSTALLER v$VERSION"
echo "================================================"

echo
echo "[*] Detecting system..."

ARCH="$(uname -m)"
BITS="$(getconf LONG_BIT)"
echo "[+] Architecture: $ARCH"
echo "[+] System: $BITS-bit"

if ! command -v python3 >/dev/null 2>&1; then
    echo "[ERROR] Python 3 is not installed."
    exit 1
fi

PYTHON_VERSION="$(python3 --version 2>&1)"
echo "[+] Python: $PYTHON_VERSION"

if [ ! -f "$ASSISTANT" ]; then
    echo "[ERROR] assistant.py not found."
    exit 1
fi

echo "[+] assistant.py found."

echo
echo "[*] Creating project directories..."

mkdir -p "$DATA_DIR" "$ASSET_DIR" "$MODEL_DIR" "$VOICE_DIR"

echo "[+] Directories ready."

echo
echo "[*] Checking avatar..."

if [ -f "$AVATAR" ]; then
    echo "[+] Avatar found: assets/leah_avatar.png"
else
    echo "[WARNING] Avatar not found: assets/leah_avatar.png"
    echo "[WARNING] LEAH will continue without the avatar."
fi

echo
echo "[*] Checking Python syntax..."

if ! python3 -m py_compile "$ASSISTANT"; then
    echo "[ERROR] Python syntax check failed."
    exit 1
fi

echo "[+] Python syntax check passed."

echo
echo "[*] Checking optional Pillow support..."

if python3 -c "from PIL import Image" >/dev/null 2>&1; then
    echo "[+] Pillow is available."
else
    echo "[INFO] Pillow is not installed."
    echo "[INFO] No installation attempted."
fi

echo
echo "[*] Creating launcher..."

cat > "$LAUNCHER" <<'LAUNCHER_EOF'
#!/usr/bin/env bash

set -e

LEAH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$LEAH_DIR"

exec python3 assistant.py
LAUNCHER_EOF

chmod +x "$LAUNCHER"
chmod 700 "$DATA_DIR"

echo "[+] Launcher created."

echo
echo "================================================"
echo "       LEAH.OS // INSTALLATION COMPLETE"
echo "================================================"

echo "[+] Installer version: $VERSION"
echo "[+] Architecture: $ARCH ($BITS-bit)"
echo "[+] Python: $PYTHON_VERSION"
echo "[+] Assistant: Ready"
echo "[+] Data: $DATA_DIR"
echo "[+] Assets: $ASSET_DIR"
echo "[+] Models: $MODEL_DIR"
echo "[+] Voices: $VOICE_DIR"
echo "[+] Launcher: $LAUNCHER"

echo
echo "To launch LEAH:"
echo "  $LAUNCHER"

echo
echo "No packages were installed."
echo "No operating-system changes were made."
echo "No models or user data were deleted."
echo "================================================"
