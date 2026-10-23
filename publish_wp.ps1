<#
  케이맘픽스 워드프레스 자동 업로드 (PowerShell 판, Python 설치 불필요)

  사용법 (VS Code 터미널에서):
    .\publish_wp.cmd content\20261021-vscode-claude-code-install-working-mom
    .\publish_wp.cmd content\<폴더> -DryRun      # 실제로 올리지 않고 확인만

  - 기본은 임시저장(draft). 같은 slug 글이 있으면 새로 만들지 않고 그 글을 고칩니다.
  - 이미 발행된 글은 덮어쓰지 않습니다 (-Force 를 붙여야 수정).
  - 접속 정보는 같은 폴더의 .env 에서 읽습니다 (.env.example 참고, 깃허브에 올라가지 않음).
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Folder,
    [switch]$DryRun,
    [ValidateSet('draft', 'pending', 'private', 'publish')][string]$Status,
    [switch]$Force,
    [switch]$SeoOnly
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root = $PSScriptRoot

function Fail([string]$msg) { Write-Host "❌ $msg" -ForegroundColor Red; exit 1 }

# ------------------------------------------------------------ .env
$envFile = Join-Path $Root '.env'
if (-not (Test-Path $envFile)) { Fail ".env 파일이 없습니다. .env.example 을 복사해 .env 로 저장하고 값을 채우세요." }
$cfg = @{}
foreach ($line in [IO.File]::ReadAllLines($envFile, [Text.Encoding]::UTF8)) {
    if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') { $cfg[$Matches[1]] = $Matches[2].Trim('"') }
}
foreach ($k in 'WP_URL', 'WP_USERNAME', 'WP_APP_PASSWORD') {
    if (-not $cfg[$k]) { Fail ".env 에 $k 값이 비어 있습니다." }
}
$wpUrl = $cfg['WP_URL'].TrimEnd('/')
if ($wpUrl -notmatch '^https://') { Fail "WP_URL 은 https:// 로 시작해야 합니다 (비밀번호 보호)." }
if (-not $Status) { $Status = if ($cfg['WP_DEFAULT_STATUS']) { $cfg['WP_DEFAULT_STATUS'] } else { 'draft' } }
$createCategories = $cfg['WP_CREATE_MISSING_CATEGORIES'] -eq 'true'

$token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($cfg['WP_USERNAME']):$($cfg['WP_APP_PASSWORD'])"))
$headers = @{ Authorization = "Basic $token"; 'User-Agent' = 'kmompicks-publisher-ps/1.0' }

function Invoke-WP([string]$Method, [string]$Route, $Body = $null, [hashtable]$Query = @{}, [string]$File = '') {
    $qs = ($Query.GetEnumerator() | ForEach-Object { "$($_.Key)=$([Uri]::EscapeDataString([string]$_.Value))" }) -join '&'
    # '/rankmath/v1/…' 처럼 / 로 시작하면 wp/v2 가 아닌 다른 플러그인 경로로 보낸다.
    $path = if ($Route.StartsWith('/')) { $Route.TrimStart('/') } else { "wp/v2/$Route" }
    $uri = "$wpUrl/wp-json/$path" + $(if ($qs) { "?$qs" } else { '' })
    $params = @{ Method = $Method; Uri = $uri; Headers = $headers.Clone(); UseBasicParsing = $true; TimeoutSec = 180 }
    if ($File) {
        $params.Body = [IO.File]::ReadAllBytes($File)
        $params.ContentType = @{ '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.webp' = 'image/webp'; '.gif' = 'image/gif' }[[IO.Path]::GetExtension($File).ToLower()]
        if (-not $params.ContentType) { Fail "이미지 파일만 올릴 수 있습니다: $File" }
        $params.Headers['Content-Disposition'] = "attachment; filename=`"$([IO.Path]::GetFileName($File))`""
    } elseif ($null -ne $Body) {
        $params.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 5))
        $params.ContentType = 'application/json; charset=utf-8'
    }
    try {
        $resp = Invoke-WebRequest @params
        return [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
    } catch {
        $err = $_   # switch 안에서는 $_ 가 switch 값으로 바뀌므로 미리 잡아 둔다
        $code = $err.Exception.Response.StatusCode.value__
        $hint = switch ($code) {
            401 { '아이디 또는 애플리케이션 비밀번호가 틀렸습니다 (관리자 > 사용자 > 프로필 > 애플리케이션 비밀번호).' }
            403 { '글쓰기 권한이 없거나 보안 플러그인/방화벽이 REST API 를 막았습니다.' }
            404 { 'REST API 주소를 찾을 수 없습니다 (WP_URL 확인).' }
            default { $err.Exception.Message }
        }
        $detail = "$($err.ErrorDetails.Message)"
        if ($detail -match '"message"\s*:\s*"([^"]*)"') { $detail = $Matches[1] }
        elseif ($detail -match '<title>([^<]*)</title>') { $detail = "차단 페이지: $($Matches[1].Trim())" }
        else { $detail = $detail.Substring(0, [Math]::Min(200, $detail.Length)) }
        Fail "워드프레스 오류 $code : $hint`n   (서버 응답: $detail)"
    }
}

