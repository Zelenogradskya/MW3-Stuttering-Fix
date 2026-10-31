[CmdletBinding()]
param([string]$OutputDirectory)
if(-not$OutputDirectory){$OutputDirectory=Split-Path -Parent $PSScriptRoot}
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$m=Get-Content -LiteralPath (Join-Path $root 'package.json') -Raw|ConvertFrom-Json
if($m.ProductId-ne'MW3StutteringFix.AudioCache.v1'-or$m.Version-notmatch'^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$'){throw 'Invalid package metadata'}
if((Get-FileHash -LiteralPath (Join-Path $root 'bin\d3d9.dll') -Algorithm SHA256).Hash-ne$m.DLLSHA256){throw 'DLL integrity check failed'}
$rootFiles=@('Setup.cmd','Start.cmd','Uninstall.cmd','Setup.ps1','Launch.ps1','Uninstall.ps1','Build.ps1','Pack.ps1','README.md','README.ru.md','CREDITS.md','CHANGELOG.md','LICENSE','package.json','compatibility.json','.gitignore')
$files=[Collections.Generic.List[object]]::new()
foreach($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force){
 $relative=$file.FullName.Substring($root.Length+1).Replace('\','/')
 $allow=$rootFiles-contains$relative
 if($relative-eq'bin/d3d9.dll'){$allow=$true}
 if($relative-match'^(lib|tests)/[^/]+\.ps1$'-or$relative-match'^src/[^/]+\.(c|h|def)$'-or$relative-match'^docs/[^/]+\.md$'){$allow=$true}
 if($relative-eq'third_party/minhook/LICENSE.txt'-or$relative-match'^third_party/minhook/(include|src)/.+\.(c|h)$'-or$relative-match'^third_party/notices/[^/]+\.txt$'){$allow=$true}
 if(-not$allow){continue}
 if(($file.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Reparse points are not release payloads'}
 if($file.Length-gt5MB -or $relative-match'(?i)\.(iwd|wav|mp3|etl|exe)$'-or$relative-match'(^|/)(cache|logs|sessions|build)/'){throw "Unexpected payload: $relative"}
 $files.Add([pscustomobject]@{Path=$file.FullName;Relative=$relative})
}
foreach($required in $rootFiles){if(-not($files.Relative-contains$required)){throw "Missing required release file: $required"}}
$checks=@()
foreach($file in $files|Sort-Object Relative){$checks+=((Get-FileHash -LiteralPath $file.Path -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+$file.Relative)}
$sum=Join-Path $root 'SHA256SUMS.txt'
[IO.File]::WriteAllLines($sum,$checks,[Text.Encoding]::ASCII)
$files.Add([pscustomobject]@{Path=$sum;Relative='SHA256SUMS.txt'})
$out=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $out -Force|Out-Null
$name='MW3StutteringFix-'+$m.Version+'-x64'
$zipPath=Join-Path $out ($name+'.zip')
if(Test-Path -LiteralPath $zipPath){throw 'Release ZIP exists; choose another output directory or version'}
$zip=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Create)
try{foreach($file in $files|Sort-Object Relative){
 $entry=$zip.CreateEntry($name+'/'+$file.Relative,[IO.Compression.CompressionLevel]::Optimal)
 $input=[IO.File]::OpenRead($file.Path);$output=$entry.Open()
 try{$input.CopyTo($output)}finally{$input.Dispose();$output.Dispose()}
}}finally{$zip.Dispose()}
$hash=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(($zipPath+'.sha256'),($hash+'  '+[IO.Path]::GetFileName($zipPath)+[Environment]::NewLine),[Text.Encoding]::ASCII)
[pscustomobject]@{Zip=$zipPath;Bytes=(Get-Item -LiteralPath $zipPath).Length;Files=$files.Count;SHA256=$hash;GameAssetsIncluded=$false}|Format-List
