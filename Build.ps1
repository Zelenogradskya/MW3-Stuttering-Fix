[CmdletBinding()]
param([string]$Compiler='x86_64-w64-mingw32-clang.exe')
$ErrorActionPreference='Stop'
$root=$PSScriptRoot

$settings=Join-Path $root 'settings.json'
if(Test-Path -LiteralPath $settings){$s=Get-Content -LiteralPath $settings -Raw|ConvertFrom-Json;if(Test-Path -LiteralPath (Join-Path $s.GamePath 'd3d9.dll')){throw 'Uninstall the game proxy before rebuilding.'}}
New-Item -ItemType Directory -Path (Join-Path $root 'bin'),(Join-Path $root 'build\tmp') -Force|Out-Null
$env:TEMP=Join-Path $root 'build\tmp';$env:TMP=$env:TEMP
$mh=Join-Path $root 'third_party\minhook'
$deps=@((Join-Path $mh 'src\hook.c'),(Join-Path $mh 'src\buffer.c'),(Join-Path $mh 'src\trampoline.c'),(Join-Path $mh 'src\hde\hde64.c'))
$incs=@('-I',(Join-Path $mh 'include'),'-I',(Join-Path $mh 'src'),'-I',(Join-Path $mh 'src\hde'))
$source=Join-Path $root 'src\runtime.c'
& $Compiler -O2 -Wall -Wextra -Werror -DAUDIO_CACHE_TEST $source -o (Join-Path $root 'build\core-test.exe')
if($LASTEXITCODE-ne0){throw 'Core test build failed'}
& (Join-Path $root 'build\core-test.exe')
if($LASTEXITCODE-ne0){throw 'Core tests failed'}
& $Compiler -shared -O2 -Wall -Wextra -Werror @incs $source @deps (Join-Path $root 'src\d3d9.def') '-Wl,--no-insert-timestamp' -ladvapi32 -o (Join-Path $root 'bin\d3d9.dll')
if($LASTEXITCODE-ne0){throw 'DLL build failed'}
& $Compiler -O2 -Wall -Wextra -Werror -municode -DAUDIO_MAP_TEST @incs $source @deps -ladvapi32 -o (Join-Path $root 'build\cache-map-test.exe')
if($LASTEXITCODE-ne0){throw 'Cache loader test build failed'}
& $Compiler -O2 -Wall -Wextra -Werror -municode (Join-Path $root 'src\loader-smoke.c') -o (Join-Path $root 'build\loader-smoke.exe')
if($LASTEXITCODE-ne0){throw 'Loader smoke build failed'}
& (Join-Path $root 'build\loader-smoke.exe') (Join-Path $root 'bin\d3d9.dll')
if($LASTEXITCODE-ne0){throw 'DLL forwarding test failed'}
$m=[ordered]@{ProductId='MW3StutteringFix.AudioCache.v1';Name='MW3 Stuttering Fix';Version='0.1.0-alpha';Author='MW3 Stuttering Fix contributors';License='MIT';DLLSHA256=(Get-FileHash -LiteralPath (Join-Path $root 'bin\d3d9.dll') -Algorithm SHA256).Hash}
$m|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $root 'package.json') -Encoding UTF8
Write-Host ("Built MW3 Stuttering Fix "+$m.Version+"; SHA256 "+$m.DLLSHA256)
