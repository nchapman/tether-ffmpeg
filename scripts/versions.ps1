# Expose versions.env values as $env: variables for the Windows build script.
# Parses the (bash-syntax) versions.env so there's a single source of truth for
# pins across every platform — no duplicated version numbers.
$envFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.env'
Get-Content $envFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { return }
    $name, $value = $line -split '=', 2
    # Strip surrounding double quotes, if any.
    $value = $value.Trim().Trim('"')
    Set-Item -Path "env:$($name.Trim())" -Value $value
}
