#!/bin/bash
set -x
exec > /tmp/slbuild2.log 2>&1
sed -i 's/^#deb-src/deb-src/' /etc/apt/sources.list
apt-get update -qq
echo '=== APT UPDATE DONE ==='
rm -rf /root/slbuild && mkdir -p /root/slbuild && cd /root/slbuild
apt-get source squeezelite
echo '=== SOURCE DONE ==='
apt-get build-dep -y squeezelite
echo '=== BUILDDEP DONE ==='
cd squeezelite-*/ || exit 1
cp /tmp/output_stdout.c ./output_stdout.c
make -j4
strip squeezelite
echo '=== MAKE DONE ==='
cp squeezelite /usr/local/bin/squeezelite-ap2
echo '=== ALL DONE ==='
