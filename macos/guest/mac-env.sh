#!/bin/bash
# wt enter hook: the env cargo-zigbuild needs for aarch64-apple-darwin. stdout is wt's env
# channel (KEY=VALUE lines only — anything else is dropped); diagnostics belong on stderr.
# /opt/MacOSX.sdk is the provision-time copy of the HOST's CLT SDK (see macos/lima.yaml).
echo "SDKROOT=/opt/MacOSX.sdk"
echo "MACOSX_DEPLOYMENT_TARGET=13.0"
