# Draws the logo (the same shapes as logo.svg) into logo.png and strata-launcher.ico, the window and
# shortcut icon. Run it after changing the design:
#   powershell -NoProfile -ExecutionPolicy Bypass -File assets\make-icons.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function New-Logo([int]$Size) {
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.InterpolationMode = 'HighQualityBicubic'
    $k = $Size / 256.0
    $pt = { param($x, $y) New-Object System.Drawing.PointF ([float]($x * $k)), ([float]($y * $k)) }
    $poly = { param([double[]]$xy) $pts = for ($i = 0; $i -lt $xy.Count; $i += 2) { & $pt $xy[$i] $xy[$i + 1] }; [System.Drawing.PointF[]]$pts }
    $grad = { param($c1, $c2, [double[]]$box) New-Object System.Drawing.Drawing2D.LinearGradientBrush (& $pt $box[0] $box[1]), (& $pt $box[2] $box[3]),
        ([System.Drawing.ColorTranslator]::FromHtml($c1)), ([System.Drawing.ColorTranslator]::FromHtml($c2)) }
    $solid = { param($c) New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($c)) }

    # rounded background
    $r = 56 * $k; $w = $Size
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, 2 * $r, 2 * $r, 180, 90); $path.AddArc($w - 2 * $r, 0, 2 * $r, 2 * $r, 270, 90)
    $path.AddArc($w - 2 * $r, $w - 2 * $r, 2 * $r, 2 * $r, 0, 90); $path.AddArc(0, $w - 2 * $r, 2 * $r, 2 * $r, 90, 90); $path.CloseFigure()
    $g.FillPath((& $grad '#101828' '#1d2939' @(0, 0, 256, 256)), $path)

    $layers = @(
        @{ Y = 150; Edge = '#5b21b6'; A = '#818cf8'; B = '#7c3aed' }
        @{ Y = 112; Edge = '#1d4ed8'; A = '#38bdf8'; B = '#3b82f6' }
        @{ Y = 74; Edge = '#0e7490'; A = '#5eead4'; B = '#22d3ee' }
    )
    foreach ($l in $layers) {
        $y = $l.Y
        $g.FillPolygon((& $solid $l.Edge), (& $poly @(128, $y, 212, ($y + 36), 212, ($y + 48), 128, ($y + 84), 44, ($y + 48), 44, ($y + 36))))
        $g.FillPolygon((& $grad $l.A $l.B @(44, $y, 212, ($y + 72))), (& $poly @(128, $y, 212, ($y + 36), 128, ($y + 72), 44, ($y + 36))))
    }
    $g.FillPolygon([System.Drawing.Brushes]::White, (& $poly @(113, 94, 151, 110, 113, 126)))
    $g.Dispose()
    return $bmp
}

function Get-PngBytes($Bitmap) {
    $ms = New-Object IO.MemoryStream
    $Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    return , $ms.ToArray()
}

$big = New-Logo 256
$big.Save((Join-Path $PSScriptRoot 'logo.png'), [System.Drawing.Imaging.ImageFormat]::Png)

# An .ico of PNG images (Windows Vista and later read them): 256, 64, 48, 32, 24, 16.
$sizes = 256, 64, 48, 32, 24, 16
$images = foreach ($s in $sizes) { $b = New-Logo $s; , (Get-PngBytes $b); $b.Dispose() }
$ms = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter $ms
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)   # ICONDIR: reserved, type 1 = icon, count
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $images[$i].Length
    $w.Write([byte]$(if ($s -ge 256) { 0 } else { $s })); $w.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))   # 0 means 256
    $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]1); $w.Write([uint16]32)                            # palette, reserved, planes, bpp
    $w.Write([uint32]$len); $w.Write([uint32]$offset)
    $offset += $len
}
foreach ($img in $images) { $w.Write($img) }
[IO.File]::WriteAllBytes((Join-Path $PSScriptRoot 'strata-launcher.ico'), $ms.ToArray())
$big.Dispose()
Write-Host "Wrote logo.png and strata-launcher.ico ($($sizes -join ', ') px) in $PSScriptRoot"
