param (
    [switch]$Watch,
    [switch]$SkipTranslations
)

$env:LIBGL_ALWAYS_SOFTWARE = "1"
$env:SDL_VIDEO_DRIVER = "x11"
$env:SDL_VIDEODRIVER = "x11"

$EnvList = @("LIBGL_ALWAYS_SOFTWARE/u", "SDL_VIDEO_DRIVER/u", "SDL_VIDEODRIVER/u")
foreach ($item in $EnvList) {
    $varName = $item.Split('/')[0]
    if ($env:WSLENV) {
        if ($env:WSLENV -notlike "*$varName*") {
            $env:WSLENV = "$env:WSLENV:$item"
        }
    } else {
        $env:WSLENV = $item
    }
}

$ToolsDir = $PSScriptRoot
$RepoRoot = (Resolve-Path "$ToolsDir/..").Path
$KoreaderDir = Join-Path $RepoRoot "koreader"
$PluginDir = Join-Path $KoreaderDir "nimbus.koplugin"

$WSLDest = "~/.config/koreader/plugins/nimbus.koplugin"
$SyntaxScript = Join-Path $ToolsDir "check_syntax.py"
$AuditScript = Join-Path $ToolsDir "check_translations.py"

$SquashPath = ""
$UserNameLower = $env:USERNAME.ToLower()
$ProbedPaths = @(
    "/home/jimmy/squashfs-root",
    "/home/$env:USERNAME/squashfs-root",
    "/home/$UserNameLower/squashfs-root",
    "/mnt/c/Users/$env:USERNAME/squashfs-root",
    "/mnt/c/Users/$UserNameLower/squashfs-root"
)
foreach ($path in $ProbedPaths) {
    $null = wsl test -d $path
    if ($LASTEXITCODE -eq 0) {
        $SquashPath = $path
        break
    }
}
if (-not $SquashPath) {
    $SquashPath = "/home/jimmy/squashfs-root"
}
Write-Host "Using KOReader installation path: $SquashPath" -ForegroundColor Yellow

function Run-Workflow {
    Write-Host "`n--- Starting Nimbus KOReader Verification Workflow ---" -ForegroundColor Cyan

    # 1. Syntax Check
    Write-Host "Checking Lua syntax..." -NoNewline
    $syntaxResult = python -X utf8 $SyntaxScript $PluginDir
    if ($LASTEXITCODE -ne 0) {
        Write-Host " FAILED" -ForegroundColor Red
        Write-Host $syntaxResult
        return $false
    }
    Write-Host " PASSED" -ForegroundColor Green

    # 2. Translation Audit (optional if languages/ hasn't been generated yet)
    if (-not $SkipTranslations -and (Test-Path (Join-Path $PluginDir "languages"))) {
        Write-Host "Auditing translations..." -NoNewline
        $auditResult = python -X utf8 $AuditScript
        if ($LASTEXITCODE -ne 0) {
            Write-Host " FAILED" -ForegroundColor Red
            Write-Host $auditResult
            return $false
        }
        Write-Host " PASSED" -ForegroundColor Green
    }

    $winKoreaderPath = (Get-Item $KoreaderDir).FullName -replace '\\', '/'
    $WslKoreaderDir = (wsl wslpath -u $winKoreaderPath).Trim()

    $winPluginPath = (Get-Item $PluginDir).FullName -replace '\\', '/'
    $WslPluginDir = (wsl wslpath -u $winPluginPath).Trim()

    # 3. Unit Tests
    Write-Host "Running unit tests (LuaJIT in WSL)..."
    wsl bash -c "cd '$WslKoreaderDir' && ./tests/run_tests.sh"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Tests FAILED. Aborting sync." -ForegroundColor Red
        return $false
    }
    Write-Host "Tests PASSED" -ForegroundColor Green

    # 4. Sync
    Write-Host "Syncing nimbus.koplugin to WSL..." -NoNewline
    wsl bash -c "mkdir -p $WSLDest"
    wsl rsync -rv --delete --exclude=".git/" --exclude="*.log" "$WslPluginDir/" "$WSLDest/"
    if ($LASTEXITCODE -ne 0) {
        Write-Host " FAILED" -ForegroundColor Red
        return $false
    }
    Write-Host " SUCCESS" -ForegroundColor Green

    # 5. Restart KOReader
    Write-Host "Restarting KOReader..." -ForegroundColor Cyan
    wsl pkill -9 -f koreader 2>$null
    wsl pkill -9 -f reader.lua 2>$null
    Start-Sleep -Seconds 1

    $DefaultCmd = "C:\Windows\System32\wsl.exe --exec dbus-launch --exit-with-session bash -c `"/usr/bin/koreader`""
    $StartCmd = if ($env:KOREADER_START_CMD) { $env:KOREADER_START_CMD } else { $DefaultCmd }

    Write-Host "Starting KOReader: $StartCmd"
    $cmdLine = "/c start `"`" $StartCmd"
    Start-Process cmd.exe -ArgumentList $cmdLine -WindowStyle Hidden

    Write-Host "`nReady!" -ForegroundColor Green
    return $true
}

if ($Watch) {
    Write-Host "Watching for changes in $PluginDir..." -ForegroundColor Magenta
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = (Get-Item $PluginDir).FullName
    $watcher.Filter = "*.lua"
    $watcher.IncludeSubdirectories = $true
    $watcher.EnableRaisingEvents = $true

    $action = { Run-Workflow }
    Register-ObjectEvent $watcher "Changed" -Action $action
    Register-ObjectEvent $watcher "Created" -Action $action
    Register-ObjectEvent $watcher "Deleted" -Action $action
    Register-ObjectEvent $watcher "Renamed" -Action $action

    while ($true) { Start-Sleep -Seconds 1 }
} else {
    Run-Workflow
}
