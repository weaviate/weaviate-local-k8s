#!/usr/bin/env bash
set -eou pipefail

# Import functions from utilities.sh
source "./utilities/helpers.sh"

wait_for_raft_sync 3