# Liest Spielerdaten per FTP (nur lesend) und schreibt data/stats.json.
# Zugangsdaten liegen ausserhalb dieses Repos und werden nie ausgegeben.
param([switch]$Push)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$mc    = 'C:\Claude\minecraft-server'
$repo  = Split-Path -Parent $PSScriptRoot
$netrc = "$mc\ftp-zugang.netrc"
$url   = (Get-Content "$mc\ftp-server.txt" -Raw).Trim()
$tmp   = "$mc\arbeit\stats"
$enc   = New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force $tmp, "$repo\data\avatars" | Out-Null

function Ftp($remote, $out) {
  & curl.exe -s -S --connect-timeout 20 --max-time 120 --netrc-file $netrc -o $out "$url$remote"
  return ($LASTEXITCODE -eq 0)
}
function FtpList($remote) {
  $o = & curl.exe -s -S --connect-timeout 20 --max-time 60 --netrc-file $netrc "$url$remote"
  foreach ($l in $o) { if ($l -and $l -notmatch '^d') { ($l -split '\s+', 9)[8] } }
}
function Gunzip($path) {
  $fs = [IO.File]::OpenRead($path)
  try {
    $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress)
    $ms = New-Object IO.MemoryStream
    $gz.CopyTo($ms); $gz.Close()
    return ,$ms.ToArray()
  } finally { $fs.Close() }
}

# --- NBT lesen ---
function NbtN($n) { $a = New-Object byte[] $n; [Array]::Copy($script:B, $script:P, $a, 0, $n); [Array]::Reverse($a); $script:P += $n; return ,$a }
function NbtI { return [BitConverter]::ToInt32((NbtN 4), 0) }
function NbtS {
  $len = [BitConverter]::ToUInt16((NbtN 2), 0)
  $s = [Text.Encoding]::UTF8.GetString($script:B, $script:P, $len)
  $script:P += $len
  return $s
}
function NbtP($t) {
  if ($t -eq 1)  { $v = [int]$script:B[$script:P]; $script:P++; if ($v -gt 127) { $v -= 256 }; return $v }
  if ($t -eq 2)  { return [int][BitConverter]::ToInt16((NbtN 2), 0) }
  if ($t -eq 3)  { return (NbtI) }
  if ($t -eq 4 -or $t -eq 6) { $script:P += 8; return 0 }
  if ($t -eq 5)  { $script:P += 4; return 0 }
  if ($t -eq 7)  { $n = NbtI; $script:P += $n; return 0 }
  if ($t -eq 8)  { return (NbtS) }
  if ($t -eq 9) {
    $et = [int]$script:B[$script:P]; $script:P++
    $n = NbtI
    $arr = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $n; $i++) { [void]$arr.Add((NbtP $et)) }
    return ,$arr
  }
  if ($t -eq 10) {
    $h = @{}
    while ($true) {
      $c = [int]$script:B[$script:P]; $script:P++
      if ($c -eq 0) { return $h }
      $name = NbtS
      $h[$name] = NbtP $c
    }
  }
  if ($t -eq 11) { $n = NbtI; $script:P += 4 * $n; return 0 }
  if ($t -eq 12) { $n = NbtI; $script:P += 8 * $n; return 0 }
  throw "Unbekannter NBT-Typ $t"
}
function ReadNbt($bytes) { $script:B = $bytes; $script:P = 0; $script:P++; [void](NbtS); return (NbtP 10) }

# Zaehlt Diamanten, auch in Shulker-Kisten und Buendeln. Diamantblock = 9.
function CountDia($n) {
  $s = 0
  if ($n -is [hashtable]) {
    if ($n.ContainsKey('id') -and $n['id'] -is [string]) {
      $c = 1; if ($n.ContainsKey('count')) { $c = [int]$n['count'] }
      if ($n['id'] -eq 'minecraft:diamond') { $s += $c }
      if ($n['id'] -eq 'minecraft:diamond_block') { $s += 9 * $c }
    }
    foreach ($v in $n.Values) { if ($v -is [hashtable] -or $v -is [System.Collections.ArrayList]) { $s += (CountDia $v) } }
  } elseif ($n -is [System.Collections.ArrayList]) {
    foreach ($v in $n) { if ($v -is [hashtable] -or $v -is [System.Collections.ArrayList]) { $s += (CountDia $v) } }
  }
  return [int]$s
}

# --- Welt und Spieler ---
if (-not (Ftp 'server.properties' "$tmp\sp")) { throw 'server.properties nicht lesbar' }
$level = ((Get-Content "$tmp\sp" | Where-Object { $_ -match '^level-name=' }) -replace '^level-name=', '').Trim()
[void](Ftp 'usercache.json' "$tmp\uc.json")
$names = @{}
foreach ($e in (Get-Content "$tmp\uc.json" -Raw | ConvertFrom-Json)) { foreach ($x in $e) { $names[$x.uuid] = $x.name } }

function StatCat($st, $c) { $p = $st.PSObject.Properties["minecraft:$c"]; if ($p) { return $p.Value } else { return $null } }
function Val($o, $k) { if ($null -eq $o) { return 0 }; $p = $o.PSObject.Properties["minecraft:$k"]; if ($p) { return [double]$p.Value } else { return 0 } }
function Map($o) {
  $r = @()
  if ($null -ne $o) { foreach ($p in $o.PSObject.Properties) { $r += [pscustomobject]@{ id = ($p.Name -replace '^minecraft:', ''); n = [int]$p.Value } } }
  return ,@($r | Sort-Object n -Descending)
}

