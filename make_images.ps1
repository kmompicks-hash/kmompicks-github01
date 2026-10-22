<#
  케이맘픽스 이미지 만들기 (Python 불필요, Edge 브라우저로 캡처)

  사용법:
    .\make_images.cmd content\<폴더>

  <폴더>\images\src\*.html 을 하나씩 열어 PNG 로 찍어 <폴더>\images\ 에 저장합니다.
  각 HTML 에는 <meta name="kmom-size" content="1200x630"> 처럼 크기를 적어 둡니다.
  디자인 공통 스타일: tools\image-kit\kmom.css
#>
param([Parameter(Mandatory = $true, Position = 0)][string]$Folder)

$ErrorActionPreference = 'Stop'
function Fail([string]$msg) { Write-Host "❌ $msg" -ForegroundColor Red; exit 1 }

$dir = Resolve-Path $Folder -ErrorAction SilentlyContinue
if (-not $dir) { Fail "폴더를 찾을 수 없습니다: $Folder" }
$srcDir = Join-Path $dir 'images\src'
$outDir = Join-Path $dir 'images'
$sources = @(Get-ChildItem $srcDir -Filter *.html -ErrorAction SilentlyContinue | Sort-Object Name)
if (-not $sources.Count) { Fail "이미지 원본(images\src\*.html)이 없습니다: $srcDir" }

$browser = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { Fail "Edge 또는 Chrome 을 찾을 수 없습니다." }

# 켜져 있는 브라우저 창과 섞이지 않도록 임시 프로필을 따로 쓴다.
$profileDir = Join-Path $env:TEMP 'kmompicks-image-profile'

foreach ($src in $sources) {
    $html = [IO.File]::ReadAllText($src.FullName, [Text.Encoding]::UTF8)
    if ($html -notmatch '<meta name="kmom-size" content="(\d+)x(\d+)"') { Fail "$($src.Name): kmom-size 메타 태그가 없습니다." }
    $w = $Matches[1]; $h = $Matches[2]
    $png = Join-Path $outDir ($src.BaseName + '.png')
    if (Test-Path $png) { Remove-Item $png }
    $url = 'file:///' + ($src.FullName -replace '\\', '/')
    $argList = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
        '--virtual-time-budget=5000', "--user-data-dir=`"$profileDir`"", "--window-size=$w,$h",
        "--screenshot=`"$png`"", "`"$url`"")
    Start-Process -FilePath $browser -ArgumentList $argList -Wait -WindowStyle Hidden
    if (-not (Test-Path $png)) { Fail "$($src.Name) 캡처에 실패했습니다." }
    Write-Host "  🖼 $($src.BaseName).png ($w x $h)"
}
Write-Host "✅ 이미지 $($sources.Count)장 생성 → $outDir" -ForegroundColor Green
