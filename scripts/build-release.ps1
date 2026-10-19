[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$')]
    [string]$Version,

    [switch]$IncludePortableNode,
    [string]$NodeArchivePath,
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$NodeArchiveSha256,

    [string]$InnoCompilerPath,
    [switch]$SkipInstaller,
    [switch]$RequireInstaller,

    [switch]$SignArtifacts,
    [switch]$RequireSignature,
    [string]$CertificateThumbprint,
    [string]$CertificatePfxPath,
    [Security.SecureString]$CertificatePfxPassword,
    [string]$TimestampServer = "http://timestamp.digicert.com",

    [ValidateSet("stable")]
    [string]$UpdateChannel = "stable",
    [string]$UpdateManifestUrl,
    [string]$UpdateInstallerUrl,
    [ValidateLength(0, 4000)]
    [string]$ReleaseNotes = "",

    [switch]$AllowVersionMismatch,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$releaseRoot = Join-Path $repositoryRoot "release"
$workRoot = Join-Path $releaseRoot "work"
$artifactsRoot = Join-Path $releaseRoot "artifacts"
$artifactDirectory = Join-Path $artifactsRoot $Version
$stageDirectory = Join-Path $workRoot ("{0}-{1}-{2}" -f $Version, $PID, [Guid]::NewGuid().ToString("N"))
$payloadDirectory = Join-Path $stageDirectory "payload"
$packageAllowlistPath = Join-Path $releaseRoot "package-files.txt"
$innoSourcePath = Join-Path $repositoryRoot "installer\UlanziLibreBridge.iss"
$forbiddenSegments = @(
    ".git", ".runtime", ".secrets", ".tools", "backups", "firmware",
    "node_modules", "coverage", ".install", ".config-history", ".updates",
    "diagnostics", "diagnosticos", "logs", "data", "dados", "exports",
    "rollback"
)
$signingCertificate = $null
$updatePublisher = $null

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $fullCandidate = [IO.Path]::GetFullPath($Candidate)
    $fullParent = [IO.Path]::GetFullPath($Parent).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    return $fullCandidate.StartsWith($fullParent, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-SafeRelativePackagePath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "A allowlist contém um caminho inválido: '$RelativePath'."
    }

    $normalized = $RelativePath.Replace('/', '\').Trim()
    if ($normalized.Contains(':') -or $normalized -match '(^|\\)\.\.(\\|$)') {
        throw "A allowlist contém travessia de diretório: '$RelativePath'."
    }

    $segments = @($normalized -split '\\')
    foreach ($segment in $segments) {
        if ($segment -match '(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') {
            throw "A allowlist contém um nome reservado do Windows: '$RelativePath'."
        }
        if ($forbiddenSegments -icontains $segment) {
            throw "O caminho '$RelativePath' pertence a uma área que nunca pode ser publicada."
        }
    }

    $leaf = $segments[$segments.Count - 1]
    if ($leaf -like ".env*" -and $normalized -ine ".env.example") {
        throw "O caminho '$RelativePath' pode conter configuração local e foi recusado."
    }
    if ($leaf -match '(?i)(secret|credential|token).*(json|txt|env)$') {
        throw "O caminho '$RelativePath' parece conter credenciais e foi recusado."
    }
    if ([IO.Path]::GetExtension($leaf) -match '(?i)^\.(bak|backup|bin|dmp|log|tmp|zip)$') {
        throw "O caminho '$RelativePath' parece ser um artefato ou dado local e foi recusado."
    }
    if ([IO.Path]::GetExtension($leaf) -ieq ".json" -and $normalized -inotmatch '^(package\.json|locales\\(en|pt-BR)\.json)$') {
        throw "Arquivos JSON locais não entram no payload pela allowlist: '$RelativePath'."
    }

    return $normalized
}

function Assert-NoReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$StopAt
    )

    $file = Get-Item -LiteralPath $FilePath -Force
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Links e junctions não são aceitos no pacote: $($file.FullName)"
    }
    $cursor = $file.Directory
    while ($null -ne $cursor) {
        if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Links e junctions não são aceitos no pacote: $($cursor.FullName)"
        }
        if ($cursor.FullName -ieq $StopAt) { break }
        $cursor = $cursor.Parent
    }
}

