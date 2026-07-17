@echo off
setlocal
set "SAMCUTOUT_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:SAMCUTOUT_SELF; $s=[IO.File]::ReadAllText($p); iex ($s.Substring($s.LastIndexOf('#>')+2))"
exit /b %ERRORLEVEL%
#>
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$Root = Split-Path -Parent $env:SAMCUTOUT_SELF
$Models = Join-Path $Root "models"
$Logs = Join-Path $Root "logs"
$Log = Join-Path $Logs "model_install.log"
$Py = Join-Path $Root "_internal\env\python.exe"

New-Item -ItemType Directory -Force $Models, $Logs | Out-Null

function Write-Log([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $Log -Value $line -Encoding UTF8
    Write-Host $Message
}

function Assert-MinSize([string]$Path, [int64]$MinBytes) {
    if (!(Test-Path $Path)) { throw "Missing file: $Path" }
    $size = (Get-Item $Path).Length
    if ($size -lt $MinBytes) { throw "Downloaded file is too small: $Path ($size bytes)" }
}

function Download-File([string]$Name, [string]$Url, [int64]$MinBytes) {
    $Target = Join-Path $Models $Name
    if (Test-Path $Target) {
        $size = (Get-Item $Target).Length
        if ($size -ge $MinBytes) {
            Write-Log "$Name already exists, skipping."
            return
        }
        Remove-Item $Target -Force
    }
    $Part = "$Target.part"
    if (Test-Path $Part) { Remove-Item $Part -Force }
    Write-Log "Downloading $Name"
    $started = Get-Date
    Invoke-WebRequest -Uri $Url -OutFile $Part -UseBasicParsing
    Assert-MinSize $Part $MinBytes
    $elapsed = [Math]::Round(((Get-Date) - $started).TotalSeconds, 2)
    $bytes = (Get-Item $Part).Length
    Move-Item $Part $Target -Force
    Write-Log "$Name downloaded, bytes=$bytes, elapsed=${elapsed}s."
}

Write-Log "Installing official model files into $Models"

Download-File `
    "sam_vit_h_4b8939.pth" `
    "https://dl.fbaipublicfiles.com/segment_anything/sam_vit_h_4b8939.pth" `
    1000000000

Download-File `
    "bpe_simple_vocab_16e6.txt.gz" `
    "https://raw.githubusercontent.com/facebookresearch/sam3/main/sam3/assets/bpe_simple_vocab_16e6.txt.gz" `
    500000

$Sam3Target = Join-Path $Models "sam3.pt"
if (Test-Path $Sam3Target -and (Get-Item $Sam3Target).Length -ge 1000000000) {
    Write-Log "sam3.pt already exists, skipping."
} else {
    if (!(Test-Path $Py)) {
        throw "Runtime Python not found. Please run InstallRuntime.cmd before downloading SAM3."
    }
    $Token = Read-Host "Enter Hugging Face token for facebook/sam3"
    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw "Hugging Face token is required for facebook/sam3."
    }
    $TempScript = Join-Path $env:TEMP ("samcutout_download_sam3_" + [Guid]::NewGuid().ToString("N") + ".py")
    @'
import os
import shutil
import sys
from huggingface_hub import hf_hub_download

token = os.environ["HF_TOKEN"]
target = sys.argv[1]
part = target + ".part"
path = hf_hub_download(repo_id="facebook/sam3", filename="sam3.pt", token=token)
shutil.copyfile(path, part)
size = os.path.getsize(part)
if size < 1_000_000_000:
    raise RuntimeError(f"sam3.pt is too small: {size} bytes")
os.replace(part, target)
print("sam3.pt downloaded")
'@ | Set-Content -Path $TempScript -Encoding UTF8
    try {
        $env:HF_TOKEN = $Token
        $started = Get-Date
        & $Py $TempScript $Sam3Target 2>&1 | Tee-Object -FilePath $Log -Append
        if ($LASTEXITCODE -ne 0) { throw "SAM3 download failed with exit code $LASTEXITCODE" }
        $elapsed = [Math]::Round(((Get-Date) - $started).TotalSeconds, 2)
    } finally {
        Remove-Item Env:\HF_TOKEN -ErrorAction SilentlyContinue
        Remove-Item $TempScript -Force -ErrorAction SilentlyContinue
    }
    Assert-MinSize $Sam3Target 1000000000
    $bytes = (Get-Item $Sam3Target).Length
    Write-Log "sam3.pt downloaded, bytes=$bytes, elapsed=${elapsed}s."
}

Write-Log "Model installation complete."
