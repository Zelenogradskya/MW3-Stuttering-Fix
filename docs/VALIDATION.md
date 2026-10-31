# Validation — 2026-10-31

## Prototype gameplay observation

One RTX 5070 Ti / 60 Hz PC, Steam MW3 2011 x64. The user reported a noticeable improvement.

Metrics exclude the first 30 seconds. Different playthrough segments were recorded; this is not a controlled identical-scene benchmark or a stock-vs-release comparison.

| Metric | Prior nine-resource prototype | Common-audio prototype |
|---|---:|---:|
| Frames after 30 s | 3,907 | 5,396 |
| Median between-present interval | 16.72 ms | 16.59 ms |
| 99th percentile interval | 93.12 ms | 19.03 ms |
| Intervals above 50 ms | 102 | 1 |
| Intervals above 100 ms | 15 | 0 |
| Maximum interval | 128.21 ms | 87.08 ms |

An earlier trace showed 463,392 logical reads / 3.76 GB and about 0.66 MB of physical reads attributed to the process, predominantly repeated sound-archive activity. This indicated repeated cached reads/decompression rather than physical drive throughput alone.

## Portable package checks

- 1,000 native randomized cursor/read cases: byte equality, EOF, invalid offsets, fallback, failed resync, close/reuse and tell.
- Synthetic inventory: duplicate/localized ambiguity and traversal-like paths excluded.
- Windows PowerShell suite: 17 checks, including foreign proxy preservation, interrupted recovery, changed-INI refusal and Unicode INI parsing.
- Native parser: invalid ranges/counts rejected; corrupted resource bytes detected.
- Real cache generated under Windows PowerShell.
- All 2,401 public-loader slices SHA256-match original bytes used by the successful prototype.
- Full native mapped loader verification of all resources.
- Package/cache relocation to another Cyrillic folder with spaces; relative-cache lookup and read-only launch preflight passed.
- Supported EXE accepted; non-code trailing metadata difference accepted; changed executable code refused.
- DLL load/real-system D3D9 forwarding/release smoke passed in a non-game process.

The release's dynamic path/catalog loader was tested separately from the gameplay prototype.
The portable binary has not yet had an independent full-campaign gameplay pass or broad hardware testing.
No universal stutter-elimination or VAC/multiplayer-safety claim is made.

Raw gameplay traces, usernames, install paths, executables and extracted audio are not release payloads.
