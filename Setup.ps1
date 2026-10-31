[CmdletBinding()]
param([string]$GamePath,[string]$CachePath,[switch]$NonInteractive)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Cache.ps1')
if(-not$GamePath) {
 $found=@(Get-GameCandidates|Select-Object -Unique)
 if($found.Count-eq1){$GamePath=$found[0]}
 elseif($NonInteractive){throw 'Specify -GamePath for an installed supported Steam copy.'}
 else {
  if($found.Count){Write-Host 'Detected game directories:';for($i=0;$i-lt$found.Count;$i++){Write-Host ("["+$i+"] "+$found[$i])}}
  $answer=Read-Host 'Game directory (or detected number)'
  $n=0;if([int]::TryParse($answer,[ref]$n)-and$n-ge0-and$n-lt$found.Count){$GamePath=$found[$n]}else{$GamePath=$answer.Trim('"')}
 }
}
$GamePath=[IO.Path]::GetFullPath($GamePath).TrimEnd('\')
if($PSScriptRoot.StartsWith($GamePath+'\',[StringComparison]::OrdinalIgnoreCase)-or$PSScriptRoot-eq$GamePath){throw 'Extract this package outside the game directory.'}
$identity=Assert-SupportedGame $GamePath
if(-not$CachePath){
 $default=Join-Path $PSScriptRoot 'cache'
 if($NonInteractive){$CachePath=$default}else{$a=Read-Host ("Cache directory ["+$default+"]");$CachePath=if([string]::IsNullOrWhiteSpace($a)){$default}else{$a.Trim('"')}}
}
$CachePath=[IO.Path]::GetFullPath($CachePath).TrimEnd('\')
if($CachePath.StartsWith($GamePath+'\',[StringComparison]::OrdinalIgnoreCase)-or$CachePath-eq$GamePath){throw 'Choose a cache directory outside the game directory.'}
if($CachePath.IndexOfAny([char[]]@(10,13))-ge0){throw 'Invalid cache path.'}
$mutex=[Threading.Mutex]::new($false,('Local\MW3SFCache-'+(Get-ByteHash ([Text.Encoding]::UTF8.GetBytes($CachePath.ToLowerInvariant()))).Substring(0,24)))
$owned=$false
try {
 try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
 if(-not$owned){throw 'Another cache setup is already running.'}
 if(Test-Path -LiteralPath (Join-Path $CachePath 'cache-manifest.json')){
  Write-Host 'Verifying existing cache.'
  $manifest=Test-AudioCache $GamePath $CachePath
 }else{
  Write-Host 'Scanning original archives. Audio is generated locally; no game data is downloaded.'
  $inventory=Get-AudioInventory $GamePath
  Write-Host ("Preparing "+$inventory.Assets.Count+" resources. Keep this window open.")
  $manifest=New-AudioCache $GamePath $CachePath $inventory
 }
 $relative=$null
 if($CachePath.StartsWith($PSScriptRoot+'\',[StringComparison]::OrdinalIgnoreCase)){$relative=$CachePath.Substring($PSScriptRoot.Length+1)}
 $settings=[ordered]@{ProductId=$script:ProductId;Schema=1;GamePath=$GamePath;CachePath=$CachePath;CacheRelative=$relative;CreatedUTC=[DateTime]::UtcNow.ToString('o')}
 $target=Join-Path $PSScriptRoot 'settings.json'
 if(Test-Path -LiteralPath $target){$old=Get-Content -LiteralPath $target -Raw|ConvertFrom-Json;if($old.ProductId-ne$script:ProductId){throw 'Refusing to replace an unknown settings.json.'}}
 $stage=$target+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 $settings|ConvertTo-Json|Set-Content -LiteralPath $stage -Encoding UTF8
 if(Test-Path -LiteralPath $target){[IO.File]::Replace($stage,$target,[NullString]::Value)}else{[IO.File]::Move($stage,$target)}
 Write-Host ("Setup complete: "+$manifest.Resources+" resources. Run Start.cmd for Campaign.")
}finally{if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
