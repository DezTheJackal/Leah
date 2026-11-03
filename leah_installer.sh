#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# LEAH.OS v2.0
# Raspberry Pi 3 Model B / Raspbian Stretch
# Core Assistant Installer
# ============================================================

VERSION="2.0"

LEAH_DIR="$HOME/Leah"
DATA_DIR="$LEAH_DIR/data"
ASSET_DIR="$LEAH_DIR/assets"
MODEL_DIR="$LEAH_DIR/models"
VOICE_DIR="$LEAH_DIR/voices"

ASSISTANT="$LEAH_DIR/assistant.py"
LAUNCHER="$LEAH_DIR/run_leah.sh"

# ============================================================
# ERROR HANDLING
# ============================================================

error_exit() {
    echo
    echo "[ERROR] $1"
    exit 1
}

trap 'error_exit "Installation failed on line $LINENO."' ERR

# ============================================================
# STARTUP
# ============================================================

echo "================================================"
echo " LEAH.OS // CORE INSTALLER v$VERSION"
echo "================================================"

echo "[*] Detecting hardware..."

ARCH=$(uname -m)
BITS=$(getconf LONG_BIT)

echo "[+] Architecture: $ARCH"
echo "[+] System: $BITS-bit"

if ! command -v python3 >/dev/null 2>&1; then
    error_exit "Python 3 is not installed."
fi

PYTHON_VERSION=$(python3 --version)

echo "[+] Python: $PYTHON_VERSION"

# ============================================================
# DIRECTORY STRUCTURE
# ============================================================

echo
echo "[*] Creating LEAH directory structure..."

mkdir -p "$DATA_DIR"
mkdir -p "$ASSET_DIR"
mkdir -p "$MODEL_DIR"
mkdir -p "$VOICE_DIR"

# ============================================================
# CHECK ASSISTANT FILE
# ============================================================

if [[ ! -f "$ASSISTANT" ]]; then
    error_exit "assistant.py not found in $LEAH_DIR"
fi

echo "[+] assistant.py detected."

# ============================================================
# PYTHON SYNTAX CHECK
# ============================================================

echo
echo "[*] Checking Python syntax..."

python3 -m py_compile "$ASSISTANT"

echo "[+] Python syntax check passed."

# ============================================================
# OPTIONAL PILLOW CHECK
# ============================================================

echo
echo "[*] Checking optional Pillow dependency..."

if python3 -c "from PIL import Image" >/dev/null 2>&1; then
    echo "[+] Pillow available."
else
    echo "[WARNING] Pillow not detected."
    echo "[WARNING] Portrait rendering will need Pillow."
    echo "[WARNING] No package installation attempted."
fi

# ============================================================
# CREATE LAUNCHER
# ============================================================

echo
echo "[*] Creating LEAH launcher..."

cat > "$LAUNCHER" <<'EOF'
#!/usr/bin/env bash

set -e

LEAH_DIR="$HOME/Leah"

cd "$LEAH_DIR"

python3 assistant.py
EOF

chmod +x "$LAUNCHER"

# ============================================================
# PERMISSIONS
# ============================================================

chmod 700 "$DATA_DIR"

# ============================================================
# FINAL REPORT
# ============================================================

echo
echo "================================================"
echo " LEAH.OS // CORE INSTALLATION COMPLETE"
echo "================================================"

echo "[+] Architecture: $ARCH"
echo "[+] Python: $PYTHON_VERSION"
echo "[+] Core assistant: Installed"
echo "[+] Data directory: $DATA_DIR"
echo "[+] Assets directory: $ASSET_DIR"
echo "[+] Models directory: $MODEL_DIR"
echo "[+] Voices directory: $VOICE_DIR"
echo "[+] Launcher: $LAUNCHER"

echo
echo "To launch LEAH:"
echo
echo "  ~/Leah/run_leah.sh"

echo
echo "LLM installation has deliberately been postponed."
echo "No APT repositories were modified."
echo "No existing model files were deleted."

echo
echo "================================================"
echo " LEAH.OS // READY"
echo "================================================"
