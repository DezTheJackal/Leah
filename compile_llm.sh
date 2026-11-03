#!/bin/bash
set -e

echo "=========================================================="
echo "LEAH.OS // LOCAL LLM AUTO-COMPILER (32-Bit ARMv7)"
echo "=========================================================="

# 1. Install build tools and dependencies
echo "[*] Checking & installing build dependencies..."
sudo apt update && sudo apt install -y build-essential cmake git curl wget

# 2. Clone llama.cpp if not present
if [ ! -d "$HOME/llama.cpp" ]; then
    echo "[*] Cloning llama.cpp repository..."
    cd ~
    git clone https://github.com/ggerganov/llama.cpp.git
else
    echo "[*] llama.cpp repository already exists. Skipping clone."
fi

# 3. Compile llama.cpp
echo "[*] Configuring and compiling llama.cpp (this may take a few minutes)..."
cd ~/llama.cpp
mkdir -p build && cd build
cmake .. -DGGML_OPENMP=OFF
cmake --build . --config Release -- -j2

# 4. Download a tiny lightweight model (Qwen2.5 0.5B Instruct Quantized)
MODEL_DIR="$HOME/Leah/models"
mkdir -p "$MODEL_DIR"
MODEL_PATH="$MODEL_DIR/qwen2.5-0.5b-instruct-q4_k_m.gguf"

if [ ! -f "$MODEL_PATH" ]; then
    echo "[*] Downloading Qwen2.5-0.5B-Instruct GGUF model..."
    curl -L -o "$MODEL_PATH" "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"
else
    echo "[*] Model already downloaded."
fi

echo "=========================================================="
echo "[+] COMPILATION & MODEL ACQUISITION COMPLETE!"
echo "[+] Binary located at: ~/llama.cpp/build/bin/llama-cli"
echo "[+] Model located at:  $MODEL_PATH"
echo "=========================================================="
