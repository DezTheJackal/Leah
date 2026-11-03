
#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# LEAH.OS // LOCAL LLM AUTO-COMPILER
# Raspberry Pi / ARMv7 / 32-Bit Linux
# ============================================================

VERSION="1.1"

LEAH_DIR="$HOME/Leah"
LLAMA_DIR="$HOME/llama.cpp"
BUILD_DIR="$LLAMA_DIR/build"
MODEL_DIR="$LEAH_DIR/models"

MODEL_NAME="qwen2.5-0.5b-instruct-q4_k_m.gguf"

MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/$MODEL_NAME"

MODEL_PATH="$MODEL_DIR/$MODEL_NAME"

LLAMA_BINARY="$BUILD_DIR/bin/llama-cli"

# Default to one job to conserve Raspberry Pi RAM.
JOBS="${LEAH_BUILD_JOBS:-1}"

# ============================================================
# ERROR HANDLING
# ============================================================

error_exit() {
    echo
    echo "[ERROR] $1"
    echo "[ERROR] Installation aborted."
    exit 1
}

trap 'error_exit "Command failed on line $LINENO."' ERR

# ============================================================
# STARTUP
# ============================================================

clear || true

echo "=========================================================="
echo " LEAH.OS // LOCAL LLM AUTO-COMPILER v$VERSION"
echo "=========================================================="

echo "[*] Detecting hardware..."

ARCH=$(uname -m)
BITS=$(getconf LONG_BIT)

echo "[+] Architecture: $ARCH"
echo "[+] Operating system: $BITS-bit"

if [[ "$BITS" != "32" ]]; then
    echo "[WARNING] This installer was configured for 32-bit Linux."
fi

if [[ "$ARCH" != "armv7l" && "$ARCH" != "armv6l" ]]; then
    echo "[WARNING] Architecture differs from expected ARMv7."
fi

if [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    error_exit "LEAH_BUILD_JOBS must be a positive integer."
fi

echo "[+] Compilation jobs: $JOBS"

# ============================================================
# INSTALL DEPENDENCIES
# ============================================================

echo
echo "[*] Installing build dependencies..."

sudo apt-get update

sudo apt-get install -y \
    build-essential \
    cmake \
    git \
    curl \
    wget \
    pkg-config

# ============================================================
# CREATE LEAH DIRECTORIES
# ============================================================

echo
echo "[*] Preparing LEAH directories..."

mkdir -p "$LEAH_DIR"
mkdir -p "$MODEL_DIR"

# ============================================================
# CLONE OR UPDATE LLAMA.CPP
# ============================================================

echo
echo "[*] Preparing llama.cpp..."

if [[ ! -d "$LLAMA_DIR/.git" ]]; then

    if [[ -e "$LLAMA_DIR" ]]; then
        error_exit "$LLAMA_DIR exists but is not a Git repository."
    fi

    echo "[*] Cloning llama.cpp..."

    git clone \
        --depth 1 \
        https://github.com/ggml-org/llama.cpp.git \
        "$LLAMA_DIR"

else

    echo "[*] Existing llama.cpp repository detected."

    cd "$LLAMA_DIR"

    echo "[*] Updating repository..."

    git pull --ff-only

fi

# ============================================================
# CONFIGURE CMAKE
# ============================================================

echo
echo "[*] Configuring ARM-compatible build..."

cmake \
    -S "$LLAMA_DIR" \
    -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=OFF

# ============================================================
# COMPILE LLAMA.CPP
# ============================================================

echo
echo "=========================================================="
echo "[*] COMPILING LLAMA.CPP"
echo "[*] This may take a while on Raspberry Pi."
echo "=========================================================="

cmake \
    --build "$BUILD_DIR" \
    --target llama-cli \
    --config Release \
    --parallel "$JOBS"

# ============================================================
# VERIFY EXECUTABLE
# ============================================================

echo
echo "[*] Verifying llama-cli..."

if [[ ! -x "$LLAMA_BINARY" ]]; then
    error_exit "llama-cli executable was not generated."
fi

"$LLAMA_BINARY" --version

# ============================================================
# DOWNLOAD QUANTIZED MODEL
# ============================================================

echo
echo "[*] Checking Qwen2.5 0.5B model..."

if [[ -f "$MODEL_PATH" ]]; then

    echo "[+] Existing model detected."

else

    echo "[*] Downloading Qwen2.5 0.5B Instruct Q4_K_M..."

    TEMP_MODEL="${MODEL_PATH}.part"

    rm -f "$TEMP_MODEL"

    curl \
        --fail \
        --location \
        --retry 3 \
        --retry-all-errors \
        --connect-timeout 20 \
        --progress-bar \
        "$MODEL_URL" \
        --output "$TEMP_MODEL"

    # Check minimum file size.
    FILE_SIZE=$(stat -c%s "$TEMP_MODEL")

    if [[ "$FILE_SIZE" -lt 10000000 ]]; then
        rm -f "$TEMP_MODEL"
        error_exit "Downloaded model is suspiciously small."
    fi

    # Verify GGUF file signature.
    MAGIC=$(od -An -t x1 -N4 "$TEMP_MODEL" | tr -d ' \n')

    if [[ "$MAGIC" != "47475546" ]]; then
        rm -f "$TEMP_MODEL"
        error_exit "Invalid GGUF model file signature."
    fi

    mv "$TEMP_MODEL" "$MODEL_PATH"

    echo "[+] Model download verified."

fi

# ============================================================
# FINAL INSTALLATION CHECK
# ============================================================

echo
echo "=========================================================="
echo " LEAH.OS // INSTALLATION COMPLETE"
echo "=========================================================="

echo "[+] Architecture: $ARCH ($BITS-bit)"
echo "[+] Compiler: CMake / GCC"
echo "[+] Backend: llama.cpp"
echo "[+] Model: Qwen2.5 0.5B Instruct"
echo "[+] Quantization: Q4_K_M"

echo
echo "[+] Executable:"
echo "$LLAMA_BINARY"

echo
echo "[+] Model:"
echo "$MODEL_PATH"

echo
echo "=========================================================="
echo " LEAH.OS // READY FOR INFERENCE"
echo "=========================================================="

echo
echo "[*] To launch Leah's local AI engine, run:"

echo
echo "\"$LLAMA_BINARY\" \\"
echo "  -m \"$MODEL_PATH\" \\"
echo "  -cnv \\"
echo "  -c 1024 \\"
echo "  -n 256"

echo
echo "[*] Installation finished."