function Get-PackageAllowlist {
    if (-not (Test-Path -LiteralPath $packageAllowlistPath -PathType Leaf)) {
        throw "Allowlist não encontrada: $packageAllowlistPath"
    }

    $seen = @{}
    $result = [Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $packageAllowlistPath -Encoding UTF8) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) { continue }
        $relativePath = Assert-SafeRelativePackagePath -RelativePath $trimmed
        if ($seen.ContainsKey($relativePath)) {
            throw "Arquivo repetido na allowlist: $relativePath"
        }
        $seen[$relativePath] = $true
        $result.Add($relativePath)
    }
    if ($result.Count -eq 0) { throw "A allowlist do pacote está vazia." }
    return $result
}

function Copy-AllowlistedPayload {
    param([Parameter(Mandatory = $true)][Collections.Generic.List[string]]$RelativePaths)

    foreach ($relativePath in $RelativePaths) {
        $sourcePath = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $relativePath))
        if (-not (Test-PathInside -Candidate $sourcePath -Parent $repositoryRoot)) {
            throw "O arquivo saiu da raiz do projeto: $relativePath"
        }
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Arquivo obrigatório ausente da release: $relativePath"
        }
        Assert-NoReparsePoint -FilePath $sourcePath -StopAt $repositoryRoot

        $destinationPath = Join-Path $payloadDirectory $relativePath
        $destinationParent = Split-Path -Parent $destinationPath
        [void](New-Item -ItemType Directory -Force -Path $destinationParent)
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
    }
}

function Assert-ExampleEnvironmentHasNoSecrets {
    $examplePath = Join-Path $payloadDirectory ".env.example"
    $sensitiveNames = @(
        "AWTRIX_PASSWORD", "NIGHTSCOUT_TOKEN", "NIGHTSCOUT_API_SECRET",
        "JSON_SOURCE_TOKEN"
    )
    foreach ($line in Get-Content -LiteralPath $examplePath -Encoding UTF8) {
        if ($line -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { continue }
        if ($sensitiveNames -icontains $Matches[1] -and -not [string]::IsNullOrWhiteSpace($Matches[2])) {
            throw ".env.example contém um valor para $($Matches[1]); a publicação foi bloqueada."
        }
    }
}

function Assert-SafeArchiveEntries {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrWhiteSpace($entry.FullName)) { continue }
            $entryName = $entry.FullName.Replace('/', '\')
            if ([IO.Path]::IsPathRooted($entryName) -or $entryName.Contains(':') -or $entryName -match '(^|\\)\.\.(\\|$)') {
                throw "O arquivo do Node contém um caminho inseguro: $($entry.FullName)"
            }
            foreach ($segment in @($entryName -split '\\')) {
                if ($segment -match '(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') {
                    throw "O arquivo do Node contém um nome reservado do Windows: $($entry.FullName)"
                }
            }
            $entryDestination = [IO.Path]::GetFullPath((Join-Path $Destination $entryName))
            if (-not (Test-PathInside -Candidate $entryDestination -Parent $Destination)) {
                throw "O arquivo do Node tentou sair da pasta temporária: $($entry.FullName)"
            }
        }
    } finally {
        $archive.Dispose()
    }
}

