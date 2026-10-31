[CmdletBinding()]
param([string]$WorkRoot,[string]$SupportedGamePath)
if(-not$WorkRoot){$WorkRoot=Join-Path (Split-Path -Parent $PSScriptRoot) 'build\test-work'}
$ErrorActionPreference='Stop'
$package=Split-Path -Parent $PSScriptRoot
. (Join-Path $package 'lib\Common.ps1')
. (Join-Path $package 'lib\Cache.ps1')
$work=Join-Path ([IO.Path]::GetFullPath($WorkRoot)) ('qa-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $work 'game'
$main=Join-Path $game 'main'
$cache=Join-Path $work 'cache с пробелами'
New-Item -ItemType Directory -Path $main,$cache -Force|Out-Null
$results=[Collections.Generic.List[object]]::new()
function Check([bool]$Condition,[string]$Name){if(-not$Condition){throw "FAIL: $Name"};$results.Add([pscustomobject]@{Test=$Name;Passed=$true})}
function New-TestZip([string]$Path,[hashtable]$Entries) {
 $z=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
 try{foreach($key in $Entries.Keys){$e=$z.CreateEntry($key,[IO.Compression.CompressionLevel]::Optimal);$s=$e.Open();try{$bytes=[byte[]]$Entries[$key];$s.Write($bytes,0,$bytes.Length)}finally{$s.Dispose()}}}finally{$z.Dispose()}
}
$a=New-Object byte[] 333;$b=New-Object byte[] 2051
for($i=0;$i-lt$a.Length;$i++){$a[$i]=[byte]($i%251)}
for($i=0;$i-lt$b.Length;$i++){$b[$i]=[byte](($i*13)%253)}
New-TestZip (Join-Path $main 'iw_00.iwd') @{'Sound/test/a.wav'=$a;'sound/test/mixed.mp3'=$b;'sound/test/override.wav'=$a;'sound/../escape.wav'=$a}
New-TestZip (Join-Path $main 'iw_01.iwd') @{'sound/test/duplicate.wav'=$a}
New-TestZip (Join-Path $main 'iw_02.iwd') @{'SOUND/test/duplicate.wav'=$b}
New-TestZip (Join-Path $main 'localized_russian_iw00.iwd') @{'sound/test/override.wav'=$b}
$inventory=Get-AudioInventory $game
Check ($inventory.Assets.Count-eq2) 'inventory excludes duplicate, localized override and traversal paths'
$m=New-AudioCache $game $cache $inventory
Check ($m.Resources-eq2) 'cache creation from synthetic archives'
$v=Test-AudioCache $game $cache
Check ($v.IndexBytes-eq(96+312*2)) 'portable binary index size'
$map=Join-Path $package 'build\cache-map-test.exe'
& $map $cache $m.IndexSHA256
Check ($LASTEXITCODE-eq0) 'native mapped loader supports Cyrillic and spaces'
$index=Join-Path $cache 'index.bin';$indexBytes=[IO.File]::ReadAllBytes($index)
$bad=[byte[]]$indexBytes.Clone()
[Array]::Copy([BitConverter]::GetBytes([uint64]([long]$m.BlobBytes+1)),0,$bad,96+264,8)
[IO.File]::WriteAllBytes($index,$bad)
& $map $cache (Get-Sha256 $index)
Check ($LASTEXITCODE-ne0) 'native loader rejects out-of-bounds resource offset'
$bad=[byte[]]$indexBytes.Clone();[Array]::Copy([BitConverter]::GetBytes([uint32]4294967295),0,$bad,12,4);[IO.File]::WriteAllBytes($index,$bad)
& $map $cache (Get-Sha256 $index)
Check ($LASTEXITCODE-ne0) 'native loader rejects excessive catalog count'
[IO.File]::WriteAllBytes($index,$indexBytes)
$blob=Join-Path $cache 'audio.bin';$blobBytes=[IO.File]::ReadAllBytes($blob)
$bad=[byte[]]$blobBytes.Clone();$bad[65536]=$bad[65536]-bxor1;[IO.File]::WriteAllBytes($blob,$bad)
$rejected=$false;try{$null=Test-AudioCache $game $cache}catch{$rejected=$true}
Check $rejected 'launcher integrity guard rejects changed audio data'
& $map $cache $m.IndexSHA256
Check ($LASTEXITCODE-ne0) 'native map validation detects changed resource bytes'
[IO.File]::WriteAllBytes($blob,$blobBytes)
$dll=Join-Path $game 'd3d9.dll'
[IO.File]::WriteAllBytes($dll,[byte[]]@(1,2,3,4,5))
$foreignHash=Get-Sha256 $dll;$refused=$false
try{Install-FixFiles $game $cache}catch{$refused=$true}
Check ($refused-and(Get-Sha256 $dll)-eq$foreignHash) 'foreign d3d9.dll is not overwritten'
Remove-Item -LiteralPath $dll
Install-FixFiles $game $cache
$pkg=Get-PackageInfo
Check ((Get-Sha256 $dll)-eq$pkg.DLLSHA256) 'known DLL staged and installed'
$ini=Join-Path $game 'mw3sf.ini';$state=Join-Path $game 'mw3sf-state.json'
$iniBytes=[IO.File]::ReadAllBytes($ini)
& $map --ini $ini
Check ($LASTEXITCODE-eq0) 'native INI parser reads Unicode cache path'
[IO.File]::AppendAllText($ini,'changed')
$refused=$false;try{Remove-FixFiles $game}catch{$refused=$true}
Check ($refused-and(Test-Path -LiteralPath $dll)) 'recovery refuses a changed configuration without partial deletion'
[IO.File]::WriteAllBytes($ini,$iniBytes)
Remove-FixFiles $game
Check (-not(Test-Path -LiteralPath $dll)-and-not(Test-Path -LiteralPath $ini)-and-not(Test-Path -LiteralPath $state)) 'normal recovery removes only known install files'
Install-FixFiles $game $cache
Remove-Item -LiteralPath $dll
Remove-FixFiles $game
Check (-not(Test-Path -LiteralPath $ini)-and-not(Test-Path -LiteralPath $state)) 'interrupted install state is recoverable'
if($SupportedGamePath){
 $id=Assert-SupportedGame $SupportedGamePath
 & $map --validate-exe (Join-Path $SupportedGamePath 'iw5sp.exe')
 Check ($LASTEXITCODE-eq0) 'native supported executable guard'
 $copy=Join-Path $work 'identity-test.exe';Copy-Item -LiteralPath (Join-Path $SupportedGamePath 'iw5sp.exe') -Destination $copy
 $f=[IO.File]::Open($copy,[IO.FileMode]::Append,[IO.FileAccess]::Write);try{$f.WriteByte(42)}finally{$f.Dispose()}
 & $map --validate-exe $copy
 Check ($LASTEXITCODE-eq0) 'code identity tolerates non-code trailing metadata differences'
 $bytes=[IO.File]::ReadAllBytes($copy);$nt=[BitConverter]::ToInt32($bytes,0x3c);$opt=[BitConverter]::ToUInt16($bytes,$nt+20);$off=[BitConverter]::ToUInt32($bytes,$nt+24+$opt+20);$bytes[$off]=$bytes[$off]-bxor1;[IO.File]::WriteAllBytes($copy,$bytes)
 & $map --validate-exe $copy
 Check ($LASTEXITCODE-ne0) 'native guard rejects changed executable code'
}
$results|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $work 'test-results.json') -Encoding UTF8
Write-Host ("PASS: "+$results.Count+" package checks. Results: "+(Join-Path $work 'test-results.json'))