function Get-TermKey([string]$name) { ($name -replace '[^\p{L}\p{N}_]', '').ToLower() }

function Get-TermIds([string]$Taxonomy, [string[]]$Names, [bool]$Create) {
    $label = if ($Taxonomy -eq 'categories') { '카테고리' } else { '태그' }
    $ids = @()
    foreach ($name in ($Names | Select-Object -Unique)) {
        $key = Get-TermKey $name
        $search = ($name -replace '[^\p{L}\p{N}\s-]', ' ').Trim()
        $found = @(Invoke-WP GET $Taxonomy -Query @{ search = $search; per_page = 100 })
        $match = $found | Where-Object { (Get-TermKey $_.name) -eq $key } | Select-Object -First 1
        if (-not $match) {
            $found = @(Invoke-WP GET $Taxonomy -Query @{ per_page = 100; hide_empty = 'false' })
            $match = $found | Where-Object { (Get-TermKey $_.name) -eq $key } | Select-Object -First 1
        }
        if ($match) { $ids += $match.id }
        elseif ($DryRun) { Write-Host "  · 새 $label 로 만들 예정: $name" }
        elseif ($Create) { $ids += (Invoke-WP POST $Taxonomy @{ name = $name }).id; Write-Host "  · 새 $label 생성: $name" }
        else { Write-Host "  ⚠ $label '$name' 이(가) 사이트에 없어 건너뜀" -ForegroundColor Yellow }
    }
    return , $ids
}

# ------------------------------------------------------------ 원고 읽기
$dir = (Resolve-Path $Folder -ErrorAction SilentlyContinue)
if (-not $dir) { Fail "폴더를 찾을 수 없습니다: $Folder" }
$htmlFile = Join-Path $dir '1_wordpress.html'; $dataFile = Join-Path $dir 'data.json'
if (-not (Test-Path $htmlFile) -or -not (Test-Path $dataFile)) { Fail "1_wordpress.html / data.json 이 있는 폴더가 아닙니다: $Folder" }

