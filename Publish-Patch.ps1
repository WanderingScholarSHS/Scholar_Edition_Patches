<#
    Publish-Patch.ps1
    Builds v<Version>\scholar_patches.zip and v<Version>\manifest.json from src\scholar_patches.
    The tp2 is the single source of truth:
      id          = DESIGNATED number
      title       = BEGIN ~title~
      description = the // comment line(s) directly above BEGIN
      requires    = REQUIRE_PREDICATE MOD_IS_INSTALLED ~mod.tp2~ ~n~ inside the component
      date        = kept from the existing manifest, today's date for new patches
    Add "// @hidden" to a component's comments to keep it in the tp2 but leave it out of the manifest.

    Usage:  .\Publish-Patch.ps1          (version taken from the tp2 VERSION, e.g. v1.2.0-p2 -> 1.2.0)
            .\Publish-Patch.ps1 1.2.0
#>
param([string]$Version)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$ModName = 'scholar_patches'
$src     = Join-Path $PSScriptRoot "src\$ModName"
$tp2     = Join-Path $src "$ModName.tp2"
if (-not (Test-Path -LiteralPath $tp2)) { throw "tp2 not found: $tp2" }
$lines = [System.IO.File]::ReadAllLines($tp2)

# ---------- Version ----------
$tp2Version = ''
foreach ($l in $lines) { if ($l -match '^\s*VERSION\s+~(?<v>[^~]*)~') { $tp2Version = $Matches.v; break } }
$fromTp2 = if ($tp2Version -match '^v?(?<v>\d+(?:\.\d+)+)') { $Matches.v } else { '' }
if (-not $Version) {
    if (-not $fromTp2) { throw "Could not read a version from VERSION ~$tp2Version~. Run e.g.: .\Publish-Patch.ps1 1.2.0" }
    $Version = $fromTp2
} elseif ($fromTp2 -and $fromTp2 -ne $Version) {
    throw "The tp2 says VERSION ~$tp2Version~ but you asked to publish v$Version."
}

$out = Join-Path $PSScriptRoot "v$Version"
$zip = Join-Path $out "$ModName.zip"
$man = Join-Path $out 'manifest.json'
[void][System.IO.Directory]::CreateDirectory($out)

# ---------- Parse components ----------
$components = New-Object System.Collections.Generic.List[object]
$current    = $null
for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ($l -match '^\s*BEGIN\s+~(?<title>[^~]+)~') {
        $title = $Matches.title.Trim()
        # Comment block directly above BEGIN (stops at a blank or non-comment line)
        $notes = @()
        for ($j = $i - 1; $j -ge 0 -and $lines[$j] -match '^\s*//(?<c>.*)$'; $j--) {
            $notes = @($Matches.c.Trim()) + $notes
        }
        $current = [pscustomobject]@{
            Title       = $title
            Line        = $i + 1
            Hidden      = [bool]($notes | Where-Object { $_ -ieq '@hidden' })
            Description = (@($notes | Where-Object { $_ -and -not $_.StartsWith('@') }) -join "`n")
            Body        = New-Object System.Text.StringBuilder
        }
        $components.Add($current)
    }
    # Comments are stripped so text in them can't be mistaken for DESIGNATED / REQUIRE_PREDICATE
    if ($current) { [void]$current.Body.AppendLine(($l -replace '//.*$', '')) }
}
if ($components.Count -eq 0) { throw "No BEGIN components found in $tp2" }

$patches = foreach ($c in $components) {
    $body = $c.Body.ToString()
    if ($body -notmatch '\bDESIGNATED\s+(?<id>\d+)') { throw "Component '$($c.Title)' (tp2 line $($c.Line)) has no DESIGNATED number." }
    $id  = [int]$Matches.id
    $req = @([regex]::Matches($body, 'REQUIRE_PREDICATE\s+MOD_IS_INSTALLED\s+~(?<tp2>[^~]+)~\s+~?(?<c>\d+)~?') |
             ForEach-Object { "$($_.Groups['tp2'].Value)#$($_.Groups['c'].Value)" } | Sort-Object -Unique)
    if (-not $c.Description) { Write-Warning "Patch $id has no // description comment above its BEGIN line." }
    [pscustomobject]@{ Id = $id; Title = $c.Title; Description = $c.Description; Requires = $req; Hidden = $c.Hidden }
}
$patches = @($patches | Sort-Object Id)
$dupes   = @($patches | Group-Object Id | Where-Object Count -gt 1)
if ($dupes) { throw "Duplicate DESIGNATED number(s): $(($dupes | ForEach-Object Name) -join ', ')" }

