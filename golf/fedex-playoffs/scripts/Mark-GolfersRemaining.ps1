<#
.SYNOPSIS
  Marks FedEx Cup Playoffs golfers as eliminated based on a "who's still
  in" list.

.DESCRIPTION
  Reads a CSV of the golfers who ADVANCED past a cut (the field of 50
  heading into BMW, or the field of 30 heading into TOUR Championship —
  copy this straight off the PGA Tour / ESPN FedEx Cup standings page,
  it's the list they publish anyway). Any currently-active golfer for the
  season who is NOT on that list gets golfers.eliminated set to true.
  Golfers already eliminated in an earlier round are left alone, so the
  BMW-stage CSV only needs to list the 30 advancing out of the 50 who
  were still alive, not the full original 70.

  Prints the golfers about to be eliminated before writing anything, so a
  typo'd/missing name on the CSV (which would otherwise silently
  eliminate that golfer) can be caught before it commits.

.PARAMETER CsvPath
  Path to the CSV file. Required column: name (must match golfers.name
  for the season, case-insensitive).

.PARAMETER EliminatedAfterEvent
  Which cut this represents: 'st_jude' (uploading the 50 heading into
  BMW) or 'bmw' (uploading the 30 heading into TOUR Championship).

.PARAMETER Season
  Defaults to the current calendar year.

.EXAMPLE
  $env:SUPABASE_URL = "https://rjtlolzdwmrhctdatekj.supabase.co"
  $env:SUPABASE_SERVICE_ROLE_KEY = "<service role key from Project Settings > API>"
  .\Mark-GolfersRemaining.ps1 -CsvPath .\bmw-field.csv -EliminatedAfterEvent st_jude
#>

param(
  [Parameter(Mandatory = $true)]
  [string]$CsvPath,

  [Parameter(Mandatory = $true)]
  [ValidateSet('st_jude', 'bmw')]
  [string]$EliminatedAfterEvent,

  [int]$Season = (Get-Date).Year
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

$remainingNames = [System.Collections.Generic.HashSet[string]]::new()
foreach ($row in $rows) {
  $name = $row.name.Trim().ToLowerInvariant()
  if ($name) { [void]$remainingNames.Add($name) }
}

# Only golfers not already eliminated in an earlier round are in scope -
# this is what lets the BMW-stage CSV list just 30 names instead of
# re-listing the same 20 who were already cut after St. Jude.
$active = Invoke-RestMethod -Uri "$SupabaseUrl/rest/v1/golfers?select=id,name&season=eq.$Season&eliminated=eq.false" -Headers @{
  apikey        = $ServiceRoleKey
  Authorization = "Bearer $ServiceRoleKey"
} -UserAgent "The-Sports-Lobby-Mark-GolfersRemaining/1.0"

if (-not $active -or $active.Count -eq 0) {
  Write-Error "No active (non-eliminated) golfers found for season $Season - check SUPABASE_URL/Season."
  exit 1
}

$toEliminate = $active | Where-Object { -not $remainingNames.Contains($_.name.ToLowerInvariant()) }

$activeNamesLower = [System.Collections.Generic.HashSet[string]]::new()
foreach ($g in $active) { [void]$activeNamesLower.Add($g.name.ToLowerInvariant()) }
$unmatchedCsvNames = $rows | Where-Object { -not $activeNamesLower.Contains($_.name.Trim().ToLowerInvariant()) } | ForEach-Object { $_.name.Trim() }
if ($unmatchedCsvNames.Count -gt 0) {
  Write-Warning "These CSV names didn't match any currently-active golfer for season $Season (typo, already eliminated, or not in the field - not an error, just double-check them):"
  $unmatchedCsvNames | ForEach-Object { Write-Warning "  - $_" }
}

if ($toEliminate.Count -eq 0) {
  Write-Host "No golfers to eliminate - every active golfer for season $Season is on the CSV."
  exit 0
}

Write-Host "About to mark $($toEliminate.Count) golfer(s) as eliminated (after '$EliminatedAfterEvent'):"
$toEliminate | ForEach-Object { Write-Host "  - $($_.name)" }

$idList = ($toEliminate | ForEach-Object { $_.id }) -join ','
$body = @{ eliminated = $true; eliminated_after_event = $EliminatedAfterEvent } | ConvertTo-Json

# Invoke-RestMethod's error handling is unreliable for reading response
# bodies on non-2xx status in Windows PowerShell 5.1 (the stream is often
# already consumed by the time the catch block runs), so use HttpClient
# directly, same as Populate-Golfers.ps1.
Add-Type -AssemblyName System.Net.Http
$httpClient = [System.Net.Http.HttpClient]::new()
$request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Patch, "$SupabaseUrl/rest/v1/golfers?id=in.($idList)")
$request.Headers.Add("apikey", $ServiceRoleKey)
$request.Headers.Add("Authorization", "Bearer $ServiceRoleKey")
$request.Headers.UserAgent.ParseAdd("The-Sports-Lobby-Mark-GolfersRemaining/1.0")
$request.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, "application/json")

$response = $httpClient.SendAsync($request).GetAwaiter().GetResult()
$responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

if (-not $response.IsSuccessStatusCode) {
  Write-Error "Request failed: $($response.StatusCode) $($response.ReasonPhrase)"
  Write-Error "Response body: $responseBody"
  exit 1
}

Write-Host "Marked $($toEliminate.Count) golfer(s) as eliminated."
