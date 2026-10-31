# MW3 Stuttering Fix 0.1.0-alpha

Campaign-only streamed-audio stutter fix for one supported Steam x64 build of Call of Duty: Modern Warfare 3 (2011).

Includes a temporary D3D9 proxy, local cache generator, mapped audio index, Steam discovery, integrity/version guards, recognized-file recovery, source, tests and English/Russian instructions.

Extract outside the game directory. Run Setup.cmd once, choose a cache location with about 5 GB free, then use Start.cmd with Steam open.
Keep the launcher open until Campaign exits and the DLL is removed. If interrupted, close the game and run Uninstall.cmd.

A prototype showed a user-confirmed reduction in periodic hitches on one RTX 5070 Ti / 60 Hz system. See VALIDATION.md for the measured result and its limits.
This is an early alpha, not a claim of universal FPS improvement, complete stutter elimination, multiplayer compatibility or VAC safety.

Distribute the release ZIP only. Do not publish generated cache data or game files.
