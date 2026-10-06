# Shared source snapshot

This directory is a release snapshot of the standalone `DecentraLabsCom/FMU-Executor`
source repository. The current pin is in `VERSION` and `SOURCE.lock.json`.
Station releases package this snapshot locally; they do not fetch Python source
at runtime.

To update it, obtain a signed source bundle from the shared FMU Executor release,
verify its published Minisign signature and SHA-256 manifest, confirm its
`VERSION`, then update this directory and both lock files together. Keep the
Windows and Linux Station release pins identical.
