#!/usr/bin/env bash
# Downloads the raw Kaggle source dataset used by build_dataset.py.
# Requires a Kaggle API credential at ~/.kaggle/ (see docs/study-guide.md, Section 2).
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p data/raw
kaggle datasets download -d zaurbegiev/my-dataset --unzip -p data/raw
echo "Downloaded to data/raw/credit_train.csv and data/raw/credit_test.csv"
