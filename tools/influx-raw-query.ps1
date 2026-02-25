param([string]$Token, [string]$Query)
$url = "http://localhost:8086/api/v2/query?org=activeprobe-perf"
$headers = @{ "Authorization" = "Token $Token"; "Accept" = "application/csv"; "Content-Type" = "application/vnd.flux" }
$r = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $Query -ContentType "application/vnd.flux" -UseBasicParsing
$r.Content
