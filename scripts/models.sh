#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_DIR="$ROOT_DIR/UnrambleApp/Resources/models"
MODEL_WORK="$ROOT_DIR/UnrambleApp/.model-work"
MODEL_VENV="$MODEL_WORK/venv"
MODEL_PYTHON="$MODEL_VENV/bin/python3"
MODEL_HF="$MODEL_VENV/bin/hf"
ADAPTER_SOURCE="$ROOT_DIR/UnrambleApp/ModelSources/qwen3-0.6b-4bit-list-adapter"
ADAPTER_NAME="qwen3-0.6b-4bit-list-adapter"
COHERE_NAME="cohere-transcribe-03-2026-mlx-4bit"
QWEN_NAME="qwen3-0.6b-4bit"
COHERE_REPO="beshkenadze/cohere-transcribe-03-2026-mlx-4bit"
COHERE_REV="104bc4391b5b1a12b040859793d7148525e1a08c"
QWEN_REPO="mrinalwadhwa/Qwen3-0.6B-4bit"
QWEN_REV="44c9f61dea041165b988662ba914dbfef0e0d096"
COHERE_FILES=(
    config.json
    conversion_summary.json
    key_map.json
    model.safetensors
    preprocessor_config.json
    special_tokens_map.json
    tokenizer.model
    tokenizer_config.json
)
QWEN_FILES=(
    added_tokens.json
    config.json
    merges.txt
    model.safetensors
    model.safetensors.index.json
    special_tokens_map.json
    tokenizer.json
    tokenizer_config.json
    vocab.json
)
KOKORO_NAME="kokoro-82m-bf16"
KOKORO_REPO="mlx-community/Kokoro-82M-bf16"
KOKORO_REV="a71e4d38b236d968966a2002c4c895dbd12b1c3c"
KOKORO_FILES=(
    config.json
    kokoro-v1_0.safetensors
    voices/af_heart.safetensors
)
KOKORO_G2P_NAME="kokoro-g2p-en"
KOKORO_G2P_REPO="beshkenadze/kitten-tts-g2p"
KOKORO_G2P_REV="9c692b92682d959d9013a9cfe6a49541997add18"
KOKORO_G2P_FILES=(
    us_bart.safetensors
    us_bart_config.json
    us_gold.json
    us_silver.json
)

checksums() {
    cat <<'EOF'
c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680  qwen3-0.6b-4bit/added_tokens.json
15d3ac26c043ae477273ed5802ee0f0b33bb14f18c9d3dd70910c02d906e3f1f  qwen3-0.6b-4bit/config.json
8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5  qwen3-0.6b-4bit/merges.txt
392e8d466d56100ada00eb82031fb854297fc9e389b7d303eba3af114e87bce2  qwen3-0.6b-4bit/model.safetensors
7b294141456f6904936db03c00bca50fb5f6198f652fe8483f9cd2a1018accfb  qwen3-0.6b-4bit/model.safetensors.index.json
76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd  qwen3-0.6b-4bit/special_tokens_map.json
aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4  qwen3-0.6b-4bit/tokenizer.json
253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0  qwen3-0.6b-4bit/tokenizer_config.json
ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910  qwen3-0.6b-4bit/vocab.json
f5f4e46ea8a74e4e868d08504cb212afca7abfe55cd900d9b677bb2f9a1c210b  cohere-transcribe-03-2026-mlx-4bit/config.json
f3f763b9ff233b194df209277ab670d7768745f92eab0efb52b769991743b159  cohere-transcribe-03-2026-mlx-4bit/conversion_summary.json
42cf585ab25335db650b353abcaa9d219d51a04ef04eae5869de6122e85a7be8  cohere-transcribe-03-2026-mlx-4bit/key_map.json
5284ab5b678da720da092604323c7ce82cffe544e42b2da95064fbc85e281609  cohere-transcribe-03-2026-mlx-4bit/model.safetensors
9f297d330646ecc8ebb9dc5784f48b7c35b118c913e306a1ccd0192f2c976332  cohere-transcribe-03-2026-mlx-4bit/preprocessor_config.json
1814ce01458ff6a72b04a6618e75f18ce627be4dc17619cd3a7cd7f71e137f0f  cohere-transcribe-03-2026-mlx-4bit/special_tokens_map.json
6d21e6a83b2d0d3e1241a7817e4bef8eb63bcb7cfe4a2675af9a35ff3bbf0e14  cohere-transcribe-03-2026-mlx-4bit/tokenizer.model
0dfeb3eeba07bccaa1b4bf78f3135ad3059acf8d18f681675832b285ac0035b0  cohere-transcribe-03-2026-mlx-4bit/tokenizer_config.json
5abb01e2403b072bf03d04fde160443e209d7a0dad49a423be15196b9b43c17f  kokoro-82m-bf16/config.json
4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8  kokoro-82m-bf16/kokoro-v1_0.safetensors
2c1c733b0e6576c810e268d3e440c21dea4e0f0131a3ba4cfc98d7fe6136d094  kokoro-82m-bf16/voices/af_heart.safetensors
dc4a02e62d4fcb4bb4097ecf00db89b8e1a12a549a52ab6adfbba220b80a55c5  kokoro-g2p-en/us_bart.safetensors
8deb3537fb29c63cd9f20d75515ae06e4c92f1b6db0703a2d45bca95b33a53a4  kokoro-g2p-en/us_bart_config.json
8507f89840f0813b10cf584740942f58e9cc9ad3660e24088b442ab0a6b126be  kokoro-g2p-en/us_gold.json
ea0e1abca0c9b18fb0d3402034633a337154a3153e9a9f49f97d668c908e140c  kokoro-g2p-en/us_silver.json
EOF
}