$players = @()
foreach ($file in (FtpList "$level/stats/")) {
  if ($file -notmatch '^([0-9a-f-]{36})\.json$') { continue }
  $id = $Matches[1]
  if (-not (Ftp "$level/stats/$file" "$tmp\$file")) { continue }
  $st = (Get-Content "$tmp\$file" -Raw -Encoding UTF8 | ConvertFrom-Json).stats
  $cu = StatCat $st 'custom'; $mi = StatCat $st 'mined'
  $minedAll = 0
  if ($null -ne $mi) { foreach ($p in $mi.PSObject.Properties) { $minedAll += [double]$p.Value } }
  $inv = 0; $ender = 0
  if (Ftp "$level/playerdata/$id.dat" "$tmp\$id.dat") {
    $root = ReadNbt (Gunzip "$tmp\$id.dat")
    if ($root.ContainsKey('Inventory'))  { $inv   = CountDia $root['Inventory'] }
    if ($root.ContainsKey('EnderItems')) { $ender = CountDia $root['EnderItems'] }
  }
  $name = if ($names.ContainsKey($id)) { $names[$id] } else { $id.Substring(0, 8) }
  foreach ($kind in 'avatar', 'body') {
    $img = "$repo\data\avatars\$id.$kind.png"
    if (-not (Test-Path $img) -or ((Get-Date) - (Get-Item $img).LastWriteTime).TotalHours -gt 24) {
      $size = if ($kind -eq 'avatar') { 96 } else { 240 }
      & curl.exe -s -S -f -L --max-time 30 -A 'elmo-stats/1.0' -o "$img.neu" "https://mc-heads.net/$kind/$id/$size"
      if ($LASTEXITCODE -eq 0 -and (Test-Path "$img.neu")) { Move-Item -LiteralPath "$img.neu" $img -Force } elseif (Test-Path "$img.neu") { Remove-Item -LiteralPath "$img.neu" -Force }
    }
  }
  $players += [pscustomobject]@{
    uuid = $id; name = $name
    deaths = [int](Val $cu 'deaths'); playerKills = [int](Val $cu 'player_kills'); mobKills = [int](Val $cu 'mob_kills')
    hours = [Math]::Round((Val $cu 'play_time') / 72000, 1)
    damageDealt = [int]((Val $cu 'damage_dealt') / 10); damageTaken = [int]((Val $cu 'damage_taken') / 10)
    jumps = [int](Val $cu 'jump')
    elytraKm = [Math]::Round((Val $cu 'aviate_one_cm') / 100000, 1)
    walkKm = [Math]::Round(((Val $cu 'walk_one_cm') + (Val $cu 'sprint_one_cm')) / 100000, 1)
    minedAll = [int]$minedAll
    diamondOre = [int]((Val $mi 'diamond_ore') + (Val $mi 'deepslate_diamond_ore'))
    diamondBlocks = [int](Val $mi 'diamond_block')
    diamondsInv = [int]$inv; diamondsEnder = [int]$ender; diamondsOwned = [int]($inv + $ender)
    killedBy = (Map (StatCat $st 'killed_by'))
    killed = (Map (StatCat $st 'killed'))
  }
}

# --- Wer hat wen getoetet (aus den Logs, sammelt sich dauerhaft an) ---
$killFile = "$repo\data\kills.json"
$events = @{}
if (Test-Path $killFile) { foreach ($e in (Get-Content $killFile -Raw -Encoding UTF8 | ConvertFrom-Json)) { foreach ($x in $e) { $events["$($x.d)|$($x.t)|$($x.k)|$($x.v)"] = $x } } }
$known = @($names.Values)
foreach ($f in (FtpList 'logs/')) {
  if ($f -notmatch '\.log(\.gz)?$') { continue }
  $local = "$tmp\$f"
  if (-not (Ftp "logs/$f" $local)) { continue }
  $text = if ($f -like '*.gz') { [Text.Encoding]::UTF8.GetString((Gunzip $local)) } else { [IO.File]::ReadAllText($local) }
  $date = if ($f -match '^(\d{4}-\d{2}-\d{2})') { $Matches[1] } else { (Get-Date).ToString('yyyy-MM-dd') }
  foreach ($line in ($text -split "`r?`n")) {
    if ($line -notmatch '^\[(\d\d:\d\d:\d\d)\] \[Server thread/INFO\]: (.+)$') { continue }
    $time = $Matches[1]; $msg = $Matches[2]
    foreach ($v in $known) {
      if (-not $msg.StartsWith("$v ")) { continue }
      foreach ($k in $known) {
        if ($k -ceq $v) { continue }
        if ($msg -match ("\b(by|fighting|escape|escaping) " + [regex]::Escape($k) + "( using .*)?$")) {
          $events["$date|$time|$k|$v"] = [pscustomobject]@{ d = $date; t = $time; k = $k; v = $v }
        }
      }
    }
  }
}
$list = @($events.Values | Sort-Object d, t)
[IO.File]::WriteAllText($killFile, (ConvertTo-Json -InputObject $list -Depth 4), $enc)
$pairs = @($list | Group-Object k, v | ForEach-Object { [pscustomobject]@{ killer = $_.Group[0].k; victim = $_.Group[0].v; n = $_.Count } } | Sort-Object n -Descending)

$out = [ordered]@{ server = 'Elmo'; updated = (Get-Date).ToUniversalTime().ToString('o'); players = @($players); pairs = @($pairs) }
[IO.File]::WriteAllText("$repo\data\stats.json", (ConvertTo-Json -InputObject $out -Depth 8), $enc)
"Spieler: $($players.Count), PvP-Ereignisse: $($list.Count), Welt: $level"

if ($Push) {
  Push-Location $repo
  try {
    git add data
    git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) { git commit -q -m 'Stats aktualisiert'; git push -q; 'Hochgeladen.' } else { 'Keine Aenderung.' }
  } finally { Pop-Location }
}
