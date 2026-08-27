<#
.SYNOPSIS
    一键部署 Cloudflare Snippet（上传脚本 + 配置触发规则），全程走 API，无需登录网页操作。

.DESCRIPTION
    认证二选一：
      1) API Token（推荐）: -ApiToken            （权限需包含 Zone -> Snippets -> Edit，另加 Zone -> Zone -> Read）
      2) Global API Key   : -AuthEmail + -AuthKey

    执行步骤：
      0) 校验凭据与 Zone（可用 -ZoneName 自动反查 Zone ID）
      1) PUT  /zones/{zone_id}/snippets/{name}            上传脚本本体（multipart/form-data）
      2) GET+PUT /zones/{zone_id}/snippets/snippet_rules  合并触发规则（自动保留其他片段的规则）

.PARAMETER ZoneId       Zone ID（Dashboard 域名概览页右侧可查；与 -ZoneName 二选一）
.PARAMETER ZoneName     主域名，如 example.com，脚本会自动反查 Zone ID
.PARAMETER SnippetName  片段名：字母开头，仅含字母/数字/下划线/连字符（自动转小写）
.PARAMETER JsFile       本地 JS 文件路径（ES Module 格式，需 export default）
.PARAMETER Expression   触发规则的规则表达式，如 'http.request.uri.path contains "/api"'
.PARAMETER Description  规则备注（可选）
.PARAMETER NoRule       只上传脚本，不配置触发规则
.PARAMETER ListSnippets 只列出该 Zone 现有片段和触发规则，然后退出

.EXAMPLE
    .\deploy-snippet.ps1 -ApiToken <token> -ZoneName example.com -SnippetName add-header `
        -JsFile .\example-add-header.js -Expression 'http.request.uri.path contains "/api"'

.EXAMPLE
    .\deploy-snippet.ps1 -AuthEmail you@example.com -AuthKey <全局API密钥> -ZoneName example.com -ListSnippets
#>
[CmdletBinding()]
param(
    [string]$ZoneId,
    [string]$ZoneName,
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]*$')]
    [string]$SnippetName,
    [string]$JsFile,
    [string]$Expression,
    [string]$Description = '',
    [string]$ApiToken,
    [string]$AuthEmail,
    [string]$AuthKey,
    [switch]$NoRule,
    [switch]$ListSnippets
)

$ErrorActionPreference = 'Stop'

function Fail([string]$msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red; exit 1 }
function Ok([string]$msg)   { Write-Host "[OK]   $msg" -ForegroundColor Green }

# Windows PowerShell 5.1 需要 TLS 1.2（pwsh 7 可忽略）
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# ---------- 参数校验 ----------
if (-not ($ApiToken -or ($AuthEmail -and $AuthKey))) {
    Fail '缺少认证参数：请提供 -ApiToken（推荐），或同时提供 -AuthEmail 和 -AuthKey'
}
$headers = if ($ApiToken) { @{ Authorization = "Bearer $ApiToken" } }
           else           { @{ 'X-Auth-Email' = $AuthEmail; 'X-Auth-Key' = $AuthKey } }

if (-not $ZoneId -and -not $ZoneName) { Fail '缺少目标站点：请提供 -ZoneId 或 -ZoneName' }

function Invoke-CfApi([string]$Method, [string]$Uri, $Body) {
    $p = @{ Method = $Method; Uri = $Uri; Headers = $headers; ContentType = 'application/json'; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $p.Body = $Body }
    Invoke-RestMethod @p
}

# ---------- 第 0 步：确定并验证 Zone ----------
if (-not $ZoneId) {
    try {
        $found = Invoke-CfApi -Method Get -Uri "https://api.cloudflare.com/client/v4/zones?name=$ZoneName"
    } catch {
        Fail "按域名反查 Zone 失败：$($_.Exception.Message)"
    }
    if (-not $found.success -or @($found.result).Count -eq 0) {
        Fail "找不到域名 [$ZoneName] 对应的 Zone（确认该账号拥有此站点）"
    }
    $ZoneId  = $found.result[0].id
    $apiBase = "https://api.cloudflare.com/client/v4/zones/$ZoneId"
    Ok "已定位 Zone：$($found.result[0].name) -> $ZoneId"
}
else {
    $apiBase = "https://api.cloudflare.com/client/v4/zones/$ZoneId"
}

try {
    $zone = Invoke-CfApi -Method Get -Uri $apiBase
} catch {
    Fail "无法访问该 Zone（检查 ZoneId 与凭据权限）：$($_.Exception.Message)"
}
if (-not $zone.success) { Fail "Cloudflare 返回错误：$(($zone.errors | ConvertTo-Json -Depth 5 -Compress))" }
Ok "Zone 验证通过：$($zone.result.name)"

# ---------- 列表模式 ----------
if ($ListSnippets) {
    Write-Host "`n--- 已有 Snippets ---"
    $list = Invoke-CfApi -Method Get -Uri "$apiBase/snippets"
    if (@($list.result).Count -eq 0) { Write-Host '(无)' }
    else { foreach ($s in @($list.result)) { Write-Host " - $($s.snippet_name)" } }

    Write-Host "`n--- 触发规则 ---"
    try {
        $rr = Invoke-CfApi -Method Get -Uri "$apiBase/snippets/snippet_rules"
        # 过滤空元素，避免“无规则”时打出一行空白的假规则
        $allRules = @($rr.result.rules | Where-Object { $_ })
        if ($allRules.Count -eq 0) { Write-Host '(无)' }
        elseif ($allRules[0].PSObject.Properties['snippet_name'] -and $allRules[0].PSObject.Properties['expression']) {
            foreach ($r in $allRules) {
                $state = if ($r.enabled) { '启用' } else { '停用' }
                $desc  = if ($r.description) { "（$($r.description)）" } else { '' }
                Write-Host (" - [{0}] {1} <- {2} {3}" -f $state, $r.snippet_name, $r.expression, $desc)
            }
        }
        else {
            # 返回结构不符合预期时，打印原始 JSON 便于排查
            Write-Host '(返回结构异常，原始内容如下)'
            $rr.result | ConvertTo-Json -Depth 10 | Write-Host
        }
    } catch { Write-Host '(无)' }
    return
}

