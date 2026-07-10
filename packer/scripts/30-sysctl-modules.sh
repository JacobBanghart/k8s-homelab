#!/bin/bash
set -euxo pipefail

# Sanity check: fail the build if the required modules/sysctls from
# 10-containerd.sh didn't actually take, rather than silently shipping a
# template that can't run k8s pod networking.

lsmod | grep -q '^overlay'
lsmod | grep -q '^br_netfilter'

test "$(sysctl -n net.bridge.bridge-nf-call-iptables)" = "1"
test "$(sysctl -n net.ipv4.ip_forward)" = "1"

echo "kernel modules and sysctls verified OK"
