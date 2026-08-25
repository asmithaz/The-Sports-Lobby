<#
.SYNOPSIS
  Refreshes `golfers.fedex_rank_current` for FedEx Cup Playoffs Fantasy Golf.

.DESCRIPTION
  Reads a CSV of (name, fedex_rank_current) and patches just that column
  on the matching `golfers` row (matched by exact name), via the Supabase
  REST API. Does NOT touch `fedex_rank`/`tier` - those stay frozen at their
  preseason draft value forever (see golf/fedex-playoffs/schema.sql).

  Source the name/rank list from pgatour.com/fedexcup, "Official" tab,
  "This Week Rank" column - re-run this before each playoff event
  (St. Jude -> BMW -> TOUR Championship) so the dashboard's "FEC Rk"
  column reflects the standings as they were entering that event.

.PARAMETER CsvPath
  Path to the CSV file. Required columns: name, fedex_rank_current.

.EXAMPLE
  $env:SUPABASE_URL = "https://rjtlolzdwmrhctdatekj.supabase.co"
  $env:SUPABASE_SERVICE_ROLE_KEY = "<service role key from Project Settings > API>"
  .\Update-CurrentFedexRank.ps1 -CsvPath .\fedex-rank-current-2026-bmw.csv
#>

param(
  [Parameter(Mandatory = $true)]
  [string]$CsvPath
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

$existing = Invoke-RestMethod -Uri "$SupabaseUrl/rest/v1/golfers?select=id,name" -Headers @{
  apikey        = $ServiceRoleKey
  Authorization = "Bearer $ServiceRoleKey"
} -UserAgent "The-Sports-Lobby-Update-CurrentFedexRank/1.0"
$idByName = @{}
foreach ($g in $existing) { $idByName[$g.name] = $g.id }

$updated = 0
$missing = @()

foreach ($row in $rows) {
  $name = $row.name.Trim()
  $rankCurrent = [int]$row.fedex_rank_current

  $golferId = $idByName[$name]
  if (-not $golferId) {
    $missing += $name
    continue
  }

  $body = @{ fedex_rank_current = $rankCurrent } | ConvertTo-Json
  $headers = @{
    apikey        = $ServiceRoleKey
    Authorization = "Bearer $ServiceRoleKey"
    "Content-Type" = "application/json"
  }

  try {
    Invoke-RestMethod -Method Patch -Uri "$SupabaseUrl/rest/v1/golfers?id=eq.$golferId" `
      -Headers $headers -Body $body -UserAgent "The-Sports-Lobby-Update-CurrentFedexRank/1.0" -ErrorAction Stop | Out-Null
    $updated++
  } catch {
    Write-Warning "Failed to update '$name': $($_.Exception.Message)"
  }
}

Write-Host "Updated fedex_rank_current for $updated golfers."
if ($missing.Count -gt 0) {
  Write-Host "No matching golfer row for (check name spelling against the golfers table):"
  $missing | ForEach-Object { Write-Host "  - $_" }
}