function Add-PortableNodeRuntime {
    if (-not $IncludePortableNode) { return $null }
    if ([string]::IsNullOrWhiteSpace($NodeArchivePath) -or [string]::IsNullOrWhiteSpace($NodeArchiveSha256)) {
        throw "Use -NodeArchivePath e -NodeArchiveSha256 ao incluir o Node portátil. Nenhum download é feito automaticamente."
    }

    $archivePath = [IO.Path]::GetFullPath($NodeArchivePath)
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw "Arquivo do Node portátil não encontrado: $archivePath"
    }
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    if ($actualHash -ine $NodeArchiveSha256) {
        throw "Hash SHA-256 do Node portátil inválido. Esperado $NodeArchiveSha256; obtido $actualHash."
    }

    $nodeExtractionDirectory = Join-Path $stageDirectory "node-extracted"
    [void](New-Item -ItemType Directory -Path $nodeExtractionDirectory)
    Assert-SafeArchiveEntries -ArchivePath $archivePath -Destination $nodeExtractionDirectory
    Expand-Archive -LiteralPath $archivePath -DestinationPath $nodeExtractionDirectory

    $reparsePoint = Get-ChildItem -LiteralPath $nodeExtractionDirectory -Recurse -Force |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } |
        Select-Object -First 1
    if ($null -ne $reparsePoint) {
        throw "O arquivo do Node contém um link não permitido: $($reparsePoint.FullName)"
    }

    $nodeExecutables = @(Get-ChildItem -LiteralPath $nodeExtractionDirectory -Recurse -File -Filter "node.exe")
    if ($nodeExecutables.Count -ne 1) {
        throw "O arquivo do Node deve conter exatamente um node.exe; encontrados: $($nodeExecutables.Count)."
    }
    $nodeRoot = Split-Path -Parent $nodeExecutables[0].FullName
    $reportedVersion = (& $nodeExecutables[0].FullName --version).Trim()
    if ($LASTEXITCODE -ne 0 -or $reportedVersion -notmatch '^v([0-9]+)\.') {
        throw "Não foi possível validar a versão do Node portátil."
    }
    if ([int]$Matches[1] -lt 22) {
        throw "O runtime portátil precisa ser Node 22 ou mais recente; encontrado $reportedVersion."
    }

    $runtimeDestination = Join-Path $payloadDirectory "runtime\node"
    [void](New-Item -ItemType Directory -Force -Path $runtimeDestination)
    # The app has no npm runtime dependencies. Shipping npm/corepack would add
    # thousands of unused files and conflict with the installer's data guard.
    foreach ($runtimeFileName in @("node.exe", "LICENSE")) {
        $runtimeFilePath = Join-Path $nodeRoot $runtimeFileName
        if (-not (Test-Path -LiteralPath $runtimeFilePath -PathType Leaf)) {
            throw "Required Node.js runtime file is missing: $runtimeFileName"
        }
        Copy-Item -LiteralPath $runtimeFilePath -Destination (Join-Path $runtimeDestination $runtimeFileName)
    }

    return [ordered]@{
        version = $reportedVersion.TrimStart('v')
        archiveSha256 = $actualHash.ToLowerInvariant()
        archiveName = [IO.Path]::GetFileName($archivePath)
    }
}

function Get-CodeSigningCertificate {
    $hasThumbprint = -not [string]::IsNullOrWhiteSpace($CertificateThumbprint)
    $hasPfx = -not [string]::IsNullOrWhiteSpace($CertificatePfxPath)
    if ($hasThumbprint -and $hasPfx) {
        throw "Escolha CertificateThumbprint ou CertificatePfxPath, não os dois."
    }
    if (-not $hasThumbprint -and -not $hasPfx) {
        throw "Uma assinatura foi solicitada, mas nenhum certificado foi fornecido."
    }

    if ($hasThumbprint) {
        $normalizedThumbprint = ($CertificateThumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
        if ($normalizedThumbprint -notmatch '^[0-9A-F]{40}$') {
            throw "CertificateThumbprint deve conter os 40 dígitos hexadecimais do certificado."
        }
        $certificate = $null
        foreach ($storeLocation in @("Cert:\CurrentUser\My", "Cert:\LocalMachine\My")) {
            $candidate = Join-Path $storeLocation $normalizedThumbprint
            if (Test-Path -LiteralPath $candidate) {
                $certificate = Get-Item -LiteralPath $candidate
                break
            }
        }
        if ($null -eq $certificate) { throw "Certificado de assinatura não encontrado pelo thumbprint informado." }
    } else {
        $fullPfxPath = [IO.Path]::GetFullPath($CertificatePfxPath)
        if (-not (Test-Path -LiteralPath $fullPfxPath -PathType Leaf)) {
            throw "Arquivo PFX não encontrado: $fullPfxPath"
        }
        if ($null -eq $CertificatePfxPassword) {
            throw "CertificatePfxPassword deve ser fornecido como SecureString; PFX sem senha não é aceito para uma release pública."
        }
        $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $fullPfxPath,
            $CertificatePfxPassword,
            $flags
        )
    }

    if (-not $certificate.HasPrivateKey) { throw "O certificado não possui chave privada." }
    $now = Get-Date
    if ($now -lt $certificate.NotBefore -or $now -ge $certificate.NotAfter) {
        throw "O certificado está fora do período de validade."
    }
    $ekuExtension = $certificate.Extensions |
        Where-Object { $_.Oid.Value -eq "2.5.29.37" } |
        Select-Object -First 1
    if ($null -eq $ekuExtension) {
        throw "O certificado não declara o uso estendido para assinatura de código."
    }
    $enhancedKeyUsage = [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new(
        $ekuExtension,
        $ekuExtension.Critical
    )
    $codeSigningEku = $enhancedKeyUsage.EnhancedKeyUsages |
        Where-Object { $_.Value -eq "1.3.6.1.5.5.7.3.3" } |
        Select-Object -First 1
    if ($null -eq $codeSigningEku) {
        throw "O certificado não é válido para assinatura de código."
    }
    return $certificate
}

function Set-RequiredAuthenticodeSignature {
    param([Parameter(Mandatory = $true)][string]$Path)

    $parameters = @{
        FilePath = $Path
        Certificate = $signingCertificate
        HashAlgorithm = "SHA256"
    }
    if (-not [string]::IsNullOrWhiteSpace($TimestampServer)) {
        $parameters.TimestampServer = $TimestampServer
    }
    $signature = Set-AuthenticodeSignature @parameters
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
        throw "A assinatura Authenticode de '$Path' não ficou válida: $($signature.Status) $($signature.StatusMessage)"
    }
}

