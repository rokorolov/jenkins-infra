#!/bin/sh
set -e

key=/etc/jenkins-agent-keys/id_ed25519
if [ ! -f "$key" ]; then
    ssh-keygen -q -t ed25519 -N '' -C jenkins-agent -f "$key"
fi
