FROM python:3.12-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/data/huggingface \
    GRADIO_TEMP_DIR=/data/gradio \
    TMPDIR=/data/tmp \
    GRADIO_ANALYTICS_ENABLED=False \
    GRADIO_SHARE=False

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg libsndfile1 sox \
    && rm -rf /var/lib/apt/lists/*

RUN python -m pip install --no-cache-dir torch==2.9.1 torchaudio==2.9.1 --index-url https://download.pytorch.org/whl/cu128 \
    && python -m pip install --no-cache-dir qwen-tts==0.1.1 gradio==5.50.0 \
    && python -m pip check

RUN mkdir -p /data/huggingface /data/gradio /data/tmp

WORKDIR /data
EXPOSE 8000
ENTRYPOINT ["qwen-tts-demo"]