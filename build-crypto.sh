#!/usr/bin/env bash
set -e

# ---------------------------------------------------------
# Configuration (Adjust these if your GitHub URLs change)
# ---------------------------------------------------------
WASM_REPO="https://github.com/thomas666-beast/cipherbox-pqc-wasm.git"
NATIVE_REPO="https://github.com/thomas666-beast/cipherbox-pqc-native.git"

# Where to download and build the Rust projects (outside the Perl project)
BUILD_DIR="../cipherbox-crypto-build"

# Paths inside the Perl project
FRONTEND_DIR="./frontend"       # <-- Change this if your Vue folder is named differently
VUE_PQC_DIR="$FRONTEND_DIR/src/pqc"
PERL_BIN_DIR="./bin"

echo "🚀 Starting Post-Quantum Crypto build..."

# 1. Create a clean build directory outside the Perl project
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# 2. Clone the WASM project (if it doesn't exist)
if [ ! -d "cipherbox-pqc-wasm" ]; then
    echo "📥 Cloning WASM repository..."
    git clone "$WASM_REPO"
else
    echo "🔄 Updating WASM repository..."
    cd cipherbox-pqc-wasm && git pull && cd ..
fi

# 3. Clone the Native project (if it doesn't exist)
if [ ! -d "cipherbox-pqc-native" ]; then
    echo "📥 Cloning Native repository..."
    git clone "$NATIVE_REPO"
else
    echo "🔄 Updating Native repository..."
    cd cipherbox-pqc-native && git pull && cd ..
fi

# 4. Build the WASM module
echo "📦 Building WASM for Vue..."
cd cipherbox-pqc-wasm
# Ensure wasm-pack is installed
if ! command -v wasm-pack &> /dev/null; then
    echo "⚠️ wasm-pack not found. Installing..."
    curl https://rustwasm.github.io/wasm-pack/installer/init.sh -sSf | sh
fi
wasm-pack build --target web --out-dir "../../cipherbox/$VUE_PQC_DIR"
cd ..

# 5. Build the Native binaries
echo "🦀 Building Native binaries for Perl..."
cd cipherbox-pqc-native
cargo build --release

# 6. Copy the binaries to the Perl project
echo "🚚 Copying binaries to Perl project..."
mkdir -p "../../cipherbox/$PERL_BIN_DIR"
cp target/release/cipherbox-pqc-verify "../../cipherbox/$PERL_BIN_DIR/"
cp target/release/cipherbox-pqc-wrap   "../../cipherbox/$PERL_BIN_DIR/"
cd ..

echo "🎉 Build complete!"
echo "✅ WASM files copied to $VUE_PQC_DIR"
echo "✅ Native binaries copied to $PERL_BIN_DIR"
