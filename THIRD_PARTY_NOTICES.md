# Third-party notices

RooSync embeds Syncthing v2.1.7, licensed under MPL-2.0, and gomobile at
`v0.0.0-20260410095206-2cfb76559b7b`, licensed under Apache-2.0. Syncthing's
transitive Go dependencies retain their respective licenses. CI collects the
license texts with the pinned `go-licenses` v1.6.0 and includes them in the
source and build artifacts under `third_party_licenses/`.

The Syncthing source and dependency versions are pinned by
`Scripts/build-core.sh`; generated framework binaries are not committed.
