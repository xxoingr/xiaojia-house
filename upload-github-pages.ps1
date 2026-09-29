param(
  [string]$Owner = "xxoingr",
  [string]$Repository = "xiaojia-house-pages",
  [string]$Branch = "main",
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------- 公开版目录：主文件夹下的 public 子文件夹 ----------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$publicDir = Join-Path $scriptDir "public"
if (-not (Test-Path -LiteralPath (Join-Path $publicDir "index.html") -PathType Leaf)) {
  throw "Missing public/index.html next to the upload script: $publicDir"
}

# ---------- 上传文件清单（相对公开版目录） ----------
# 素材扩展名不再写死，避免新增 JPG/WEBP 后公网仍保留旧文件。
$assetFiles = @(Get-ChildItem -LiteralPath (Join-Path $publicDir "assets") -File | Sort-Object Name | ForEach-Object { "assets/" + $_.Name })
$fileList = @(
  "index.html",
  "supabase-config.js",
  "manifest.webmanifest",
  "sw.js",
  "icons/icon-192.png",
  "icons/icon-512.png",
  "vendor/supabase.min.js"
) + $assetFiles

foreach ($rel in $fileList) {
  $local = Join-Path $publicDir $rel
  if (-not (Test-Path -LiteralPath $local -PathType Leaf)) {
    throw "Missing local file: $local"
  }
}
Write-Host "Public folder: $publicDir"
Write-Host "Files to upload: $($fileList -join ', ')"

function Get-GitHubToken {
  # Prefer the already authenticated GitHub CLI keyring so uploads do not
  # depend on repeatedly pasting short-lived or revoked tokens.
  $gh = Get-Command gh.exe -ErrorAction SilentlyContinue
  if ($gh) {
    $cliToken = (& $gh.Source auth token --hostname github.com 2>$null | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($cliToken)) {
      Write-Host "Using authenticated GitHub CLI credentials from the local keyring."
      return $cliToken
    }
  }

  $secureToken = Read-Host "Enter GitHub Fine-grained token (not saved to disk)" -AsSecureString
  $tokenPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPtr)
  }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPtr)
  }
}

function Get-GitBlobSha([byte[]]$Bytes) {
  $header = [Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)" + [char]0)
  $payload = New-Object byte[] ($header.Length + $Bytes.Length)
  [Buffer]::BlockCopy($header, 0, $payload, 0, $header.Length)
  [Buffer]::BlockCopy($Bytes, 0, $payload, $header.Length, $Bytes.Length)
  $sha1 = [Security.Cryptography.SHA1]::Create()
  try {
    return ([BitConverter]::ToString($sha1.ComputeHash($payload))).Replace("-", "").ToLowerInvariant()
  }
  finally {
    $sha1.Dispose()
  }
}

if ($DryRun) {
  Write-Host "Dry run OK. $($fileList.Count) files ready."
  exit 0
}

$token = Get-GitHubToken
if ([string]::IsNullOrWhiteSpace($token)) {
  throw "No GitHub token was provided. Stopping."
}
$token = -join (([string]$token).ToCharArray() | Where-Object { -not [char]::IsControl($_) })
$token = $token.Trim()

$headers = @{
  Authorization         = "Bearer $token"
  Accept                = "application/vnd.github+json"
  "X-GitHub-Api-Version" = "2022-11-28"
  "User-Agent"          = "xiaojia-house-pages-uploader"
}

# 先验证令牌，避免把 401 延迟到第一个 PUT 上传步骤。
try {
  $authenticatedUser = Invoke-RestMethod -Method Get -Uri "https://api.github.com/user" -Headers $headers
  Write-Host "Authenticated as @$($authenticatedUser.login)"
} catch {
  $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
  if ($statusCode -eq 401) {
    throw "GitHub rejected this token (401). Generate a fresh fine-grained token and paste it directly at the prompt; do not use an old or revoked token."
  }
  throw
}

foreach ($rel in $fileList) {
  $apiPath = "contents/" + ($rel -replace '\\', '/')
  $apiUri  = "https://api.github.com/repos/$Owner/$Repository/$apiPath"
  $local = Join-Path $publicDir $rel
  $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $local).Path)
  $localBlobSha = Get-GitBlobSha $bytes

  # 读取现有文件的 sha（新文件会 404，忽略）
  $currentSha = $null
  try {
    $existing = Invoke-RestMethod -Method Get -Uri "${apiUri}?ref=$Branch" -Headers $headers
    $currentSha = $existing.sha
  } catch {
    $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
    if ($statusCode -ne 404) { throw }
    # 404 = 文件还不存在，正常
  }

  if ($currentSha -and $currentSha -eq $localBlobSha) {
    Write-Host "Skipping unchanged $rel"
    continue
  }

  $encoded = [Convert]::ToBase64String($bytes)
  $body = @{
    message = "Update $rel"
    content = $encoded
    branch  = $Branch
  }
  if ($currentSha) { $body.sha = $currentSha }
  $json = $body | ConvertTo-Json -Depth 5

  Write-Host "Uploading $rel ..."
  $result = Invoke-RestMethod -Method Put -Uri $apiUri -Headers $headers -ContentType "application/json" -Body $json
  Write-Host "  ok -> $($result.commit.html_url)"
}

Write-Host "Upload succeeded. GitHub Pages may take 1-2 minutes to rebuild." -ForegroundColor Green

# 验证 index.html 是否出现在 GitHub raw（不打印 token）
$cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$rawUri = "https://raw.githubusercontent.com/$Owner/$Repository/$Branch/index.html?check=$cacheBust"
$raw = Invoke-WebRequest -UseBasicParsing -Uri $rawUri -Headers @{ "User-Agent" = "xiaojia-house-pages-uploader" }
$buildMatch = [regex]::Match([IO.File]::ReadAllText((Join-Path $publicDir "index.html")), 'data-build="[^"]+"')
if (-not $buildMatch.Success -or $raw.Content -notmatch [regex]::Escape($buildMatch.Value)) {
  Write-Warning "The public index.html does not contain the new code yet; GitHub may still be refreshing its cache."
}
else {
  Write-Host "The new code is present on GitHub." -ForegroundColor Green
}

Write-Host "The token was not saved to a file. Revoke it in GitHub settings if it was temporary."
