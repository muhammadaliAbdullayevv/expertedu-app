#!/usr/bin/env bash
# Builds the Fedora RPM: a release `flutter build linux`, then packages that
# bundle with the .desktop entry and launcher icons. The .rpm lands in
# build/dist/.
#
# Usage: linux/packaging/build-rpm.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

# pubspec "version: 1.6.0+7" -> RPM Version 1.6.0, Release 7. The build
# number is the same ever-increasing versionCode Android's update check
# compares, so RPM upgrades order exactly the same way.
version_line="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml)"
version="${version_line%%+*}"
build="${version_line##*+}"

flutter build linux --release

topdir="$root/build/rpmbuild"
rm -rf "$topdir"
mkdir -p "$topdir/SOURCES"

tar -C build/linux/x64/release -czf "$topdir/SOURCES/expert-edu-center-$version.tar.gz" \
  --transform "s,^bundle,expert-edu-center-$version," bundle
cp linux/packaging/uz.expertedu.expert_edu_center.desktop "$topdir/SOURCES/"
for icon in linux/packaging/icons/*.png; do
  cp "$icon" "$topdir/SOURCES/icon-$(basename "$icon")"
done

rpmbuild -bb linux/packaging/expert-edu-center.spec \
  --define "_topdir $topdir" \
  --define "app_version $version" \
  --define "app_release $build"

mkdir -p build/dist
cp "$topdir"/RPMS/x86_64/expert-edu-center-"$version"-"$build".*.rpm build/dist/
ls -1 build/dist/expert-edu-center-"$version"-"$build".*.rpm