# ---------- Existing manifest: keep dates, block deleted components ----------
$oldDates = @{}
if (Test-Path -LiteralPath $man) {
    try {
        $old = Get-Content -LiteralPath $man -Raw | ConvertFrom-Json
        foreach ($p in @($old.patches | Where-Object { $_ })) { $oldDates[[int]$p.id] = "$($p.date)" }
    } catch { Write-Warning "Existing manifest could not be read - all patches will get today's date. ($($_.Exception.Message))" }
}
$tp2Ids  = @($patches | ForEach-Object Id)
$deleted = @($oldDates.Keys | Where-Object { $tp2Ids -notcontains $_ })
if ($deleted) {
    throw "Patch(es) $($deleted -join ', ') were published but are no longer in the tp2. Never delete a released component - mark it // @hidden instead."
}
$today = Get-Date -Format 'yyyy-MM-dd'

# ---------- Build the zip ----------
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
$archive = [System.IO.Compression.ZipFile]::Open($zip, 'Create')
try {
    foreach ($f in Get-ChildItem -LiteralPath $src -Recurse -File) {
        $rel = $f.FullName.Substring($src.Length + 1)
        if ($rel -match '^(?i)backup\\' -or $f.Extension -match '(?i)^\.(exe|dll|bat|cmd|ps1|vbs|js|debug)$') { continue }
        $entry = "$ModName/" + $rel.Replace('\', '/')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $entry, 'Optimal')
    }
} finally { $archive.Dispose() }
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash

# ---------- Write the manifest ----------
function J([string]$s) {
    '"' + $s.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n').Replace("`t", '\t') + '"'
}
$visible = @($patches | Where-Object { -not $_.Hidden })
$o = New-Object System.Collections.Generic.List[string]
$o.Add('{')
$o.Add("  `"version`": $(J $Version),")
$o.Add("  `"zip`": $(J "$ModName.zip"),")
$o.Add("  `"sha256`": $(J $hash),")
$o.Add('  "patches": [')
for ($i = 0; $i -lt $visible.Count; $i++) {
    $p    = $visible[$i]
    $date = if ($oldDates.ContainsKey($p.Id) -and $oldDates[$p.Id]) { $oldDates[$p.Id] } else { $today }
    $req  = if ($p.Requires.Count) { '[' + (($p.Requires | ForEach-Object { J $_ }) -join ', ') + ']' } else { '[]' }
    $o.Add('    {')
    $o.Add("      `"id`": $($p.Id),")
    $o.Add("      `"title`": $(J $p.Title),")
    $o.Add("      `"date`": $(J $date),")
    $o.Add("      `"description`": $(J $p.Description),")
    $o.Add("      `"requires`": $req")
    $o.Add($(if ($i -lt $visible.Count - 1) { '    },' } else { '    }' }))
}
$o.Add('  ]')
$o.Add('}')
$json = ($o -join "`r`n") + "`r`n"
[void]($json | ConvertFrom-Json)    # sanity check - throws if the output isn't valid JSON
[System.IO.File]::WriteAllText($man, $json, (New-Object System.Text.UTF8Encoding($false)))

# ---------- Summary ----------
Write-Host ''
Write-Host "Published v$Version  (tp2 VERSION ~$tp2Version~)" -ForegroundColor Green
Write-Host "  $zip"
Write-Host "  $man"
Write-Host "  sha256 $hash"
Write-Host ''
foreach ($p in $patches) {
    $tag   = if ($p.Hidden) { 'HIDDEN' } elseif (-not $oldDates.ContainsKey($p.Id)) { 'NEW' } else { '' }
    $color = switch ($tag) { 'NEW' { 'Cyan' } 'HIDDEN' { 'DarkGray' } default { 'Gray' } }
    $req   = if ($p.Requires.Count) { "   requires: $($p.Requires -join ', ')" } else { '' }
    Write-Host ('  {0,-6} #{1,-4} {2}{3}' -f $tag, $p.Id, $p.Title, $req) -ForegroundColor $color
}
Write-Host ''
Write-Host 'Next: git add -A; git commit -m "..."; git push' -ForegroundColor DarkGray