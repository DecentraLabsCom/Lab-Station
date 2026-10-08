# Shared source snapshot

This directory is a release snapshot of the standalone `DecentraLabsCom/FMU-Executor`
source repository. The current pin is in `VERSION` and `SOURCE.lock.json`, which
records the source commit, SHA-256 of a normalized Git tree-entry manifest, and
a content digest for the installed runtime files. These digests are stable
across Git for Windows and Linux. Station CI checks out that commit and verifies
every tracked source file against this snapshot. Linux setup also checks the
runtime content manifest before installation. Station releases package the
snapshot locally; they do not fetch Python source at runtime.

To update it, review the shared FMU Executor commit and its source tree manifest
digest, then run `scripts/sync-shared-fmu-executor.ps1 -SharedSource <checkout>
-UpdatePin`. Update the Linux station pin in the same change. Keep the Windows
and Linux Station release pins identical.
