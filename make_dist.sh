#!/bin/bash
# Сборка дистрибутива плагина: dist/AirPlay2Bridge-v<VER>.zip + sha1.
# Перед релизом: поднять версию в AirPlay2Bridge/install.xml и repo.xml.
set -e
cd "$(dirname "$0")"

VER=$(grep -oPm1 '(?<=<version>)[^<]+' AirPlay2Bridge/install.xml)
ZIP="dist/AirPlay2Bridge-v${VER}.zip"

rm -rf dist
mkdir -p dist
zip -r "$ZIP" AirPlay2Bridge -x "*.DS_Store" "*__pycache__*" "*.pyc"
echo
echo "ZIP: $ZIP"
echo "sha1: $(sha1sum "$ZIP" | cut -d' ' -f1)"
echo "Upload as release asset v${VER} and update repo.xml (sha=, url=)."