function Write-PayloadChecksums {
    $entries = [Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $payloadDirectory -Recurse -File | Sort-Object FullName) {
        if ($file.Name -ieq "checksums.sha256") { continue }
        $relative = $file.FullName.Substring($payloadDirectory.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $entries.Add("$hash *$relative")
    }
    $checksumPath = Join-Path $payloadDirectory "checksums.sha256"
    [IO.File]::WriteAllLines($checksumPath, $entries, [Text.UTF8Encoding]::new($false))
}

function Find-InnoCompiler {
    if (-not [string]::IsNullOrWhiteSpace($InnoCompilerPath)) {
        $candidate = [IO.Path]::GetFullPath($InnoCompilerPath)
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Compilador do Inno Setup não encontrado: $candidate"
        }
        return $candidate
    }

    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    $candidates = [Collections.Generic.List[string]]::new()
    $installationRoots = @(
        $(if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            Join-Path $env:LOCALAPPDATA "Programs"
        }),
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($innoVersion in @("Inno Setup 7", "Inno Setup 6")) {
        foreach ($installationRoot in $installationRoots) {
            $candidates.Add((Join-Path $installationRoot "$innoVersion\ISCC.exe"))
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return $null
}

function Get-ValidatedHttpsReleaseUri {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$ExpectedFileName,
        [Parameter(Mandatory = $true)][string]$ParameterName
    )

    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) {
        throw "$ParameterName não contém uma URL absoluta válida."
    }
    if ($uri.Scheme -cne "https") {
        throw "$ParameterName deve usar HTTPS."
    }
    if (-not [string]::IsNullOrWhiteSpace($uri.UserInfo) -or
        -not [string]::IsNullOrWhiteSpace($uri.Fragment) -or
        -not [string]::IsNullOrWhiteSpace($uri.Query)) {
        throw "$ParameterName não pode conter credenciais, fragmento ou query temporária."
    }
    if ($uri.Host -match '(?i)(^|\.)example\.(com|org|net)$|(^|\.)(example|invalid|localhost|test)$') {
        throw "$ParameterName ainda usa um domínio de exemplo e foi recusada."
    }
    $remoteFileName = [Uri]::UnescapeDataString([IO.Path]::GetFileName($uri.AbsolutePath))
    if ($remoteFileName -cne $ExpectedFileName) {
        throw "$ParameterName deve terminar com o nome exato: $ExpectedFileName"
    }
    return $uri.AbsoluteUri
}

