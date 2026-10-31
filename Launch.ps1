[CmdletBinding()]
param([switch]$ValidateOnly,[switch]$Elevated)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
$settings=Read-Settings
$game=[IO.Path]::GetFullPath($settings.GamePath).TrimEnd('\')
$cache=[IO.Path]::GetFullPath($settings.CachePath).TrimEnd('\')
if(-not$ValidateOnly){Assert-GameClosed $game}
$identity=Assert-SupportedGame $game
$package=Get-PackageInfo
if((Get-Sha256 (Join-Path $PSScriptRoot 'bin\d3d9.dll'))-ne$package.DLLSHA256){throw 'Package DLL is corrupt or changed.'}
Write-Host 'Checking cache and archive integrity. This may take several seconds.'
$m=Test-AudioCache $game $cache
if($ValidateOnly){Write-Host ("PRECHECK OK: "+$m.Resources+" resources; supported executable; cache and archive hashes verified. No game files changed.");return}
if(-not(Get-Process steam -ErrorAction SilentlyContinue)){throw 'Open Steam normally before launching Campaign.'}
# Elevation is requested only if the game directory is not writable.
$probe=Join-Path $game ('mw3sf-'+[guid]::NewGuid().ToString('N')+'.write-test')
try {
 $f=[IO.File]::Open($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 $f.Dispose();Remove-Item -LiteralPath $probe
}catch [UnauthorizedAccessException] {
 if($Elevated){throw}
 Write-Host 'Windows requires permission to place the temporary DLL in the game directory.'
 $a='-NoProfile -ExecutionPolicy Bypass -File "{0}" -Elevated' -f $PSCommandPath
 Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $a -Verb RunAs -WindowStyle Normal -Wait
 return
}
$mutex=Get-InstallMutex $game
$installed=$false
try {
 Install-FixFiles $game $cache
 $installed=$true
 Write-Host 'MW3 Stuttering Fix active for Campaign. Keep this window open until you exit the game.'
 Start-Process 'steam://rungameid/42680'
 $deadline=[DateTime]::UtcNow.AddMinutes(5)
 do {
  $process=Get-TargetProcesses $game|Where-Object {$_.ProcessName -eq 'iw5sp'}|Select-Object -First 1
  if($process){break}
  if([DateTime]::UtcNow-gt$deadline){throw 'Campaign did not start within five minutes.'}
  Start-Sleep -Milliseconds 500
 }while($true)
 while(@(Get-TargetProcesses $game).Count){Start-Sleep -Seconds 1}
}finally{
 try {
  if($installed) {
   if(@(Get-TargetProcesses $game).Count){Write-Warning 'Close the game, then run Uninstall.cmd before Multiplayer.'}
   else{Remove-FixFiles $game;Write-Host 'Temporary DLL removed. Original game files are unchanged.'}
  }
 }finally{$mutex.ReleaseMutex();$mutex.Dispose()}
}
