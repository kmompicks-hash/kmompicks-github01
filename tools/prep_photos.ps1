<#
  내 사진을 블로그용으로 정리 (Python 불필요)
  - 위치(GPS)·촬영기기 같은 사진 정보(EXIF)를 모두 지우고
  - 휴대폰 회전 정보대로 똑바로 세운 뒤
  - 가로 최대 1600px 로 줄여 JPG 로 저장

  사용법:
    powershell -ExecutionPolicy Bypass -File tools\prep_photos.ps1 -Out content\<폴더>\photos -Prefix kmom-20261023-real 사진1.jpg 사진2.jpg ...
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [Parameter(Mandatory = $true)][string]$Prefix,
    [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)][string[]]$Files,
    [int]$MaxWidth = 1600
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $Out | Out-Null

$jpeg = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
$quality = New-Object Drawing.Imaging.EncoderParameters 1
$quality.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), 88L

$i = 0
foreach ($file in $Files) {
    $i++
    $img = [Drawing.Image]::FromFile((Resolve-Path -LiteralPath $file).Path)
    $hadGps = $img.PropertyIdList -contains 0x8825
    # EXIF 0x0112(회전 정보)를 실제 픽셀 회전으로 바꿔 둔다 (정보를 지우면 사진이 눕지 않게)
    if ($img.PropertyIdList -contains 0x0112) {
        switch ($img.GetPropertyItem(0x0112).Value[0]) {
            3 { $img.RotateFlip([Drawing.RotateFlipType]::Rotate180FlipNone) }
            6 { $img.RotateFlip([Drawing.RotateFlipType]::Rotate90FlipNone) }
            8 { $img.RotateFlip([Drawing.RotateFlipType]::Rotate270FlipNone) }
        }
    }
    $scale = [Math]::Min(1.0, $MaxWidth / $img.Width)
    $w = [int][Math]::Round($img.Width * $scale); $h = [int][Math]::Round($img.Height * $scale)
    # 새 캔버스에 다시 그리면 EXIF 가 전혀 따라오지 않는다
    $bmp = New-Object Drawing.Bitmap $w, $h
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($img, 0, 0, $w, $h)
    $name = '{0}-{1:00}.jpg' -f $Prefix, $i
    $bmp.Save((Join-Path $Out $name), $jpeg, $quality)
    $g.Dispose(); $bmp.Dispose(); $img.Dispose()
    Write-Host ("  📷 {0} ({1}x{2}){3}" -f $name, $w, $h, $(if ($hadGps) { ' · 위치정보 삭제됨' } else { '' }))
}
