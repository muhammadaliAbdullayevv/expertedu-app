#!/usr/bin/env bash
# Publishes the current commit's desktop builds for the apps' self-update:
#   tools/publish-desktop.sh "What's new, in Uzbek"
#
# 1. Takes the Windows installer from this commit's successful
#    "Windows build" run (push first and let it finish).
# 2. Builds the Fedora RPM here (linux/packaging/build-rpm.sh).
# 3. Uploads both to the server's uploads/desktop/, then version.json last
#    -- an app never sees a version whose files aren't there yet.
#
# Installed apps pick it up within a few hours, or at their next start.
set -euo pipefail

notes="${1:-}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

ssh_opts=(-p 10054 -i "$HOME/.ssh/databasemart" -o BatchMode=yes)
host=administrator@108.181.203.226
remote_dir=/opt/expertedu/backend/uploads/desktop

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit your changes first -- the published build must match a commit." >&2
  exit 1
fi
commit="$(git rev-parse HEAD)"
if ! git branch -r --contains "$commit" | grep -q .; then
  echo "Push first: CI builds the Windows installer from the pushed commit." >&2
  exit 1
fi

version_line="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml)"
version="${version_line%%+*}"
build="${version_line##*+}"

run_id="$(gh run list --workflow windows.yml --commit "$commit" --status success \
  --json databaseId -q '.[0].databaseId')"
if [[ -z "$run_id" ]]; then
  echo "No successful Windows build for $commit yet -- wait for it, then rerun." >&2
  exit 1
fi

out="$root/build/publish"
rm -rf "$out"
mkdir -p "$out"
gh run download "$run_id" -n expert-edu-center-windows-setup -D "$out"
setup="$(ls "$out"/expert-edu-center-setup-"$version".exe)"

linux/packaging/build-rpm.sh
rpm="$(ls build/dist/expert-edu-center-"$version"-"$build".*.rpm)"
cp "$rpm" "$out/"
rpm="$out/$(basename "$rpm")"

sha() { sha256sum "$1" | cut -d' ' -f1; }
python3 - "$out/version.json" "$build" "$version" "$notes" \
  "$(basename "$setup")" "$(sha "$setup")" "$(basename "$rpm")" "$(sha "$rpm")" <<'PY'
import json, sys
path, build, version, notes, exe, exe_sha, rpm, rpm_sha = sys.argv[1:]
json.dump({
    "version_code": int(build),
    "version_name": version,
    "notes": notes or None,
    "windows": {"url": f"/uploads/desktop/{exe}", "sha256": exe_sha},
    "linux_rpm": {"url": f"/uploads/desktop/{rpm}", "sha256": rpm_sha},
}, open(path, "w"), ensure_ascii=False, indent=2)
PY

ssh "${ssh_opts[@]}" "$host" "mkdir -p $remote_dir"
rsync -a -e "ssh ${ssh_opts[*]}" "$setup" "$rpm" "$host:$remote_dir/"
rsync -a -e "ssh ${ssh_opts[*]}" "$out/version.json" "$host:$remote_dir/version.json.new"
# Swap in the new version.json, then keep only the newest 3 of each file.
ssh "${ssh_opts[@]}" "$host" "cd $remote_dir && mv version.json.new version.json && \
  ls -1t expert-edu-center-setup-*.exe | tail -n +4 | xargs -r rm -- && \
  ls -1t expert-edu-center-*.rpm | tail -n +4 | xargs -r rm --"

echo "Published $version (build $build):"
curl -fsS "https://expertedu-api.ai-student-helper.site/uploads/desktop/version.json"
