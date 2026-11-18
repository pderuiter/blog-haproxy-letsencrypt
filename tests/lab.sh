#!/bin/bash
# How the repo was tested, on one Docker host, without the real Let's Encrypt:
# - Pebble (Let's Encrypt's test ACME server) stands in for Let's Encrypt;
# - pebble-challtestsrv answers DNS for every name with the HAProxy host's address,
#   so Pebble's HTTP-01 validation reaches HAProxy on port 80;
# - a systemd container (Ubuntu 24.04 by default, IMAGE=... to change) is the VM.
# Usage: tests/lab.sh up | run | down      (LAB_PREFIX=lab by default)
set -u
P=${LAB_PREFIX:-lab}-le; NET=$P-net; IMAGE=${IMAGE:-jrei/systemd-ubuntu:24.04}
PEBBLE=ghcr.io/letsencrypt/pebble:latest; CHALL=ghcr.io/letsencrypt/pebble-challtestsrv:latest
W=$PWD/.lab; mkdir -p "$W"
case "${1:-}" in
up)
  docker network create $NET >/dev/null
  docker run -d --name $P-lb --hostname haproxy1 --network $NET --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock "$IMAGE" >/dev/null
  LBIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $P-lb)
  docker run -d --name $P-chall --network $NET $CHALL \
    -defaultIPv4 "$LBIP" -defaultIPv6 "" -http01 "" -https01 "" -tlsalpn01 "" -doh "" >/dev/null
  CHIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $P-chall)
  id=$(docker create $PEBBLE); docker cp $id:/test/certs/pebble.minica.pem "$W/"; docker cp $id:/test/config/pebble-config.json "$W/orig.json"; docker rm $id >/dev/null
  python3 -c "import json,sys; c=json.load(open(sys.argv[1])); c['pebble']['httpPort']=80; json.dump(c,open(sys.argv[2],'w'))" "$W/orig.json" "$W/pebble.json"
  docker run -d --name $P-pebble --network $NET --network-alias pebble -e PEBBLE_VA_NOSLEEP=1 -e PEBBLE_WFE_NONCEREJECT=0 \
    -v "$W":/lab:ro $PEBBLE -config /lab/pebble.json -dnsserver "$CHIP:8053" >/dev/null
  sleep 4
  # what the cloud image already has, plus: trust Pebble's HTTPS endpoint
  docker exec $P-lb bash -c 'if command -v apt-get >/dev/null; then apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 sudo ca-certificates gnupg iproute2 curl >/dev/null; fi'
  docker cp "$W/pebble.minica.pem" $P-lb:/usr/local/share/ca-certificates/pebble-minica.crt
  docker exec $P-lb update-ca-certificates >/dev/null
  printf 'all:\n  children:\n    haproxy:\n      hosts:\n        %s:\n          ansible_connection: community.docker.docker\n' $P-lb > lab-inventory.yml
  ;;
run)
  cd ansible || exit 1
  ARGS="-i ../lab-inventory.yml -e @../tests/demo-vars.yml -e haproxy_letsencrypt_acme_server=https://pebble:14000/dir"
  for run in 1 2; do ansible-playbook $ARGS site.yml | sed -n '/PLAY RECAP/,$p'; done
  # trust the certificates Pebble issued (its root changes on every Pebble start)
  docker exec $P-lb bash -c 'curl -sk https://pebble:15000/roots/0 > /usr/local/share/ca-certificates/pebble-root.crt && update-ca-certificates >/dev/null'
  ansible-playbook $ARGS -e verify_renewal=true ../tests/verify.yml | sed -n '/PLAY RECAP/,$p'
  ;;
down)
  docker rm -f $P-lb $P-pebble $P-chall >/dev/null; docker network rm $NET >/dev/null
  rm -rf "$W" lab-inventory.yml
  ;;
*) echo "usage: $0 up|run|down"; exit 1 ;;
esac
