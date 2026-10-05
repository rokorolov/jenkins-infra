#!/bin/sh
set -e

JENKINS_AGENT_SSH_PUBKEY="$(cat /etc/jenkins-agent-keys/id_ed25519.pub)"
export JENKINS_AGENT_SSH_PUBKEY
exec setup-sshd "$@"
