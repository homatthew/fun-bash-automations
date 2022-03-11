#!/usr/bin/env bash

set -e
rb_create() {(
  TMP_BRANCH=$(git branch --show-current)
  git branch "${TMP_BRANCH}" -u origin/master
  git review create
  git branch $TMP_BRANCH -u "origin/${TMP_BRANCH}"
)}

rb_create
set +e