#!/bin/bash
set -e

# Build EVerest Docker image for ARM64 architecture
# This script forces ARM64 platform for Apple Silicon / Raspberry Pi compatibility

IMAGE_NAME="${IMAGE_NAME:-everest-ocpp}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

echo "=== Building EVerest Docker Image for ARM64 ==="
echo "Image: ${IMAGE_NAME}:${IMAGE_TAG}"
echo "Platform: linux/arm64"
echo ""

docker build \
    --platform linux/arm64 \
    --tag "${IMAGE_NAME}:${IMAGE_TAG}" \
    --tag "${IMAGE_NAME}:arm64" \
    --progress=plain \
    .

echo ""
echo "=== Build Complete ==="
echo "Image: ${IMAGE_NAME}:${IMAGE_TAG}"
echo ""
echo "Run with:"
echo "  docker run -d -p 1880:1880 -e OCPP_URL=ws://your-csms:9000 -e OCPP_ID=CP001 ${IMAGE_NAME}:${IMAGE_TAG}"