verify() {
    local models_dir="$1"
    local expected actual

    if [[ ! -d "$models_dir" ]]; then
        echo "ERROR: model pack is missing at $models_dir" >&2
        return 1
    fi
    if [[ -n "$(find "$models_dir" ! -type d ! -type f -print -quit)" ]]; then
        echo "ERROR: model pack contains a symlink or non-file entry" >&2
        return 1
    fi

    expected=$(($(checksums | wc -l | tr -d ' ') + 2))
    actual=$(find "$models_dir" -type f | wc -l | tr -d ' ')
    if [[ "$actual" -ne "$expected" ]]; then
        echo "ERROR: model pack has $actual files, expected $expected" >&2
        return 1
    fi

    (
        cd "$models_dir"
        checksums | shasum -a 256 -c -
    )
    cmp "$ADAPTER_SOURCE/adapter_config.json" \
        "$models_dir/$ADAPTER_NAME/adapter_config.json"
    cmp "$ADAPTER_SOURCE/adapters.safetensors" \
        "$models_dir/$ADAPTER_NAME/adapters.safetensors"
}

download() {
    local python="${PYTHON:-python3}"

    if [[ -L "$MODEL_WORK" || ( -e "$MODEL_WORK" && ! -d "$MODEL_WORK" ) ]]; then
        echo "ERROR: model work path must be a real directory: $MODEL_WORK" >&2
        return 1
    fi
    mkdir -p "$MODEL_WORK"
    rm -rf "$MODEL_VENV"
    "$python" -m venv "$MODEL_VENV"
    # huggingface-hub 1.11.0 imports Click without declaring it.
    "$MODEL_PYTHON" -m pip install --disable-pip-version-check \
        'huggingface-hub==1.11.0' 'click==8.3.1'

    rm -rf "$MODEL_DIR"
    mkdir -p "$MODEL_DIR"
    "$MODEL_HF" download "$QWEN_REPO" "${QWEN_FILES[@]}" \
        --revision "$QWEN_REV" --local-dir "$MODEL_DIR/$QWEN_NAME"
    "$MODEL_HF" download "$COHERE_REPO" "${COHERE_FILES[@]}" \
        --revision "$COHERE_REV" --local-dir "$MODEL_DIR/$COHERE_NAME"
    "$MODEL_HF" download "$KOKORO_REPO" "${KOKORO_FILES[@]}" \
        --revision "$KOKORO_REV" --local-dir "$MODEL_DIR/$KOKORO_NAME"
    "$MODEL_HF" download "$KOKORO_G2P_REPO" "${KOKORO_G2P_FILES[@]}" \
        --revision "$KOKORO_G2P_REV" --local-dir "$MODEL_DIR/$KOKORO_G2P_NAME"
    rm -rf "$MODEL_DIR/$QWEN_NAME/.cache" "$MODEL_DIR/$COHERE_NAME/.cache" \
        "$MODEL_DIR/$KOKORO_NAME/.cache" "$MODEL_DIR/$KOKORO_G2P_NAME/.cache"
    cp -R "$ADAPTER_SOURCE" "$MODEL_DIR/$ADAPTER_NAME"
    verify "$MODEL_DIR"
}

case "${1:-}" in
    download)
        download
        ;;
    verify)
        verify "${2:-$MODEL_DIR}"
        ;;
    *)
        echo "usage: $0 {download|verify [models-directory]}" >&2
        exit 2
        ;;
esac
