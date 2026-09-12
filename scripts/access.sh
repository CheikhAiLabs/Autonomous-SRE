#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
"$ROOT/scripts/configure.sh" >/dev/null
NEW_IP="$(curl -fsS https://api.ipify.org)/32"
python3 - "$PROJECT_ENV" "$NEW_IP" <<'PYI'
from pathlib import Path
import sys
p=Path(sys.argv[1]); cidr=sys.argv[2]
lines=p.read_text().splitlines()
p.write_text("\n".join((f"OPERATOR_CIDR={cidr}" if x.startswith("OPERATOR_CIDR=") else x) for x in lines)+"\n")
PYI
load_config
require_repo
gh variable set OPERATOR_CIDR --repo "$GITHUB_REPOSITORY" --env production --body "$NEW_IP"
echo "Operator CIDR updated to $NEW_IP. Run make deploy to reconcile Security Groups and Gateway allow-list."