$data = [IO.File]::ReadAllText($dataFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
$wp = $data.wordpress.output
$content = [regex]::Replace([IO.File]::ReadAllText($htmlFile, [Text.Encoding]::UTF8), '\A\s*<!--[\s\S]*?-->\s*', '')
# NinjaFirewall 이 <script> 가 든 요청을 통째로 막기 때문에 JSON-LD 블록은 빼고 올린다.
if ($content -match '<script') {
    $content = [regex]::Replace($content, '\s*<script\b[\s\S]*?</script>\s*', "`n")
    Write-Host "  ℹ 보안 방화벽이 <script>(JSON-LD 구조화 데이터)를 막아서 빼고 올립니다." -ForegroundColor Cyan
}
if ($content -match 'REPLACE_ME') { Write-Host "  ⚠ 제휴 링크가 아직 REPLACE_ME 입니다." -ForegroundColor Yellow }

Write-Host "📄 $($wp.seo_title)"
Write-Host "   slug: $($wp.slug) / 상태: $Status$(if ($DryRun) { ' / 확인만(DryRun)' })"

# ------------------------------------------------------------ 업로드
$me = Invoke-WP GET 'users/me' -Query @{ context = 'edit' }
Write-Host "🔐 로그인 확인: $($me.name)"

$existing = @(Invoke-WP GET 'posts' -Query @{ slug = $wp.slug; status = 'any'; context = 'edit' }) | Select-Object -First 1

# Rank Math SEO 칸(포커스 키워드, 메타 설명)은 wp/v2 로는 저장되지 않아 Rank Math 전용 경로로 따로 넣는다.
function Set-RankMathMeta([int]$PostId) {
    $meta = @{ rank_math_focus_keyword = $wp.focus_keyword; rank_math_description = $wp.meta_description }
    if ($DryRun) { Write-Host "  · Rank Math 포커스 키워드 '$($wp.focus_keyword)' 와 메타 설명을 넣을 예정"; return }
    [void](Invoke-WP POST '/rankmath/v1/updateMeta' @{ objectType = 'post'; objectID = $PostId; meta = $meta })
    Write-Host "  🔎 Rank Math SEO 설정: 포커스 키워드 '$($wp.focus_keyword)' · 메타 설명"
}

if ($SeoOnly) {
    if (-not $existing) { Fail "slug '$($wp.slug)' 글이 사이트에 없습니다. 먼저 -SeoOnly 없이 올리세요." }
    Set-RankMathMeta $existing.id
    Write-Host "✅ SEO 설정만 반영했습니다 (#$($existing.id), 본문은 그대로)." -ForegroundColor Green
    exit 0
}

if ($existing -and $existing.status -eq 'publish' -and -not $Force) {
    Fail "이미 발행된 글입니다 ($($existing.link)). 덮어쓰려면 -Force, SEO 설정만 넣으려면 -SeoOnly 를 붙이세요."
}

# ------------------------------------------------------------ 이미지 (본문 images/… + 대표 이미지 *-thumbnail.png)
# 한 번 올린 이미지는 images\.uploaded.json 에 기록해 두고, 파일이 바뀌었을 때만 다시 올린다.
$imgDir = Join-Path $dir 'images'
$cacheFile = Join-Path $imgDir '.uploaded.json'
$cache = @{}
if (Test-Path $cacheFile) {
    (ConvertFrom-Json ([IO.File]::ReadAllText($cacheFile, [Text.Encoding]::UTF8))).PSObject.Properties | ForEach-Object { $cache[$_.Name] = $_.Value }
}

function Publish-Image([string]$Rel, [string]$Alt) {
    $path = Join-Path $dir $Rel
    if (-not (Test-Path $path)) { Fail "이미지 파일이 없습니다: $Rel (make_images.cmd 로 먼저 만드세요)" }
    $hash = (Get-FileHash $path -Algorithm SHA256).Hash
    $hit = $cache[$Rel]
    if ($hit -and $hit.hash -eq $hash) { return $hit }
    if ($DryRun) { Write-Host "  · 이미지 업로드 예정: $Rel"; return $null }
    # 서버가 저장은 해 놓고 502 로 답하는 경우가 있어, 같은 이름이 이미 있으면 다시 올리지 않고 그걸 쓴다.
    $fileName = [IO.Path]::GetFileName($path)
    $media = @(Invoke-WP GET 'media' -Query @{ search = [IO.Path]::GetFileNameWithoutExtension($path); per_page = 20 }) |
        Where-Object { $_.source_url -like "*/$fileName" } | Select-Object -First 1
    if ($media -and -not $hit) {
        Write-Host "  ♻ 이미 올라가 있는 이미지 사용: $Rel"
    } else {
        $media = Invoke-WP POST 'media' -File $path
    }
    if ($Alt) { [void](Invoke-WP POST "media/$($media.id)" @{ alt_text = $Alt }) }
    $entry = [pscustomobject]@{ hash = $hash; id = $media.id; url = $media.source_url }
    $cache[$Rel] = $entry
    [IO.File]::WriteAllText($cacheFile, ($cache | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding $false))
    Write-Host "  🖼 이미지 업로드: $Rel"
    return $entry
}

foreach ($m in [regex]::Matches($content, '<img\b[^>]*>')) {
    if ($m.Value -notmatch 'src="((?:images|photos)/[^"]+)"') { continue }
    $rel = $Matches[1]
    $alt = if ($m.Value -match 'alt="([^"]*)"') { $Matches[1] } else { '' }
    $media = Publish-Image $rel $alt
    if ($media) { $content = $content.Replace("src=`"$rel`"", "src=`"$($media.url)`"") }
}

$featuredId = $null
$thumb = Get-ChildItem $imgDir -Filter '*-thumbnail.png' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($thumb) {
    $media = Publish-Image "images/$($thumb.Name)" $wp.seo_title
    if ($media) { $featuredId = $media.id }
} else {
    Write-Host "  ⚠ 대표 이미지(images\*-thumbnail.png)가 없습니다." -ForegroundColor Yellow
}

$tagIds = Get-TermIds 'tags' @($wp.tags) ($cfg['WP_CREATE_MISSING_TERMS'] -ne 'false')
$catNames = @($data.input.category) + @(($cfg['WP_DEFAULT_CATEGORY'] -split ',') | ForEach-Object { $_.Trim() }) | Where-Object { $_ }
$catIds = Get-TermIds 'categories' $catNames $createCategories

$post = @{
    title = $wp.seo_title; content = $content; slug = $wp.slug
    excerpt = $wp.meta_description; status = $Status; tags = $tagIds
}
if ($catIds.Count) { $post.categories = $catIds }
if ($featuredId) { $post.featured_media = $featuredId }

if ($DryRun) {
    $action = if ($existing) { "기존 글 #$($existing.id) 수정" } else { '새 글 생성' }
    Set-RankMathMeta 0
    Write-Host "✅ 확인 완료: 실제로 올리면 '$action' 됩니다. (태그 $($tagIds.Count)개 · 카테고리 $($catIds.Count)개 매칭)" -ForegroundColor Green
    exit 0
}

if ($existing) { $result = Invoke-WP POST "posts/$($existing.id)" $post; $action = '수정' }
else { $result = Invoke-WP POST 'posts' $post; $action = '생성' }
Set-RankMathMeta $result.id

Write-Host "✅ $action 완료 (#$($result.id), 상태: $($result.status))" -ForegroundColor Green
Write-Host "   편집 화면: $wpUrl/wp-admin/post.php?post=$($result.id)&action=edit"
