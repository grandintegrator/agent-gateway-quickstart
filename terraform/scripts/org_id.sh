#!/usr/bin/env bash
# External data source: the organization id a project belongs to, found by
# walking its ancestry (data.google_project.org_id is empty for projects that
# live in a folder). Usage: org_id.sh <project_id>
set -euo pipefail
gcloud projects get-ancestors "$1" --format=json | python3 -c "
import json,sys
for a in json.load(sys.stdin):
    if a['type']=='organization': print(json.dumps({'org_id': a['id']})); break
else: sys.exit('no organization in the ancestry of $1 — set var.org_id')"
