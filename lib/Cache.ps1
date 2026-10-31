Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Get-NameHash([string]$Name) {
 [uint32]$hash=2166136261
 foreach($b in [Text.Encoding]::ASCII.GetBytes($Name.ToLowerInvariant().Replace('\','/'))){$hash=[uint32](([uint64]($hash-bxor$b)*16777619)-band[uint64]4294967295)}
 return $hash
}
function Convert-HexBytes([string]$Hex) {
 if($Hex-notmatch'^[A-Fa-f0-9]{64}$'){throw 'Invalid SHA256 value.'}
 $b=New-Object byte[] 32
 for($i=0;$i-lt32;$i++){$b[$i]=[Convert]::ToByte($Hex.Substring($i*2,2),16)}
 return ,$b
}
function Get-AudioInventory([string]$GamePath) {
 $main=Join-Path $GamePath 'main'
 $all=[Collections.Generic.List[object]]::new()
 $archives=@(Get-ChildItem -LiteralPath $main -File -Filter 'iw_*.iwd'|Sort-Object Name)
 if(-not$archives){throw 'No original iw_*.iwd archives found.'}
 foreach($file in $archives){
  $z=[IO.Compression.ZipFile]::OpenRead($file.FullName)
  try {foreach($e in $z.Entries){
   $name=$e.FullName.Replace('\','/')
   if($name-match'(?i)^sound/[A-Za-z0-9_/ .-]+\.(wav|mp3)$' -and $name.Length-lt260 -and $e.Length-gt0 -and $e.Length-le64MB -and $name-notmatch'(^|/)\.\.?(/|$)'){
    $all.Add([pscustomobject]@{Archive=$file.FullName;OriginalName=$e.FullName;Name=$name.ToLowerInvariant();Bytes=$e.Length})
   }
  }}finally{$z.Dispose()}
 }
 $blocked=@{}
 foreach($g in $all|Group-Object Name){if($g.Count-gt1){$blocked[$g.Name]=$true}}
 $known=@{};foreach($a in $all){$known[$a.Name]=$true}
 foreach($file in Get-ChildItem -LiteralPath $main -File -Filter 'localized_*.iwd'){
  $z=[IO.Compression.ZipFile]::OpenRead($file.FullName)
  try {foreach($e in $z.Entries){$name=$e.FullName.Replace('\','/').ToLowerInvariant();if($known.ContainsKey($name)){$blocked[$name]=$true}}}finally{$z.Dispose()}
 }
 $selected=@($all|Where-Object {-not$blocked.ContainsKey($_.Name)})
 if($selected.Count-lt1 -or $selected.Count-gt20000){throw 'Unsupported audio inventory size.'}
 return [pscustomobject]@{Assets=$selected;ExcludedPaths=@($blocked.Keys)}
}
function New-AudioCache([string]$GamePath,[string]$CachePath,[object]$Inventory) {
 $CachePath=[IO.Path]::GetFullPath($CachePath).TrimEnd('\')
 if($CachePath-notmatch'^[A-Za-z]:\\' -or $CachePath.Length-lt4 -or $CachePath.Length-gt180){throw 'Use a short local cache directory path (up to 180 characters), not a drive root or network share.'}
 if(Test-Path -LiteralPath (Join-Path $CachePath 'cache-manifest.json')){return (Test-AudioCache $GamePath $CachePath)}
 New-Item -ItemType Directory -Path $CachePath -Force|Out-Null
 $owner=Join-Path $CachePath 'CACHE-OWNER.txt'
 if(Test-Path -LiteralPath $owner){if((Get-Content -LiteralPath $owner -Raw).Trim()-ne$script:ProductId){throw 'Cache folder belongs to another application.'}}
 $unknown=@(Get-ChildItem -LiteralPath $CachePath -Force|Where-Object {$_.Name-notin@('CACHE-OWNER.txt','logs')})
 if($unknown.Count){throw 'Cache directory is not empty or contains an incomplete cache. Choose an empty directory.'}
 [IO.File]::WriteAllText($owner,$script:ProductId,[Text.Encoding]::ASCII)
 $sum=65536L+($Inventory.Assets|Measure-Object Bytes -Sum).Sum
 if($sum-gt32GB){throw 'Cache would exceed the supported 32 GiB limit.'}
 $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($CachePath))
 if($drive.AvailableFreeSpace-lt($sum+64MB)){throw 'Not enough free space for the generated audio cache.'}
 $stage=Join-Path $CachePath ('.building-'+[guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $stage|Out-Null
 $blob=Join-Path $stage 'audio.bin'
 $assets=[Collections.Generic.List[object]]::new()
 $sourceHashes=[Collections.Generic.List[object]]::new()
 $buffer=New-Object byte[] 1048576
 try {
  $out=[IO.FileStream]::new($blob,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try {
   $out.Write((New-Object byte[] 65536),0,65536)
   foreach($group in $Inventory.Assets|Group-Object Archive){
    Write-Host ("Reading "+[IO.Path]::GetFileName($group.Name)+" ("+$group.Count+" sound files)")
    $sourceHashes.Add([pscustomobject]@{Name=[IO.Path]::GetFileName($group.Name);SHA256=(Get-Sha256 $group.Name)})
    $zip=[IO.Compression.ZipFile]::OpenRead($group.Name)
    try {foreach($a in $group.Group){
     $entry=$zip.GetEntry($a.OriginalName);if(-not$entry){throw 'Source ZIP entry disappeared.'}
     $offset=$out.Position;$length=0L
     $h=[Security.Cryptography.SHA256]::Create();$input=$entry.Open()
     try {
      while(($n=$input.Read($buffer,0,$buffer.Length))-gt0){$out.Write($buffer,0,$n);[void]$h.TransformBlock($buffer,0,$n,$buffer,0);$length+=$n}
      [void]$h.TransformFinalBlock((New-Object byte[] 0),0,0);$sha=Get-Hex $h.Hash
     }finally{$input.Dispose();$h.Dispose()}
     if($length-ne[long]$a.Bytes){throw 'Source audio length mismatch.'}
     $assets.Add([pscustomobject]@{Name=$a.Name;Hash=(Get-NameHash $a.Name);Offset=$offset;Bytes=$length;SHA256=$sha})
    }}finally{$zip.Dispose()}
   }
   $total=$out.Position
   $header=New-Object byte[] 65536
   [Array]::Copy([Text.Encoding]::ASCII.GetBytes('MW3SND01'),0,$header,0,8)
   [Array]::Copy([BitConverter]::GetBytes([uint32]$assets.Count),0,$header,8,4)
   [Array]::Copy([BitConverter]::GetBytes([uint64]$total),0,$header,16,8)
   $out.Position=0;$out.Write($header,0,$header.Length);$out.Flush($true)
  }finally{$out.Dispose()}
  Write-Host 'Verifying generated audio slices.'
  $input=[IO.File]::OpenRead($blob)
  try {foreach($a in $assets){
   $input.Position=$a.Offset;$left=[long]$a.Bytes;$h=[Security.Cryptography.SHA256]::Create()
   try {
    while($left-gt0){$n=$input.Read($buffer,0,[int][Math]::Min($left,$buffer.Length));if($n-eq0){throw 'Truncated generated cache.'};[void]$h.TransformBlock($buffer,0,$n,$buffer,0);$left-=$n}
    [void]$h.TransformFinalBlock((New-Object byte[] 0),0,0)
    if((Get-Hex $h.Hash)-ne$a.SHA256){throw 'Generated slice differs from the original audio.'}
   }finally{$h.Dispose()}
  }}finally{$input.Dispose()}
  $blobSHA=Get-Sha256 $blob;$headerSHA=Get-ByteHash $header
  $indexPath=Join-Path $stage 'index.bin';$writer=[IO.BinaryWriter]::new([IO.File]::Create($indexPath))
  try {
   $writer.Write([Text.Encoding]::ASCII.GetBytes('MW3IDX01'));$writer.Write([uint32]1);$writer.Write([uint32]$assets.Count);$writer.Write([uint64]$total)
   $writer.Write((Convert-HexBytes $blobSHA));$writer.Write((Convert-HexBytes $headerSHA));$writer.Write([uint64]0)
   foreach($a in $assets|Sort-Object Hash,Name){
    $nameBytes=New-Object byte[] 260;$ascii=[Text.Encoding]::ASCII.GetBytes($a.Name);[Array]::Copy($ascii,0,$nameBytes,0,$ascii.Length)
    $writer.Write($nameBytes);$writer.Write([uint32]$a.Hash);$writer.Write([uint64]$a.Offset);$writer.Write([uint32]$a.Bytes);$writer.Write((Convert-HexBytes $a.SHA256));$writer.Write([uint32]0)
   }
  }finally{$writer.Dispose()}
  $manifest=[ordered]@{ProductId=$script:ProductId;Schema=1;Resources=$assets.Count;BlobFile='audio.bin';BlobBytes=$total;BlobSHA256=$blobSHA;IndexFile='index.bin';IndexBytes=(Get-Item -LiteralPath $indexPath).Length;IndexSHA256=(Get-Sha256 $indexPath);Archives=@($sourceHashes);ExcludedPaths=$Inventory.ExcludedPaths;CreatedUTC=[DateTime]::UtcNow.ToString('o')}
  $manifest|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $stage 'cache-manifest.json') -Encoding UTF8
  $assets|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $stage 'resource-hashes.json') -Encoding UTF8
  foreach($name in @('audio.bin','index.bin','resource-hashes.json','cache-manifest.json')){[IO.File]::Move((Join-Path $stage $name),(Join-Path $CachePath $name))}
  return (Get-CacheManifest $CachePath)
 } finally {
  # Only unlink known files in the exact freshly created staging directory.
  if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($stage))-eq[IO.Path]::GetFullPath($CachePath) -and (Test-Path -LiteralPath $stage)) {
   foreach($name in @('audio.bin','index.bin','resource-hashes.json','cache-manifest.json')){$p=Join-Path $stage $name;if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p}}
   if(@(Get-ChildItem -LiteralPath $stage -Force).Count-eq0){Remove-Item -LiteralPath $stage}
  }
 }
}
