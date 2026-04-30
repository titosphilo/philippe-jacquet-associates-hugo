$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$organigramPath = Join-Path $root "MASTER_COMPLETE_ORGANIGRAM.txt"
$contentRoot = Join-Path $root "content\en"
$reportPath = Join-Path $root "organigram-generation-report.txt"

if (-not (Test-Path -LiteralPath $organigramPath)) {
  throw "Missing organigram file: $organigramPath"
}

New-Item -ItemType Directory -Force -Path $contentRoot | Out-Null

$lines = Get-Content -LiteralPath $organigramPath
$records = New-Object System.Collections.Generic.List[object]
$current = $null

foreach ($line in $lines) {
  if ($line -match '^\s*\[\d+\]\s+(?!PARENT PAGE\s*$)(.+?)\s*$') {
    $current = @{
      Title = $Matches[1].Trim()
      Url = $null
      Slug = $null
    }
    continue
  }

  if ($line -match '^\s*Title:\s*(.+?)\s*$') {
    $current = @{
      Title = $Matches[1].Trim()
      Url = $null
      Slug = $null
    }
    continue
  }

  if ($line -match '^\s*URL:\s*(.+?)\s*$') {
    if ($current) {
      $current.Url = $Matches[1].Trim()
    }
    continue
  }

  if ($line -match '^\s*Slug:\s*(.+?)\s*$') {
    if ($current) {
      $current.Slug = $Matches[1].Trim()
      if ($current.Title -and $current.Url -and $current.Slug) {
        $records.Add([pscustomobject]$current)
        $current = $null
      }
    }
    continue
  }
}

function Convert-ToRelativeUrl {
  param([string]$Url)

  if ($Url -match '^https?://www\.philippejacquet\.co\.uk(?<path>/.*)$') {
    $path = $Matches['path']
    if ($path -match '^//+') {
      $path = '/' + $path.TrimStart('/')
    }
    return $path
  }

  if ($Url -match '^/') {
    return $Url
  }

  return $null
}

function Get-LayoutForUrl {
  param([string]$Url)

  $trimmed = $Url.Trim('/')
  if ($trimmed -eq '') {
    return 'index'
  }

  return 'location-service'
}

