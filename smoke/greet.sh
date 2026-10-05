#!/usr/bin/env bash
# Throwaway file for the codex engine smoke test (PR #143). Never merged.
name=$1
if [ $name == "" ]; then
  echo "usage: greet.sh NAME"
fi
echo "Hello, $name"
