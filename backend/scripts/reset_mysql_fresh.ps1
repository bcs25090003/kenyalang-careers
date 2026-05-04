# Wipes Kenyalang MySQL and recreates an empty database with the same schema as a brand-new Docker install.
#
# Recommended (Docker — destroys the named volume, then MySQL re-runs backend/sql/*.sql on first start):
#   powershell -ExecutionPolicy Bypass -File backend/scripts/reset_mysql_fresh.ps1
#
# Local MySQL on port 3307 (no Docker): drops DB and reapplies all backend/sql/*.sql as root
#   powershell -ExecutionPolicy Bypass -File backend/scripts/reset_mysql_fresh.ps1 -Local
#   (default root password "root"; override with -RootPassword "yourrootpass")

param(
    [switch]$Local,
    [string]$RootPassword = "root",
    [int]$Port = 3307,
    [string]$Host = "127.0.0.1"
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$SqlDir = Join-Path $RepoRoot "backend\sql"

function Wait-DockerMysql {
    $ok = $false
    for ($i = 0; $i -lt 45; $i++) {
        docker exec kenyalang_mysql mysqladmin ping -h localhost -u root -p$RootPassword --silent 2>$null
        if ($LASTEXITCODE -eq 0) { $ok = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ok) {
        Write-Error "MySQL in container did not become ready in time. Check: docker logs kenyalang_mysql"
    }
}

if (-not $Local) {
    Set-Location $RepoRoot
    Write-Host "Stopping stack and removing MySQL volume (all data in this project DB will be lost)..."
    docker compose down -v
    Write-Host "Starting MySQL fresh (init scripts will run once)..."
    docker compose up -d mysql
    Wait-DockerMysql
    Write-Host "Done. Empty database with schema from backend/sql. API user: kenyalang / kenyalang (port $Port on host)."
    exit 0
}

# --- Local MySQL ---
$mysql = Get-Command mysql -ErrorAction SilentlyContinue
if (-not $mysql) {
    Write-Error "mysql client not in PATH. Install MySQL shell client or use Docker reset without -Local."
}

Write-Host "Dropping and recreating kenyalang_careers on ${Host}:$Port (local MySQL)..."
& mysql -h $Host -P $Port -u root -p$RootPassword -e "DROP DATABASE IF EXISTS kenyalang_careers; CREATE DATABASE kenyalang_careers CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Use cmd redirection so DELIMITER / stored procedures in 003,004,007 parse correctly (pipe breaks them).
Get-ChildItem -Path $SqlDir -Filter "*.sql" -File | Sort-Object Name | ForEach-Object {
    Write-Host "  -> $($_.Name)"
    $p = $_.FullName
    $cmd = "mysql -h$Host -P$Port -uroot -p$RootPassword kenyalang_careers < `"$p`""
    cmd.exe /c $cmd
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed applying $($_.Name). Fix errors and re-run."
    }
}

Write-Host "Done. Local database reset. Ensure user kenyalang exists and has grants on kenyalang_careers (see Docker compose env) if the API uses that login."
