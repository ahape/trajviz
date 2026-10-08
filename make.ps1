[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0, HelpMessage = "Path to the JSON file containing transcript commands")]
    [string]$JsonPath,

    [Parameter(Position = 1, HelpMessage = "Path to the output HTML file")]
    [string]$OutputPath,

    [Parameter(HelpMessage = "Path to the HTML template file")]
    [string]$TemplatePath,

    [Parameter(HelpMessage = "Optional custom title for the generated HTML page")]
    [string]$Title
)

if (-not $TemplatePath) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
    $TemplatePath = Join-Path $scriptDir "template.html"
}

# Resolve input JSON path
$resolvedJsonPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($JsonPath)
if (-not (Test-Path -Path $resolvedJsonPath -PathType Leaf)) {
    Write-Error "JSON file not found: $resolvedJsonPath"
    exit 1
}

# Resolve template path
$resolvedTemplatePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TemplatePath)
if (-not (Test-Path -Path $resolvedTemplatePath -PathType Leaf)) {
    Write-Error "Template file not found: $resolvedTemplatePath"
    exit 1
}

# Resolve output path (default to same name with .html extension)
if (-not $OutputPath) {
    $OutputPath = [System.IO.Path]::ChangeExtension($resolvedJsonPath, ".html")
}
$resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)

# Load and parse JSON
$rawJson = Get-Content -Path $resolvedJsonPath -Raw -Encoding UTF8
try {
    $parsedJson = $rawJson | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse JSON in $resolvedJsonPath : $_"
    exit 1
}

# Extract items and optional title (supports raw array or object with commands/items)
$items = @()
$pageTitle = $Title

if ($parsedJson -is [System.Array]) {
    $items = $parsedJson
} elseif ($parsedJson.PSObject.Properties['commands']) {
    $items = $parsedJson.commands
    if (-not $pageTitle -and $parsedJson.title) { $pageTitle = $parsedJson.title }
} elseif ($parsedJson.PSObject.Properties['items']) {
    $items = $parsedJson.items
    if (-not $pageTitle -and $parsedJson.title) { $pageTitle = $parsedJson.title }
} else {
    $items = @($parsedJson)
}

if (-not $pageTitle) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedJsonPath)
    $pageTitle = "$baseName Transcript"
}

$totalCommands = $items.Count
$commandCountText = if ($totalCommands -eq 1) { "1 Command" } else { "$totalCommands Commands" }

# Build Rows HTML
$rowsBuilder = [System.Text.StringBuilder]::new()

for ($i = 0; $i -lt $totalCommands; $i++) {
    $stepNum = $i + 1
    $stepBadge = "#{0:D2}" -f $stepNum
    $item = $items[$i]

    # Command
    $rawCmd = if ($item.PSObject.Properties['command'] -and $null -ne $item.command) { [string]$item.command } else { "" }
    $encodedCmd = [System.Net.WebUtility]::HtmlEncode($rawCmd)

    # Output
    $rawOutput = if ($item.PSObject.Properties['output'] -and $null -ne $item.output) { [string]$item.output } else { "" }
    $hasOutput = -not [string]::IsNullOrWhiteSpace($rawOutput) -and ($rawOutput.Trim() -ne "(no output)")
    $outputHtml = if ($hasOutput) {
        $encodedOutput = [System.Net.WebUtility]::HtmlEncode($rawOutput)
        "<pre class=""output-content""><code>$encodedOutput</code></pre>"
    } else {
        "<div class=""no-output""><em>(no output)</em></div>"
    }

    # Reasoning (optional)
    $rawReasoning = if ($item.PSObject.Properties['reasoning'] -and $null -ne $item.reasoning) { [string]$item.reasoning } else { "" }
    $hasReasoning = -not [string]::IsNullOrWhiteSpace($rawReasoning)
    $reasoningBodyHtml = ""

    if ($hasReasoning) {
        # Split on double newlines / blank lines into separate paragraphs
        $paragraphs = $rawReasoning -split "(?:\r?\n){2,}"
        foreach ($p in $paragraphs) {
            $trimmed = $p.Trim()
            if ($trimmed.Length -gt 0) {
                $encodedP = [System.Net.WebUtility]::HtmlEncode($trimmed)
                $reasoningBodyHtml += "            <p>$encodedP</p>`n"
            }
        }
    } else {
        # Blank / placeholder state
        $reasoningBodyHtml = "            <p class=""empty-reasoning""><em>(No reasoning provided)</em></p>`n"
    }

    $rowHtml = @"
    <section class="docco-row" id="section-$stepNum" data-step="$stepNum">
      <div class="column command-col">
        <div class="col-header">
          <div class="cmd-meta">
            <span class="step-badge">$stepBadge</span>
            <span class="cmd-label" id="label-$stepNum">Command</span>
            <div class="row-toggle" title="Toggle this command / reasoning">
              <button class="row-toggle-btn active" id="row-btn-cmd-$stepNum" onclick="setRowMode($stepNum, 'command')">COMMAND</button>
              <button class="row-toggle-btn" id="row-btn-reasoning-$stepNum" onclick="setRowMode($stepNum, 'reasoning')">REASONING</button>
            </div>
          </div>
          <button class="copy-btn" onclick="copyCode(this)" title="Copy content">Copy</button>
        </div>
        <div class="code-container">
          <pre class="darcula-code" id="cmd-pre-$stepNum"><code>$encodedCmd</code></pre>
          <div class="darcula-reasoning" id="reasoning-box-$stepNum" style="display:none;">
            <div class="reasoning-tag">Likely Reasoning</div>
$reasoningBodyHtml          </div>
        </div>
      </div>
      <div class="column output-col">
        <div class="col-header">
          <span class="output-label">Output</span>
        </div>
        <div class="output-container">
          $outputHtml
        </div>
      </div>
    </section>

"@
    [void]$rowsBuilder.AppendLine($rowHtml)
}

# Read template and substitute tokens
$templateContent = Get-Content -Path $resolvedTemplatePath -Raw -Encoding UTF8
$html = $templateContent.Replace("{{PAGE_TITLE}}", [System.Net.WebUtility]::HtmlEncode($pageTitle))
$html = $html.Replace("{{COMMAND_COUNT}}", $commandCountText)
$html = $html.Replace("{{ROWS}}", $rowsBuilder.ToString().TrimEnd())

# Ensure output directory exists
$outDir = [System.IO.Path]::GetDirectoryName($resolvedOutputPath)
if ($outDir -and -not (Test-Path -Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# Write output file as UTF-8
[System.IO.File]::WriteAllText($resolvedOutputPath, $html, [System.Text.Encoding]::UTF8)

Write-Host "Successfully generated: $resolvedOutputPath ($totalCommands commands)" -ForegroundColor Green
