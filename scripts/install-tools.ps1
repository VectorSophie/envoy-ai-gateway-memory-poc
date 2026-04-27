# AI Gateway PoC 도구 설치 스크립트 (Windows PowerShell)
# 실행: powershell -ExecutionPolicy Bypass -File install-tools.ps1

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== AI Gateway PoC 도구 설치 ===" -ForegroundColor Cyan
Write-Host ""

# winget 존재 확인
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "[Error] winget이 없습니다. Windows App Installer를 설치하거나 Chocolatey를 사용하세요." -ForegroundColor Red
    exit 1
}

# ── kind 설치 ─────────────────────────────────────────────────────────────────
if (Get-Command kind -ErrorAction SilentlyContinue) {
    Write-Host "[OK] kind: $(kind version)" -ForegroundColor Green
} else {
    Write-Host "[Installing] kind..." -ForegroundColor Yellow
    # winget 시도
    winget install --id Kubernetes.kind --silent --accept-source-agreements --accept-package-agreements
    if (-not (Get-Command kind -ErrorAction SilentlyContinue)) {
        # 수동 다운로드 fallback
        Write-Host "  winget 실패, 수동 다운로드..." -ForegroundColor Yellow
        $kindUrl = "https://kind.sigs.k8s.io/dl/v0.27.0/kind-windows-amd64"
        $kindDest = "$env:LOCALAPPDATA\Microsoft\WindowsApps\kind.exe"
        Invoke-WebRequest -Uri $kindUrl -OutFile $kindDest
        Write-Host "[OK] kind 설치됨: $kindDest" -ForegroundColor Green
    }
}

# ── helm 설치 ─────────────────────────────────────────────────────────────────
if (Get-Command helm -ErrorAction SilentlyContinue) {
    Write-Host "[OK] helm: $(helm version --short)" -ForegroundColor Green
} else {
    Write-Host "[Installing] helm..." -ForegroundColor Yellow
    winget install --id Helm.Helm --silent --accept-source-agreements --accept-package-agreements
    if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
        Write-Host "[Error] helm 설치 실패. https://helm.sh/docs/intro/install/ 에서 수동 설치하세요." -ForegroundColor Red
        exit 1
    }
}

# ── Python 패키지 설치 ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[Installing] Python 데모 클라이언트 의존성..." -ForegroundColor Yellow
$clientDir = Join-Path $PSScriptRoot "..\demo-client"
python -m pip install httpx --quiet
Write-Host "[OK] httpx 설치됨" -ForegroundColor Green

Write-Host ""
Write-Host "=== 설치 완료 ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "다음 단계:"
Write-Host "  1. Docker Desktop 실행 확인"
Write-Host "  2. bash scripts/setup.sh 실행"
Write-Host ""
