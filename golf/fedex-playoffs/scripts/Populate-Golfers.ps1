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
    season     = (Get-Date).Year
  }

  Start-Sleep -Milliseconds 300
}

# ESPN's player search can mis-match two different golfers to the same
# athlete id (common surnames like "Kim" or "Fitzpatrick" are ambiguous).
# golfers.espn_id is UNIQUE, so sending duplicates would fail the whole
# upsert with a 409 - clear them here instead and let the warning below
# flag it for manual fixing.
$dupeEspnIds = $golfers | Where-Object { $_.espn_id } | Group-Object espn_id | Where-Object { $_.Count -gt 1 }
foreach ($grp in $dupeEspnIds) {
  $names = ($grp.Group | ForEach-Object { $_.name }) -join ", "
  Write-Warning "ESPN id $($grp.Name) matched multiple golfers ($names) - clearing espn_id for all of them, fix manually in the golfers table."
  foreach ($g in $grp.Group) { $g.espn_id = $null }
}

# A previous season's golfer could already occupy this espn_id under a
# different `id` slug than the one we just generated for the same
# person - on_conflict=id below wouldn't match that row, so Postgres
# would try a fresh insert and collide on the espn_id UNIQUE constraint.
# Clear those too rather than fail the whole batch.
$existing = Invoke-RestMethod -Uri "$SupabaseUrl/rest/v1/golfers?select=id,espn_id" -Headers @{
  apikey        = $ServiceRoleKey
  Authorization = "Bearer $ServiceRoleKey"
} -UserAgent "The-Sports-Lobby-Populate-Golfers/1.0"
$existingIdByEspnId = @{}
foreach ($e in $existing) {
  if ($e.espn_id) { $existingIdByEspnId[[string]$e.espn_id] = $e.id }
}
foreach ($g in $golfers) {
  if ($g.espn_id -and $existingIdByEspnId.ContainsKey([string]$g.espn_id) -and $existingIdByEspnId[[string]$g.espn_id] -ne $g.id) {
    Write-Warning "ESPN id $($g.espn_id) for '$($g.name)' already belongs to existing golfer id '$($existingIdByEspnId[[string]$g.espn_id])' - clearing espn_id, fix manually in the golfers table."
    $g.espn_id = $null
  }
}

$json = $golfers | ConvertTo-Json -Depth 5

# Invoke-RestMethod's error handling is unreliable for reading response
# bodies on non-2xx status in Windows PowerShell 5.1 (the stream is often
# already consumed by the time the catch block runs), so use HttpClient
# directly to guarantee we see the real Supabase/PostgREST error message.
Add-Type -AssemblyName System.Net.Http
$httpClient = [System.Net.Http.HttpClient]::new()
$request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, "$SupabaseUrl/rest/v1/golfers?on_conflict=id")
$request.Headers.Add("apikey", $ServiceRoleKey)
$request.Headers.Add("Authorization", "Bearer $ServiceRoleKey")
$request.Headers.Add("Prefer", "resolution=merge-duplicates")
$request.Headers.UserAgent.ParseAdd("The-Sports-Lobby-Populate-Golfers/1.0")
$request.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, "application/json")

$response = $httpClient.SendAsync($request).GetAwaiter().GetResult()
$responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

if (-not $response.IsSuccessStatusCode) {
  Write-Error "Request failed: $($response.StatusCode) $($response.ReasonPhrase)"
  Write-Error "Response body: $responseBody"
  exit 1
}

Write-Host "Upserted $($golfers.Count) golfers into the golfers table."
$missing = $golfers | Where-Object { -not $_.espn_id }
if ($missing.Count -gt 0) {
  Write-Host "Golfers missing an ESPN id (fix manually in the golfers table):"
  $missing | ForEach-Object { Write-Host "  - $($_.name)" }
}