function Set-PayloadUpdatePins {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestUrl,
        [Parameter(Mandatory = $true)][string]$Channel,
        [Parameter(Mandatory = $true)][string]$Publisher
    )

    if ($Publisher -match '[#=\x00-\x1f\x7f]') {
        throw "O publicador contém caracteres que não podem ser gravados no pin local."
    }
    $values = [ordered]@{
        UPDATE_MANIFEST_URL = $ManifestUrl
        UPDATE_CHANNEL = $Channel
        UPDATE_EXPECTED_PUBLISHER = $Publisher
    }

    $envExamplePath = Join-Path $payloadDirectory ".env.example"
    $envText = [IO.File]::ReadAllText($envExamplePath)
    foreach ($name in $values.Keys) {
        $pattern = "(?m)^$([regex]::Escape($name))=.*$"
        $matches = [regex]::Matches($envText, $pattern)
        if ($matches.Count -ne 1) {
            throw "Não foi possível fixar $name uma única vez em .env.example."
        }
        $replacement = "$name=$($values[$name])"
        $envText = [regex]::Replace(
            $envText,
            $pattern,
            [Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement }
        )
    }
    [IO.File]::WriteAllText($envExamplePath, $envText, [Text.UTF8Encoding]::new($false))

    $configuratorPath = Join-Path $payloadDirectory "scripts\configurar.ps1"
    $configuratorText = [IO.File]::ReadAllText($configuratorPath)
    foreach ($name in $values.Keys) {
        $pattern = "(?m)^(\s*)[`"']$([regex]::Escape($name))=.*[`"'](,?)\s*$"
        $matches = [regex]::Matches($configuratorText, $pattern)
        if ($matches.Count -ne 1) {
            throw "Não foi possível fixar $name uma única vez no configurador empacotado."
        }
        $escapedValue = ([string]$values[$name]).Replace("'", "''")
        $configuratorText = [regex]::Replace(
            $configuratorText,
            $pattern,
            [Text.RegularExpressions.MatchEvaluator]{
                param($match)
                return "$($match.Groups[1].Value)'$name=$escapedValue'$($match.Groups[2].Value)"
            }
        )
    }
    [IO.File]::WriteAllText($configuratorPath, $configuratorText, [Text.UTF8Encoding]::new($false))
}

if ($SkipInstaller -and $RequireInstaller) {
    throw "SkipInstaller e RequireInstaller não podem ser usados juntos."
}
if ($SkipInstaller -and $RequireSignature) {
    throw "RequireSignature exige que o instalador seja compilado; remova SkipInstaller."
}
if ($RequireSignature -and [string]::IsNullOrWhiteSpace($TimestampServer)) {
    throw "RequireSignature exige um servidor de timestamp para manter a assinatura verificável."
}
if ([string]::IsNullOrWhiteSpace($UpdateManifestUrl) -ne [string]::IsNullOrWhiteSpace($UpdateInstallerUrl)) {
    throw "UpdateManifestUrl e UpdateInstallerUrl devem ser informados juntos."
}
if (-not [string]::IsNullOrWhiteSpace($UpdateInstallerUrl) -and -not $RequireSignature) {
    throw "Um feed de atualização só pode ser gerado com -RequireSignature."
}
if ($RequireSignature) { $SignArtifacts = $true }
$validatedUpdateManifestUrl = $null
$validatedUpdateInstallerUrl = $null
if (-not [string]::IsNullOrWhiteSpace($UpdateInstallerUrl)) {
    $expectedInstallerName = "Ulanzi-Libre-Bridge-Setup-$Version.exe"
    $validatedUpdateManifestUrl = Get-ValidatedHttpsReleaseUri `
        -Value $UpdateManifestUrl `
        -ExpectedFileName "update-manifest.json" `
        -ParameterName "UpdateManifestUrl"
    $validatedUpdateInstallerUrl = Get-ValidatedHttpsReleaseUri `
        -Value $UpdateInstallerUrl `
        -ExpectedFileName $expectedInstallerName `
        -ParameterName "UpdateInstallerUrl"
}

