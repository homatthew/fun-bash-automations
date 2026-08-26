#!/usr/bin/env bash

secure_dir() {
  mkdir -p "$1" || return 1
  chmod 700 "$1"
}

secure_file() {
  [ ! -e "$1" ] || chmod 600 "$1"
}
