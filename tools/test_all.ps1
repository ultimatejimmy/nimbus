$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path

Write-Host "=== 1/4: Spec & Fixtures Validation ===" -ForegroundColor Cyan
python "$RepoRoot\spec\validate_fixtures.py"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "`n=== 2/4: KOReader Plugin Tests (WSL LuaJIT) ===" -ForegroundColor Cyan
& "$RepoRoot\koreader\tests\run_tests.bat"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "`n=== 3/4: Calibre Plugin Tests & ZIP Build ===" -ForegroundColor Cyan
python -m unittest discover -s "$RepoRoot\calibre\tests" -v
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
python "$RepoRoot\calibre\build_zip.py"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "`n=== 4/4: Web App Vitest & Production PWA Build ===" -ForegroundColor Cyan
npm --prefix "$RepoRoot\web" test
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
npm --prefix "$RepoRoot\web" run build
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "`nALL NIMBUS SUITES PASSED!" -ForegroundColor Green
