#!/usr/bin/env bash
set -euo pipefail

# GitHub's Ubuntu images prefer azure.archive.ubuntu.com through this mirror
# list. When that mirror accepts a connection and then stops sending package
# indexes, apt's mirror fallback can wait forever. Use Ubuntu's main HTTPS
# mirror and put a hard bound on every network attempt.
mirrors=/etc/apt/apt-mirrors.txt
if [[ -f "$mirrors" ]]; then
    sudo sed -Ei \
        's#https?://azure\.archive\.ubuntu\.com#https://archive.ubuntu.com#g; s#http://archive\.ubuntu\.com#https://archive.ubuntu.com#g' \
        "$mirrors"
fi

sudo timeout --signal=TERM 5m apt-get \
    -o Acquire::Retries=3 \
    -o Acquire::http::Timeout=20 \
    -o Acquire::https::Timeout=20 \
    update
