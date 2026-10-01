param(
    [string]$RepoName = "flipper-zero-mouse-jiggler",
    [string]$Description = "Native Flipper Zero USB HID mouse jiggler with a PowerShell installer.",
    [switch]$Private
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git is not installed or is not on PATH."
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is not installed. Install it with: winget install --id GitHub.cli"
}

gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "GitHub CLI is not authenticated. Starting login..."
    gh auth login
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub authentication failed."
    }
}

if (-not (Test-Path ".git")) {
    git init
    git branch -M main
}

git add .
git commit -m "Initial release: native Flipper Zero mouse jiggler"

$Visibility = if ($Private) { "--private" } else { "--public" }

gh repo create $RepoName $Visibility --source=. --remote=origin --push --description $Description

if ($LASTEXITCODE -ne 0) {
    throw "GitHub repository creation or push failed."
}

Write-Host ""
Write-Host "Repository created and pushed successfully." -ForegroundColor Green
gh repo view --web
