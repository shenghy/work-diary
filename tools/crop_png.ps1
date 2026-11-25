param([string]$In, [string]$Out, [int]$X, [int]$Y, [int]$W, [int]$H)
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Bitmap]::FromFile($In)
$dst = New-Object System.Drawing.Bitmap $W, $H
$g = [System.Drawing.Graphics]::FromImage($dst)
$g.DrawImage($src, (New-Object System.Drawing.Rectangle 0,0,$W,$H), (New-Object System.Drawing.Rectangle $X,$Y,$W,$H), [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose(); $dst.Save($Out); $dst.Dispose(); $src.Dispose()
Write-Output "saved $Out"
