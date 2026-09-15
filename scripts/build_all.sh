#!/bin/bash
# One-shot local build on a Mac. Identical steps to the GitHub Actions workflow.
#
#   bash scripts/build_all.sh
#
# Override anything from the environment, e.g.
#   APP_BUNDLE_ID=com.yourname.RetroArchAccess IOS_DEPLOYMENT_TARGET=15 bash scripts/build_all.sh
#
# Each step is invoked through `bash` rather than executed directly. These files are authored on
# Windows and may arrive with mode 100644 when fetched through git or the GitHub API, in which case
# executing them straight would fail on the first run for no useful reason.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_macos

bash "${KIT_DIR}/scripts/fetch_sources.sh"
bash "${KIT_DIR}/scripts/build_core_ios.sh"
bash "${KIT_DIR}/scripts/build_vbam_ios.sh"
bash "${KIT_DIR}/scripts/build_app_ios.sh"
bash "${KIT_DIR}/scripts/make_ipa.sh"

log "artifacts in ${OUT_DIR}"
ls -la "$OUT_DIR"
