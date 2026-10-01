set shell := ["bash", "-euo", "pipefail", "-c"]

default: list

list:
    @just --list --unsorted

lint:
    just --unstable --fmt --check

push: lint
    jj git push --bookmark main
