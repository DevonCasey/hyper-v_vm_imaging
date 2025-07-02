$totalLines = 0
Get-ChildItem -Recurse -Include "*.ps1","*.psm1","*.rb","*.hcl","*.xml","*.json" | ForEach-Object {
    $lines = (Get-Content $_.FullName | Measure-Object -Line).Lines
    if ($_.FullName -like "*Count-LinesOCode.ps1" -or $_.FullName -like "*temp*" -or $_.FullName -like "*settings.json*") {
        $lines = 0 # Exclude this script and any temp files from the count
    }
    Write-Host "$($_.Name): $lines lines"
    $totalLines += $lines
}
Write-Host "`nTotal lines of code: $totalLines" -ForegroundColor Green