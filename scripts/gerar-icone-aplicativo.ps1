[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$OutputPath = "",

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$PreviewPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Split-Path -Parent $PSScriptRoot) "assets\ulanzi-libre.ico"
}

function New-UlanziIconPngBytes {
    param([Parameter(Mandatory = $true)][ValidateRange(16, 256)][int]$Size)

    $bitmap = [Drawing.Bitmap]::new($Size, $Size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $backgroundBrush = $null
    $dropPath = $null
    $dropFill = $null
    $dropPen = $null
    $trendPen = $null
    $stream = $null
    try {
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality

        $scale = [single]($Size / 256.0)
        $backgroundBrush = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml("#176B87"))
        $graphics.FillEllipse(
            $backgroundBrush,
            [single](8 * $scale),
            [single](8 * $scale),
            [single](240 * $scale),
            [single](240 * $scale)
        )

        $dropPath = [Drawing.Drawing2D.GraphicsPath]::new()
        $dropPoints = [Drawing.PointF[]]@(
            [Drawing.PointF]::new([single](128 * $scale), [single](32 * $scale)),
            [Drawing.PointF]::new([single](198 * $scale), [single](124 * $scale)),
            [Drawing.PointF]::new([single](184 * $scale), [single](190 * $scale)),
            [Drawing.PointF]::new([single](128 * $scale), [single](222 * $scale)),
            [Drawing.PointF]::new([single](72 * $scale), [single](190 * $scale)),
            [Drawing.PointF]::new([single](58 * $scale), [single](124 * $scale))
        )
        $dropPath.AddClosedCurve($dropPoints, 0.42)
        $dropFill = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(28, 255, 255, 255))
        $dropWidth = [single][Math]::Max(1.3, 12 * $scale)
        $dropPen = [Drawing.Pen]::new([Drawing.Color]::White, $dropWidth)
        $dropPen.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
        $graphics.FillPath($dropFill, $dropPath)
        $graphics.DrawPath($dropPen, $dropPath)

        $trendWidth = [single][Math]::Max(1.4, 13 * $scale)
        $trendPen = [Drawing.Pen]::new([Drawing.ColorTranslator]::FromHtml("#73E3C2"), $trendWidth)
        $trendPen.StartCap = [Drawing.Drawing2D.LineCap]::Round
        $trendPen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        $trendPen.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
        $trendPoints = [Drawing.PointF[]]@(
            [Drawing.PointF]::new([single](86 * $scale), [single](160 * $scale)),
            [Drawing.PointF]::new([single](113 * $scale), [single](138 * $scale)),
            [Drawing.PointF]::new([single](140 * $scale), [single](160 * $scale)),
            [Drawing.PointF]::new([single](176 * $scale), [single](114 * $scale))
        )
        $graphics.DrawLines($trendPen, $trendPoints)

        $stream = [IO.MemoryStream]::new()
        $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
        return $stream.ToArray()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $trendPen) { $trendPen.Dispose() }
        if ($null -ne $dropPen) { $dropPen.Dispose() }
        if ($null -ne $dropFill) { $dropFill.Dispose() }
        if ($null -ne $dropPath) { $dropPath.Dispose() }
        if ($null -ne $backgroundBrush) { $backgroundBrush.Dispose() }
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

$resolvedOutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = [IO.Path]::GetDirectoryName($resolvedOutputPath)
[void][IO.Directory]::CreateDirectory($outputDirectory)

$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$images = [Collections.Generic.List[object]]::new()
foreach ($size in $sizes) {
    $images.Add([pscustomobject]@{
        Size = $size
        Bytes = New-UlanziIconPngBytes -Size $size
    })
}

$fileStream = $null
$writer = $null
try {
    $fileStream = [IO.File]::Open(
        $resolvedOutputPath,
        [IO.FileMode]::Create,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    $writer = [IO.BinaryWriter]::new($fileStream, [Text.Encoding]::UTF8, $true)

    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$images.Count)

    $offset = 6 + (16 * $images.Count)
    foreach ($image in $images) {
        $dimension = if ($image.Size -eq 256) { 0 } else { $image.Size }
        $writer.Write([byte]$dimension)
        $writer.Write([byte]$dimension)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$image.Bytes.Length)
        $writer.Write([uint32]$offset)
        $offset += $image.Bytes.Length
    }

    foreach ($image in $images) {
        $writer.Write([byte[]]$image.Bytes)
    }
    $writer.Flush()
    $fileStream.Flush($true)
} finally {
    if ($null -ne $writer) { $writer.Dispose() }
    if ($null -ne $fileStream) { $fileStream.Dispose() }
}

if (-not [string]::IsNullOrWhiteSpace($PreviewPath)) {
    $resolvedPreviewPath = [IO.Path]::GetFullPath($PreviewPath)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($resolvedPreviewPath))
    [IO.File]::WriteAllBytes($resolvedPreviewPath, [byte[]]$images[$images.Count - 1].Bytes)
}

Write-Output $resolvedOutputPath