function Get-SafeFileName {
  param(
    [string]$Url,
    [string]$Slug
  )

  $path = $Url.Trim('/')
  if ($path -eq '') {
    $path = 'home'
  }

  $safe = $path -replace '[^A-Za-z0-9]+', '-'
  $safe = $safe.Trim('-').ToLowerInvariant()

  if ([string]::IsNullOrWhiteSpace($safe)) {
    $safe = ($Slug -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant()
  }

  return "$safe.md"
}

function Escape-Yaml {
  param([string]$Value)

  if ($null -eq $Value) {
    return ''
  }

  return $Value.Replace('\', '\\').Replace('"', '\"')
}

function Split-Markdown {
  param([string]$Text)

  if ($Text -match '(?s)^---\r?\n(.*?)\r?\n---\r?\n?(.*)$') {
    return [pscustomobject]@{
      FrontMatter = $Matches[1]
      Body = $Matches[2]
    }
  }

  return [pscustomobject]@{
    FrontMatter = ''
    Body = $Text
  }
}

function Read-FrontMatterMap {
  param([string]$FrontMatter)

  $map = [ordered]@{}
  foreach ($line in ($FrontMatter -split "\r?\n")) {
    if ($line -match '^([A-Za-z0-9_-]+):\s*(.*)$') {
      $key = $Matches[1]
      $value = $Matches[2].Trim()
      $map[$key] = $value
    }
  }

  return $map
}

function Format-YamlValue {
  param(
    [string]$Value,
    [bool]$Quote = $true
  )

  if (-not $Quote) {
    return $Value
  }

  return '"' + (Escape-Yaml $Value) + '"'
}

function Get-PlaceholderBody {
  param(
    [string]$Title,
    [string]$Url
  )

  return @"
## $Title

This page is reserved for the canonical SEO URL `$Url`.

### Clinical focus

Specialist psychotherapy, counselling and analytical treatment information will be developed for this page.

### Appointments

Consultations are available through Philippe Jacquet & Associates.
"@
}

$normalized = foreach ($record in $records) {
  $relativeUrl = Convert-ToRelativeUrl -Url $record.Url
  if (-not $relativeUrl) {
    continue
  }

  if (-not $relativeUrl.EndsWith('/')) {
    $relativeUrl = "$relativeUrl/"
  }

  [pscustomobject]@{
    Title = $record.Title
    SourceUrl = $record.Url
    Url = $relativeUrl
    Slug = $record.Slug
    Layout = Get-LayoutForUrl -Url $relativeUrl
  }
}

$duplicates = $normalized |
  Group-Object Url |
  Where-Object { $_.Count -gt 1 } |
  Sort-Object Name

$uniqueRecords = $normalized |
  Group-Object Url |
  ForEach-Object { $_.Group | Select-Object -First 1 } |
  Sort-Object Url

$generated = New-Object System.Collections.Generic.List[string]
$skippedExisting = New-Object System.Collections.Generic.List[string]

foreach ($record in $uniqueRecords) {
  if ($record.Url -eq '/') {
    $skippedExisting.Add($record.Url)
    continue
  }

  $fileName = Get-SafeFileName -Url $record.Url -Slug $record.Slug
  $path = Join-Path $contentRoot $fileName

  $existingBody = ''
  $map = [ordered]@{}

  if (Test-Path -LiteralPath $path) {
    $split = Split-Markdown -Text (Get-Content -LiteralPath $path -Raw)
    $map = Read-FrontMatterMap -FrontMatter $split.FrontMatter
    $existingBody = $split.Body
  }

  $map['title'] = Format-YamlValue -Value $record.Title
  $map['slug'] = Format-YamlValue -Value $record.Slug
  $map['url'] = Format-YamlValue -Value $record.Url
  $map['meta_title'] = Format-YamlValue -Value $record.Title
  if (-not $map.Contains('description') -or [string]::IsNullOrWhiteSpace(($map['description'] -replace '^["'']|["'']$', ''))) {
    $map['description'] = Format-YamlValue -Value $record.Title
  }
  $map['layout'] = Format-YamlValue -Value $record.Layout
  $map['type'] = Format-YamlValue -Value $record.Layout
  $map['draft'] = 'false'

  $orderedKeys = @('title', 'slug', 'url', 'meta_title', 'description', 'layout', 'type', 'draft')
  $frontMatterLines = New-Object System.Collections.Generic.List[string]
  foreach ($key in $orderedKeys) {
    if ($map.Contains($key)) {
      $frontMatterLines.Add("${key}: $($map[$key])")
    }
  }
  foreach ($key in $map.Keys) {
    if ($orderedKeys -notcontains $key) {
      $frontMatterLines.Add("${key}: $($map[$key])")
    }
  }

  $body = $existingBody.Trim()
  if ([string]::IsNullOrWhiteSpace($body)) {
    $body = Get-PlaceholderBody -Title $record.Title -Url $record.Url
  }

  $content = "---`r`n" + ($frontMatterLines -join "`r`n") + "`r`n---`r`n`r`n" + $body + "`r`n"
  Set-Content -LiteralPath $path -Value $content -Encoding UTF8
  $generated.Add($record.Url)
}

$allContentFiles = Get-ChildItem -Path (Join-Path $root "content") -Recurse -File -Include *.md
$contentUrls = New-Object System.Collections.Generic.HashSet[string]
foreach ($file in $allContentFiles) {
  $text = Get-Content -LiteralPath $file.FullName -Raw
  if ($text -match '(?m)^url:\s*["'']?(.*?)["'']?\s*$') {
    $url = $Matches[1].Trim().Trim('"').Trim("'")
    if (-not $url.EndsWith('/')) {
      $url = "$url/"
    }
    [void]$contentUrls.Add($url)
  }
}

$missing = foreach ($record in $uniqueRecords) {
  if (-not $contentUrls.Contains($record.Url)) {
    $record.Url
  }
}

$report = New-Object System.Collections.Generic.List[string]
$report.Add("Organigram generation report")
$report.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$report.Add("")
$report.Add("Complete records parsed: $($records.Count)")
$report.Add("Relative URL records parsed: $($normalized.Count)")
$report.Add("Unique URLs parsed: $($uniqueRecords.Count)")
$report.Add("Generated content files: $($generated.Count)")
$report.Add("Existing URLs skipped: $($skippedExisting.Count)")
$report.Add("Duplicate URL groups: $($duplicates.Count)")
$report.Add("Missing URLs after generation: $(@($missing).Count)")
$report.Add("")
$report.Add("Duplicate URLs:")
if ($duplicates.Count -eq 0) {
  $report.Add("  None")
} else {
  foreach ($duplicate in $duplicates) {
    $report.Add("  $($duplicate.Name) ($($duplicate.Count)x)")
  }
}
$report.Add("")
$report.Add("Missing URLs:")
if (@($missing).Count -eq 0) {
  $report.Add("  None")
} else {
  foreach ($url in $missing) {
    $report.Add("  $url")
  }
}

Set-Content -LiteralPath $reportPath -Value $report -Encoding UTF8

[pscustomobject]@{
  RecordsParsed = $records.Count
  RelativeUrlRecords = $normalized.Count
  UniqueUrls = $uniqueRecords.Count
  GeneratedFiles = $generated.Count
  ExistingSkipped = $skippedExisting.Count
  DuplicateGroups = $duplicates.Count
  MissingUrls = @($missing).Count
  ReportPath = $reportPath
}
