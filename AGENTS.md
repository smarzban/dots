# Project guidance

Keep `bin/dots` compatible with macOS `/bin/bash` 3.2 and BSD userland. Preserve the allowlist-only staging and fail-closed security boundary. Tests must use temporary homes and local remotes, never a real home or network remote.