$packageJson = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot "package.json") | ConvertFrom-Json
if ($Version.Contains('-') -and @((($Version -split '-', 2)[1] -split '\.') | Where-Object { $_ -match '^0[0-9]+$' }).Count -gt 0) {
    throw "A versão solicitada não usa identificadores SemVer válidos com zeros à esquerda."
}
if (-not $AllowVersionMismatch -and [string]$packageJson.version -cne $Version) {
    throw "A versão solicitada ($Version) difere de package.json ($($packageJson.version)). Atualize o projeto ou use -AllowVersionMismatch conscientemente."
}

if ($SignArtifacts) {
    $signingCertificate = Get-CodeSigningCertificate
}
if ($null -ne $validatedUpdateManifestUrl) {
    $updatePublisher = $signingCertificate.GetNameInfo(
        [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
        $false
    )
    if ([string]::IsNullOrWhiteSpace($updatePublisher)) {
        $updatePublisher = $signingCertificate.Subject
    }
    $updatePublisher = $updatePublisher.Trim()
    if ([string]::IsNullOrWhiteSpace($updatePublisher) -or $updatePublisher.Length -gt 200) {
        throw "O nome do publicador do certificado não cabe no contrato do feed de atualização."
    }
}

[void](New-Item -ItemType Directory -Force -Path $workRoot)
[void](New-Item -ItemType Directory -Force -Path $artifactsRoot)
if (Test-Path -LiteralPath $artifactDirectory) {
    if (-not $Force) {
        throw "A pasta da release já existe: $artifactDirectory. Use -Force para substituí-la."
    }
    if (-not (Test-PathInside -Candidate $artifactDirectory -Parent $artifactsRoot)) {
        throw "A pasta de saída não passou pela validação de segurança."
    }
    Remove-Item -LiteralPath $artifactDirectory -Recurse -Force
}
[void](New-Item -ItemType Directory -Path $artifactDirectory)
[void](New-Item -ItemType Directory -Path $payloadDirectory)

try {
    $allowlist = Get-PackageAllowlist
    Copy-AllowlistedPayload -RelativePaths $allowlist
    Assert-ExampleEnvironmentHasNoSecrets
    if ($null -ne $validatedUpdateManifestUrl) {
        Set-PayloadUpdatePins `
            -ManifestUrl $validatedUpdateManifestUrl `
            -Channel $UpdateChannel `
            -Publisher $updatePublisher
    }
    $nodeMetadata = Add-PortableNodeRuntime

    $buildInformation = [ordered]@{
        formatVersion = 1
        application = "Ulanzi Libre Bridge"
        version = $Version
        createdAt = (Get-Date).ToUniversalTime().ToString("o")
        portableNode = $nodeMetadata
    }
    [IO.File]::WriteAllText(
        (Join-Path $payloadDirectory "build-info.json"),
        (($buildInformation | ConvertTo-Json -Depth 5) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )

    if ($SignArtifacts) {
        foreach ($scriptFile in Get-ChildItem -LiteralPath $payloadDirectory -Recurse -File -Filter "*.ps1") {
            Set-RequiredAuthenticodeSignature -Path $scriptFile.FullName
        }
    }

    Write-PayloadChecksums

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $nodeSuffix = if ($IncludePortableNode) { "-portable-node" } else { "" }
    $zipName = "Ulanzi-Libre-Bridge-$Version-win-x64$nodeSuffix.zip"
    $zipPath = Join-Path $artifactDirectory $zipName
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $payloadDirectory,
        $zipPath,
        [IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    $installerPath = $null
    if (-not $SkipInstaller) {
        $compiler = Find-InnoCompiler
        if ($null -eq $compiler) {
            if ($RequireInstaller -or $RequireSignature) {
                throw "O compilador do Inno Setup não foi encontrado e o instalador é obrigatório para esta build."
            }
            Write-Warning "O compilador do Inno Setup não foi encontrado; o ZIP foi criado, mas o instalador não foi compilado."
        } else {
            if (-not (Test-Path -LiteralPath $innoSourcePath -PathType Leaf)) {
                throw "Fonte do instalador não encontrado: $innoSourcePath"
            }
            $numericVersion = (($Version -split '-')[0] + ".0")
            $innoArguments = @(
                "/DAppVersion=$Version",
                "/DAppVersionNumeric=$numericVersion",
                "/DSourceDir=$payloadDirectory",
                "/DOutputDir=$artifactDirectory",
                $innoSourcePath
            )
            & $compiler @innoArguments
            if ($LASTEXITCODE -ne 0) { throw "O Inno Setup encerrou com o código $LASTEXITCODE." }
            $installerPath = Join-Path $artifactDirectory "Ulanzi-Libre-Bridge-Setup-$Version.exe"
            if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
                throw "O Inno Setup não produziu o instalador esperado: $installerPath"
            }
            if ($SignArtifacts) { Set-RequiredAuthenticodeSignature -Path $installerPath }
        }
    }

    $artifactRecords = [Collections.Generic.List[object]]::new()
    foreach ($artifact in Get-ChildItem -LiteralPath $artifactDirectory -File | Sort-Object Name) {
        $artifactRecords.Add([ordered]@{
            file = $artifact.Name
            size = $artifact.Length
            sha256 = (Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            authenticodeRequired = ($artifact.Extension -ieq ".exe" -and [bool]$SignArtifacts)
            signerSubject = if ($artifact.Extension -ieq ".exe" -and $SignArtifacts) { $signingCertificate.Subject } else { $null }
        })
    }
    $artifactManifest = [ordered]@{
        schemaVersion = 1
        version = $Version
        generatedAt = (Get-Date).ToUniversalTime().ToString("o")
        artifacts = $artifactRecords
    }
    $artifactManifestPath = Join-Path $artifactDirectory "artifact-manifest.json"
    [IO.File]::WriteAllText(
        $artifactManifestPath,
        (($artifactManifest | ConvertTo-Json -Depth 6) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )

    $updateManifestPath = $null
    if (-not [string]::IsNullOrWhiteSpace($UpdateInstallerUrl)) {
        if ($null -eq $installerPath) {
            throw "UpdateInstallerUrl foi informado, mas nenhum instalador foi compilado."
        }
        $updateManifest = [ordered]@{
            schemaVersion = 1
            channel = $UpdateChannel
            version = $Version
            publishedAt = (Get-Date).ToUniversalTime().ToString("o")
            notes = $ReleaseNotes
            installer = [ordered]@{
                url = $validatedUpdateInstallerUrl
                fileName = [IO.Path]::GetFileName($installerPath)
                sha256 = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
                requireAuthenticode = $true
                publisher = $updatePublisher
            }
        }
        $updateManifestPath = Join-Path $artifactDirectory "update-manifest.json"
        [IO.File]::WriteAllText(
            $updateManifestPath,
            (($updateManifest | ConvertTo-Json -Depth 5) + [Environment]::NewLine),
            [Text.UTF8Encoding]::new($false)
        )
    }

    $checksumLines = [Collections.Generic.List[string]]::new()
    foreach ($artifact in Get-ChildItem -LiteralPath $artifactDirectory -File | Where-Object { $_.Name -ne "SHA256SUMS.txt" } | Sort-Object Name) {
        $hash = (Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $checksumLines.Add("$hash *$($artifact.Name)")
    }
    [IO.File]::WriteAllLines(
        (Join-Path $artifactDirectory "SHA256SUMS.txt"),
        $checksumLines,
        [Text.UTF8Encoding]::new($false)
    )

    Write-Host "Release preparada em: $artifactDirectory"
    Write-Host "Arquivos copiados pela allowlist: $($allowlist.Count)"
    Write-Host "Runtime Node portátil: $(if ($IncludePortableNode) { $nodeMetadata.version } else { 'não incluído' })"
    Write-Host "Instalador: $(if ($null -ne $installerPath) { $installerPath } else { 'não compilado' })"
    Write-Host "Assinatura Authenticode: $(if ($SignArtifacts) { 'aplicada e validada' } else { 'não solicitada' })"
    Write-Host "Feed de atualização: $(if ($null -ne $updateManifestPath) { $updateManifestPath } else { 'não gerado; informe URL HTTPS real e assinatura obrigatória' })"
} finally {
    if (Test-Path -LiteralPath $stageDirectory) {
        if (-not (Test-PathInside -Candidate $stageDirectory -Parent $workRoot)) {
            throw "A pasta temporária não passou pela validação de segurança e não foi removida."
        }
        Remove-Item -LiteralPath $stageDirectory -Recurse -Force
    }
}
