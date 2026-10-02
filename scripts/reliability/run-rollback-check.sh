#!/usr/bin/env bash
set -euo pipefail
# Do not present the former simulated observations as a rollback implementation.
printf 'ROLLBACK_CHECK_RESULT=ERROR\n' >&2
printf 'ROLLBACK_CHECK_NEXT_STEP=hot-reload threshold rollback is not implemented; foreground restart belongs to the supervisor\n' >&2
exit 2
