$script:PackageRoot=Split-Path -Parent $PSScriptRoot
$script:ProductId='MW3StutteringFix.AudioCache.v1'
function Get-Sha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash }
function Get-Hex([byte[]]$Bytes) { [BitConverter]::ToString($Bytes).Replace('-','') }
function Get-ByteHash([byte[]]$Bytes) {
 $h=[Security.Cryptography.SHA256]::Create()
 try {Get-Hex ($h.ComputeHash($Bytes))}finally{$h.Dispose()}
}
function Get-CodeIdentity([string]$GamePath) {
 if([IO.Path]::GetFullPath($GamePath).Length-gt180){throw 'Use a game directory path shorter than 181 characters.'}
 $p=Join-Path $GamePath 'iw5sp.exe'
 $info=Get-Item -LiteralPath $p -ErrorAction Stop
 if($info.Length-lt1024 -or $info.Length-gt128MB){throw 'Invalid executable size.'}
 $b=[IO.File]::ReadAllBytes($p)
 if([BitConverter]::ToUInt16($b,0)-ne0x5a4d){throw 'Not a PE executable.'}
 $nt=[BitConverter]::ToInt32($b,0x3c)
 if($nt-lt64 -or $nt+264-ge$b.Length -or [BitConverter]::ToUInt32($b,$nt)-ne0x4550){throw 'Invalid PE header.'}
 $machine=[BitConverter]::ToUInt16($b,$nt+4)
 $sections=[BitConverter]::ToUInt16($b,$nt+6)
 $stamp=[BitConverter]::ToUInt32($b,$nt+8)
 $opt=[BitConverter]::ToUInt16($b,$nt+20)
 if($sections-lt1 -or $sections-gt96 -or $nt+24+$opt+$sections*40-gt$b.Length){throw 'Invalid PE section table.'}
 $imageSize=[BitConverter]::ToUInt32($b,$nt+24+56)
 for($i=0;$i-lt$sections;$i++) {
  $s=$nt+24+$opt+$i*40
  if([Text.Encoding]::ASCII.GetString($b,$s,8).Trim([char]0)-eq'.text') {
   $size=[BitConverter]::ToUInt32($b,$s+16);$off=[BitConverter]::ToUInt32($b,$s+20)
   if($size-eq0 -or [uint64]$off+$size-gt[uint64]$b.Length){throw 'Invalid code-section range.'}
   $sha=[Security.Cryptography.SHA256]::Create()
   try {$hash=Get-Hex ($sha.ComputeHash($b,[int]$off,[int]$size))}finally{$sha.Dispose()}
   return [pscustomobject]@{Machine=$machine;TimeStamp=$stamp;ImageSize=$imageSize;TextRVA=[BitConverter]::ToUInt32($b,$s+12);TextSHA256=$hash}
  }
 }
 throw 'Executable has no .text section.'
}
function Assert-SupportedGame([string]$GamePath) {
 $expected=Get-Content -LiteralPath (Join-Path $script:PackageRoot 'compatibility.json') -Raw|ConvertFrom-Json
 $actual=Get-CodeIdentity $GamePath
 foreach($name in @('Machine','TimeStamp','ImageSize','TextRVA','TextSHA256')) {
  if($actual.$name-ne$expected.$name){throw ("Unsupported iw5sp.exe code build. Detected .text SHA256: "+$actual.TextSHA256+". This alpha supports only the build listed in compatibility.json. No game file was changed.")}
 }
 return $actual
}
function Get-TargetProcesses([string]$GamePath) {
 $root=[IO.Path]::GetFullPath($GamePath).TrimEnd('\')+'\'
 foreach($p in Get-Process iw5sp,iw5mp -ErrorAction SilentlyContinue){
  try {$image=[IO.Path]::GetFullPath($p.MainModule.FileName)}
  catch {try{if($p.HasExited){continue}}catch{};throw 'Cannot inspect a running MW3 process. Close MW3 before continuing.'}
  if($image.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){$p}
 }
}
function Assert-GameClosed([string]$GamePath) {
 if(@(Get-TargetProcesses $GamePath).Count){throw 'Close Campaign and Multiplayer from this game directory first.'}
}

function Get-PackageInfo {
 $m=Get-Content -LiteralPath (Join-Path $script:PackageRoot 'package.json') -Raw|ConvertFrom-Json
 if($m.ProductId-ne$script:ProductId){throw 'Package metadata is invalid.'}
 return $m
}
function Read-Settings {
 $p=Join-Path $script:PackageRoot 'settings.json'
 if(-not(Test-Path -LiteralPath $p)){throw 'Run Setup.cmd first.'}
 $s=Get-Content -LiteralPath $p -Raw|ConvertFrom-Json
 if($s.ProductId-ne$script:ProductId){throw 'Unrecognized settings file.'}
 if($s.PSObject.Properties['CacheRelative'] -and $s.CacheRelative){
  $relative=[string]$s.CacheRelative
  $resolved=[IO.Path]::GetFullPath((Join-Path $script:PackageRoot $relative))
  if(-not$resolved.StartsWith($script:PackageRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe relative cache path.'}
  $s.CachePath=$resolved
 }
 return $s
}
function Get-GameCandidates {
 $libraries=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($key in @('HKCU:\Software\Valve\Steam','HKLM:\Software\WOW6432Node\Valve\Steam','HKLM:\Software\Valve\Steam')){
  try {
   if(Test-Path -LiteralPath $key -ErrorAction Stop){
    $r=Get-ItemProperty -LiteralPath $key -ErrorAction Stop
    foreach($n in @('SteamPath','InstallPath')){if($r.PSObject.Properties[$n] -and $r.$n){[void]$libraries.Add(([string]$r.$n).Replace('/','\'))}}
   }
  } catch {continue}
 }
 foreach($base in @($libraries)) {
  $vdf=Join-Path $base 'steamapps\libraryfolders.vdf'
  if(Test-Path -LiteralPath $vdf){
   $raw=Get-Content -LiteralPath $vdf -Raw
   foreach($m in [regex]::Matches($raw,'"path"\s+"((?:\\.|[^"])*)"')){[void]$libraries.Add($m.Groups[1].Value.Replace('\\','\'))}
  }
 }
 foreach($library in $libraries) {
  $manifest=Join-Path $library 'steamapps\appmanifest_42680.acf'
  if(Test-Path -LiteralPath $manifest) {
   $m=[regex]::Match((Get-Content -LiteralPath $manifest -Raw),'"installdir"\s+"([^"]+)"')
   if($m.Success -and $m.Groups[1].Value.IndexOfAny([IO.Path]::GetInvalidFileNameChars())-lt0){
    $p=Join-Path $library ('steamapps\common\'+$m.Groups[1].Value)
    if(Test-Path -LiteralPath (Join-Path $p 'iw5sp.exe')){$p}
   }
  }
 }
}
function Get-CacheManifest([string]$CachePath) {
 $m=Get-Content -LiteralPath (Join-Path $CachePath 'cache-manifest.json') -Raw|ConvertFrom-Json
 if($m.ProductId-ne$script:ProductId -or $m.Schema-ne1 -or $m.BlobFile-ne'audio.bin' -or $m.IndexFile-ne'index.bin'){throw 'Unsupported or invalid cache manifest.'}
 return $m
}
function Test-AudioCache([string]$GamePath,[string]$CachePath,[switch]$SkipArchives) {
 $m=Get-CacheManifest $CachePath
 foreach($entry in @(@($m.BlobFile,$m.BlobBytes,$m.BlobSHA256),@($m.IndexFile,$m.IndexBytes,$m.IndexSHA256))){
  $p=Join-Path $CachePath $entry[0]
  if((Get-Item -LiteralPath $p).Length-ne[long]$entry[1] -or (Get-Sha256 $p)-ne$entry[2]){throw "Cache integrity check failed: $p"}
 }
 if(-not $SkipArchives) {
  if(-not$m.Archives -or $m.Archives.Count-gt100){throw 'Invalid archive inventory.'}
  foreach($a in $m.Archives){
   if($a.Name-notmatch'^iw_[0-9]+\.iwd$'){throw 'Unsafe archive name in manifest.'}
   if((Get-Sha256 (Join-Path $GamePath ('main\'+$a.Name)))-ne$a.SHA256){throw "Game archive changed: $($a.Name). Rebuild the cache in an empty directory."}
  }
 }
 return $m
}
function Get-InstallMutex([string]$GamePath) {
 $name='Local\MW3SF-'+(Get-ByteHash ([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($GamePath).ToLowerInvariant()))).Substring(0,24)
 $mutex=[Threading.Mutex]::new($false,$name)
 try {$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
 if(-not$owned){$mutex.Dispose();throw 'Another MW3 Stuttering Fix launcher is already active.'}
 return $mutex
}
function Remove-FixFiles([string]$GamePath) {
 Assert-GameClosed $GamePath
 $package=Get-PackageInfo
 $dll=Join-Path $GamePath 'd3d9.dll';$ini=Join-Path $GamePath 'mw3sf.ini';$statePath=Join-Path $GamePath 'mw3sf-state.json'
 $state=$null
 if(Test-Path -LiteralPath $statePath){
  $state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
  if($state.ProductId-ne$script:ProductId -or $state.DLLSHA256-ne$package.DLLSHA256){throw 'Unrecognized install state. Nothing removed.'}
 }
 if(Test-Path -LiteralPath $dll){if((Get-Sha256 $dll)-ne$package.DLLSHA256){throw 'Unrecognized d3d9.dll. Nothing removed.'}}
 if(Test-Path -LiteralPath $ini){if(-not$state -or (Get-Sha256 $ini)-ne$state.IniSHA256){throw 'Unrecognized mw3sf.ini. Nothing removed.'}}
 foreach($p in @($dll,$ini,$statePath)){if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -ErrorAction Stop}}
}
function Install-FixFiles([string]$GamePath,[string]$CachePath) {
 Assert-GameClosed $GamePath
 $package=Get-PackageInfo
 $cache=Get-CacheManifest $CachePath
 $dll=Join-Path $GamePath 'd3d9.dll';$ini=Join-Path $GamePath 'mw3sf.ini';$state=Join-Path $GamePath 'mw3sf-state.json'
 if(Test-Path -LiteralPath $state){Remove-FixFiles $GamePath}
 foreach($p in @($dll,$ini,$state)){if(Test-Path -LiteralPath $p){throw "File already exists; it will not be overwritten: $p"}}
 $source=Join-Path $script:PackageRoot 'bin\d3d9.dll'
 if((Get-Sha256 $source)-ne$package.DLLSHA256){throw 'Package DLL integrity check failed.'}
 $token=[guid]::NewGuid().ToString('N')
 $stagedDll=Join-Path $GamePath ('mw3sf-'+$token+'.dll.tmp')
 $stagedIni=Join-Path $GamePath ('mw3sf-'+$token+'.ini.tmp')
 $stagedState=Join-Path $GamePath ('mw3sf-'+$token+'.state.tmp')
 try {
  Copy-Item -LiteralPath $source -Destination $stagedDll
  if((Get-Sha256 $stagedDll)-ne$package.DLLSHA256){throw 'Staged DLL hash mismatch.'}
  $config="[Cache]"+[Environment]::NewLine+"Root="+[IO.Path]::GetFullPath($CachePath)+[Environment]::NewLine+"IndexSHA256="+$cache.IndexSHA256+[Environment]::NewLine
  [IO.File]::WriteAllText($stagedIni,$config,[Text.Encoding]::Unicode)
  [ordered]@{ProductId=$script:ProductId;DLLSHA256=$package.DLLSHA256;IniSHA256=(Get-Sha256 $stagedIni);CreatedUTC=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath $stagedState -Encoding UTF8
  [IO.File]::Move($stagedState,$state)
  [IO.File]::Move($stagedIni,$ini)
  [IO.File]::Move($stagedDll,$dll)
 } catch {
  if(Test-Path -LiteralPath $state){Remove-FixFiles $GamePath}
  throw
 } finally {
  foreach($p in @($stagedDll,$stagedIni,$stagedState)){if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p}}
 }
}