# ---------- 部署前校验 ----------
if (-not $SnippetName) { Fail '缺少 -SnippetName' }
if (-not $JsFile)      { Fail '缺少 -JsFile（只想查看列表请用 -ListSnippets）' }
if ((-not $NoRule) -and (-not $Expression)) { Fail '需要 -Expression 配置触发规则；若只上传脚本请加 -NoRule' }

try   { $jsPath = (Resolve-Path -LiteralPath $JsFile -ErrorAction Stop).Path }
catch { Fail "找不到 JS 文件：$JsFile" }

# 平台限制：片段名只能含小写字母、数字、下划线（不允许连字符）
if ($SnippetName -match '-') {
    $SnippetName = $SnippetName.Replace('-', '_')
    Write-Host "[提示] 片段名不能包含连字符，已自动改为：$SnippetName" -ForegroundColor Yellow
}
$SnippetName = $SnippetName.ToLower()   # 片段名统一小写

# ---------- 第 1 步：上传脚本本体 ----------
Add-Type -AssemblyName System.Net.Http

$fileName = "$SnippetName.js"
$metaJson = '{"main_module":' + ($fileName | ConvertTo-Json) + '}'

Write-Host "`n=> 上传脚本 [$fileName] ..."
$client = [System.Net.Http.HttpClient]::new()
try {
    foreach ($k in @($headers.Keys)) { [void]$client.DefaultRequestHeaders.TryAddWithoutValidation($k, [string]$headers[$k]) }

    $content = [System.Net.Http.MultipartFormDataContent]::new()
    try {
        # metadata 部分：声明入口模块
        $meta = [System.Net.Http.StringContent]::new($metaJson, [Text.Encoding]::UTF8, 'application/json')
        $content.Add($meta, 'metadata')

        # file 部分：脚本内容，ES Module 的 MIME 是 application/javascript+module
        $filePart = [System.Net.Http.ByteArrayContent]::new([IO.File]::ReadAllBytes($jsPath))
        [void]$filePart.Headers.TryAddWithoutValidation('Content-Type', 'application/javascript+module')
        $content.Add($filePart, 'file', $fileName)

        $resp     = $client.PutAsync("$apiBase/snippets/$SnippetName", $content).GetAwaiter().GetResult()
        $respBody = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
    finally { $content.Dispose() }
}
finally { $client.Dispose() }

$upload = $respBody | ConvertFrom-Json
if (-not $upload.success) { Fail "上传失败：$(($upload.errors | ConvertTo-Json -Depth 5 -Compress))" }
Ok ('脚本已部署：{0}（{1} 字节）' -f $SnippetName, (Get-Item $jsPath).Length)

# ---------- 第 2 步：合并触发规则 ----------
if ($NoRule) {
    Write-Host '[SKIP] 已按 -NoRule 跳过触发规则配置'
}
else {
    Write-Host "`n=> 合并触发规则 ..."

    # snippet_rules 的 PUT 是“全量替换”，必须先读现有规则再合并写入
    $existing = @()
    try {
        $cur = Invoke-CfApi -Method Get -Uri "$apiBase/snippets/snippet_rules"
        if ($cur.success -and $cur.result.rules) { $existing = @($cur.result.rules) }
    } catch { $existing = @() }

    # 保留指向其他片段的旧规则；同名片段的旧规则会被本次覆盖
    $kept = @( $existing | Where-Object { $_.snippet_name -ne $SnippetName } | ForEach-Object {
        @{ expression = $_.expression; snippet_name = $_.snippet_name; enabled = $_.enabled; description = $_.description }
    } )

    $kept += @{
        expression   = $Expression
        snippet_name = $SnippetName
        enabled      = $true
        description  = $Description
    }

    Write-Host ('   其他片段保留 {0} 条，本次共写入 {1} 条' -f ($kept.Count - 1), $kept.Count)

    # Body 用 UTF-8 字节发送，避免中文备注在 Windows PowerShell 5.1 下乱码
    $payload = @{ rules = $kept } | ConvertTo-Json -Depth 10
    try {
        $res = Invoke-CfApi -Method Put -Uri "$apiBase/snippets/snippet_rules" -Body ([Text.Encoding]::UTF8.GetBytes($payload))
    } catch {
        $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Fail "规则写入失败：$detail"
    }
    if (-not $res.success) { Fail "规则写入失败：$(($res.errors | ConvertTo-Json -Depth 5 -Compress))" }
    Ok ('触发规则已生效（共 {0} 条）' -f @($res.result.rules).Count)
}

Write-Host "`n完成！命中表达式的请求将由此片段在边缘处理。可再用 -ListSnippets 复查。"
