<#
.SYNOPSIS
  Populates the `golfers` table for FedEx Cup Playoffs Fantasy Golf.

.DESCRIPTION
  Reads a CSV of (name, fedex_rank) for the 70-man playoff field,
  looks up each golfer's ESPN athlete id via ESPN's player search API,
  and upserts rows into the `golfers` table via the Supabase REST API.

  Source the name/rank list from PGATour.com's FedEx Cup standings
  page after the Wyndham Championship sets the playoff field
  (top 70 in FedEx Cup points).

.PARAMETER CsvPath
  Path to the CSV file. Defaults to golfers-template.csv next to this script.
  Required columns: name, fedex_rank (1-70).

.EXAMPLE
  $env:SUPABASE_URL = "https://rjtlolzdwmrhctdatekj.supabase.co"
  $env:SUPABASE_SERVICE_ROLE_KEY = "<service role key from Project Settings > API>"
  .\Populate-Golfers.ps1 -CsvPath .\golfers-2026.csv
#>

param(
  [string]$CsvPath = (Join-Path $PSScriptRoot "golfers-template.csv")
)

$SupabaseUrl = $env:SUPABASE_URL
$ServiceRoleKey = $env:SUPABASE_SERVICE_ROLE_KEY

if (-not $SupabaseUrl -or -not $ServiceRoleKey) {
  Write-Error "Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY environment variables first (see script header for an example)."
  exit 1
}

if (-not (Test-Path $CsvPath)) {
  Write-Error "CSV not found: $CsvPath"
  exit 1
}

$rows = Import-Csv $CsvPath
if (-not $rows -or $rows.Count -eq 0) {
  Write-Error "No rows found in $CsvPath"
  exit 1
}

$golfers = @()

foreach ($row in $rows) {
  $name = $row.name.Trim()
  $rank = [int]$row.fedex_rank
  $slug = ($name.ToLowerInvariant() -replace "[^a-z0-9]+", "-").Trim('-')

  $espnId = $null
  try {
    $searchUrl = "https://site.web.api.espn.com/apis/common/v3/search?query=$([uri]::EscapeDataString($name))&type=player&sport=golf&league=pga"
    $resp = Invoke-RestMethod -Uri $searchUrl -ErrorAction Stop
    $match = $resp.items | Where-Object { $_.sport -eq 'golf' } | Select-Object -First 1
    if ($match) { $espnId = $match.id }
  } catch {
    Write-Warning "ESPN lookup failed for '$name': $_"
  }

  if (-not $espnId) {
    Write-Warning "No ESPN id found for '$name' - inserted with espn_id = null (live scores won't sync for this golfer until fixed in the golfers table)."
  }

  $golfers += [PSCustomObject]@{
    id         = $slug
    name       = $name
    espn_id    = $espnId
    fedex_rank = $rank
  }

  Start-Sleep -Milliseconds 300
}

$json = $golfers | ConvertTo-Json -Depth 5

$headers = @{
  apikey        = $ServiceRoleKey
  Authorization = "Bearer $ServiceRoleKey"
  "Content-Type" = "application/json"
  Prefer        = "resolution=merge-duplicates"
}

try {
  Invoke-RestMethod -Uri "$SupabaseUrl/rest/v1/golfers" -Method Post -Headers $headers -Body $json -UserAgent "The-Sports-Lobby-Populate-Golfers/1.0" -ErrorAction Stop | Out-Null
} catch {
  $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
  Write-Error $reader.ReadToEnd()
  exit 1
}

Write-Host "Upserted $($golfers.Count) golfers into the golfers table."
$missing = $golfers | Where-Object { -not $_.espn_id }
if ($missing.Count -gt 0) {
  Write-Host "Golfers missing an ESPN id (fix manually in the golfers table):"
  $missing | ForEach-Object { Write-Host "  - $($_.name)" }
}
