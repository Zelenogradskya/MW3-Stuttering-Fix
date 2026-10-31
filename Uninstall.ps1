[CmdletBinding()]
param([string]$GamePath,[string]$CachePath,[switch]$RemoveCache,[switch]$Elevated)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
if(-not$GamePath -or (-not$CachePath-and$RemoveCache)){
 $settings=Read-Settings
 if(-not$GamePath){$GamePath=$settings.GamePath}
 if(-not$CachePath){$CachePath=$settings.CachePath}
}
Assert-GameClosed $GamePath
$needsWrite=$false
foreach($name in @('d3d9.dll','mw3sf.ini','mw3sf-state.json')){if(Test-Path -LiteralPath (Join-Path $GamePath $name)){$needsWrite=$true}}
if($needsWrite) {
 $probe=Join-Path $GamePath ('mw3sf-'+[guid]::NewGuid().ToString('N')+'.write-test')
 try{$f=[IO.File]::Open($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$f.Dispose();Remove-Item -LiteralPath $probe}
 catch [UnauthorizedAccessException] {
  if($Elevated){throw}
  Write-Host 'Windows requires permission to remove the temporary game files.'
  $a='-NoProfile -ExecutionPolicy Bypass -File "{0}" -GamePath "{1}" -Elevated' -f $PSCommandPath,$GamePath
  if($CachePath){$a+=' -CachePath "'+$CachePath+'"'}
  if($RemoveCache){$a+=' -RemoveCache'}
  Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $a -Verb RunAs -WindowStyle Normal -Wait
  return
 }
}
$mutex=Get-InstallMutex $GamePath
try{Remove-FixFiles $GamePath;Write-Host 'Known fix files removed from the game directory.'}finally{$mutex.ReleaseMutex();$mutex.Dispose()}
if($RemoveCache){
 $path=[IO.Path]::GetFullPath($CachePath).TrimEnd('\')
 $owner=Join-Path $path 'CACHE-OWNER.txt'
 if($path.Length-lt4 -or -not(Test-Path -LiteralPath $owner)-or(Get-Content -LiteralPath $owner -Raw).Trim()-ne$script:ProductId){throw 'Refusing to delete data from an unrecognized cache directory.'}
 foreach($name in @('audio.bin','index.bin','cache-manifest.json','resource-hashes.json')){$p=Join-Path $path $name;if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p}}
 Write-Host 'Generated cache data removed. Logs and other files were preserved.'
}
