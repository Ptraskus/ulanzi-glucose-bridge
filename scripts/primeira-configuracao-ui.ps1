Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "ui-language.ps1")

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

function Test-UlanziWizardUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$RequireHttpsOutsideLocalhost,
        [switch]$DisallowPath
    )

    $candidate = $Value.Trim()
    $uri = $null
    if (
        [string]::IsNullOrWhiteSpace($candidate) -or
        -not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @("http", "https")
    ) {
        throw (Get-UlanziText -Key '{0} deve comecar com http:// ou https:// e conter um endereco valido.' -Arguments @(($Label)))
    }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo) -or -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw (Get-UlanziText -Key '{0} nao deve conter usuario, senha ou fragmento no endereco.' -Arguments @(($Label)))
    }
    if ($DisallowPath -and $uri.AbsolutePath -ne "/") {
        throw (Get-UlanziText -Key '{0} nao deve conter um caminho depois do nome ou IP.' -Arguments @(($Label)))
    }
    if (-not [string]::IsNullOrEmpty($uri.Query)) {
        throw (Get-UlanziText -Key '{0} nao deve conter parametros depois de um ponto de interrogacao.' -Arguments @(($Label)))
    }
    if ($RequireHttpsOutsideLocalhost -and $uri.Scheme -ne "https") {
        $hostName = $uri.DnsSafeHost.ToLowerInvariant()
        $isLocal = $hostName -eq "localhost" -or $hostName -eq "::1" -or $hostName -match '^127(?:\.[0-9]{1,3}){3}$'
        if (-not $isLocal) { throw (Get-UlanziText -Key '{0} deve usar https:// para proteger os dados.' -Arguments @(($Label))) }
    }
    return $uri
}

function Join-UlanziApiUrl {
    param(
        [Parameter(Mandatory = $true)][Uri]$BaseUri,
        [Parameter(Mandatory = $true)][string]$ApiPath,
        [AllowEmptyString()][string]$Query = ""
    )

    $builder = [UriBuilder]::new($BaseUri)
    $basePath = $builder.Path.TrimEnd("/")
    $builder.Path = "$basePath$ApiPath"
    $builder.Query = $Query
    $builder.Fragment = ""
    return $builder.Uri
}

function Get-UlanziSha1Hex {
    param([Parameter(Mandatory = $true)][string]$Value)

    $sha1 = [Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        return ([BitConverter]::ToString($sha1.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha1.Dispose()
    }
}

function Invoke-UlanziWizardGet {
    param(
        [Parameter(Mandatory = $true)][Uri]$Uri,
        [hashtable]$Headers = @{},
        [int]$TimeoutMilliseconds = 5000,
        [string]$EndpointLabel = (Get-UlanziText -Key 'o servico'),
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )

    $CancellationToken.ThrowIfCancellationRequested()
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Uri)
    try {
        $client.Timeout = [TimeSpan]::FromMilliseconds($TimeoutMilliseconds)
        [void]$request.Headers.TryAddWithoutValidation("Accept", "application/json")
        foreach ($name in $Headers.Keys) {
            [void]$request.Headers.TryAddWithoutValidation([string]$name, [string]$Headers[$name])
        }
        $response = $client.SendAsync($request, $CancellationToken).GetAwaiter().GetResult()
        try {
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $CancellationToken.ThrowIfCancellationRequested()
            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                IsSuccess = [bool]$response.IsSuccessStatusCode
                Body = [string]$body
            }
        } finally {
            $response.Dispose()
        }
    } catch [Threading.Tasks.TaskCanceledException] {
        if ($CancellationToken.IsCancellationRequested) {
            throw [OperationCanceledException]::new((Get-UlanziText -Key 'Operacao cancelada.'), $_.Exception, $CancellationToken)
        }
        $timeoutSeconds = [Math]::Max(1, [Math]::Ceiling($TimeoutMilliseconds / 1000))
        throw (Get-UlanziText -Key 'A conexao com {0} demorou mais de {1} segundos. Confira o endereco, a rede e tente novamente.' -Arguments @(($EndpointLabel), ($timeoutSeconds)))
    } catch [OperationCanceledException] {
        throw
    } catch {
        # Never include the request URL or a server-provided body here: the URL
        # can contain a Nightscout token and error bodies can echo credentials.
        throw (Get-UlanziText -Key 'Nao foi possivel conectar com {0}. Verifique o endereco e a rede.' -Arguments @(($EndpointLabel)))
    } finally {
        $request.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-UlanziBasicHeader {
    param(
        [AllowEmptyString()][string]$Username,
        [AllowEmptyString()][string]$Password
    )

    if ([string]::IsNullOrWhiteSpace($Username) -and [string]::IsNullOrEmpty($Password)) { return @{} }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$Username`:$Password"))
    return @{ Authorization = "Basic $encoded" }
}

function Test-UlanziNightscoutConnection {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][ValidateSet("token", "api-secret", "public")][string]$Authentication,
        [AllowEmptyString()][string]$Secret,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )

    $baseUri = Test-UlanziWizardUrl -Value $BaseUrl -Label (Get-UlanziText -Key 'A URL do Nightscout') -RequireHttpsOutsideLocalhost
    if ($Authentication -ne "public" -and [string]::IsNullOrWhiteSpace($Secret)) {
        throw (Get-UlanziText -Key 'Informe a credencial do Nightscout antes de testar.')
    }
    $queryParts = [Collections.Generic.List[string]]::new()
    $queryParts.Add("count=1")
    $headers = @{}
    if ($Authentication -eq "token") {
        $queryParts.Add("token=$([Uri]::EscapeDataString($Secret))")
    } elseif ($Authentication -eq "api-secret") {
        $headers["api-secret"] = Get-UlanziSha1Hex -Value $Secret
    }
    $uri = Join-UlanziApiUrl -BaseUri $baseUri -ApiPath "/api/v1/entries/sgv.json" -Query ($queryParts -join "&")
    $response = Invoke-UlanziWizardGet -Uri $uri -Headers $headers -EndpointLabel (Get-UlanziText -Key 'o Nightscout') -CancellationToken $CancellationToken
    if ($response.StatusCode -in @(301, 302, 307, 308)) {
        throw (Get-UlanziText -Key 'O Nightscout redirecionou a conexao. Informe a URL HTTPS final.')
    }
    if ($response.StatusCode -in @(401, 403)) { throw (Get-UlanziText -Key 'O Nightscout recusou a credencial informada.') }
    if (-not $response.IsSuccess) { throw (Get-UlanziText -Key 'O Nightscout respondeu com erro HTTP {0}.' -Arguments @(($($response.StatusCode)))) }
    try {
        $entries = @($response.Body | ConvertFrom-Json)
    } catch {
        throw (Get-UlanziText -Key 'O Nightscout respondeu em um formato inesperado.')
    }
    $hasSgv = $entries.Count -ge 1 -and $null -ne $entries[0].PSObject.Properties["sgv"]
    $hasGlucose = $entries.Count -ge 1 -and $null -ne $entries[0].PSObject.Properties["glucose"]
    if ($entries.Count -lt 1 -or (-not $hasSgv -and -not $hasGlucose)) {
        throw (Get-UlanziText -Key 'O Nightscout conectou, mas nao retornou uma leitura de glicemia.')
    }
    return (Get-UlanziText -Key 'Nightscout conectado e leitura encontrada.')
}

function Test-UlanziJsonConnection {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [AllowEmptyString()][string]$Token,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )

    $uri = Test-UlanziWizardUrl -Value $Url -Label (Get-UlanziText -Key 'A URL da fonte JSON') -RequireHttpsOutsideLocalhost
    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($Token)) { $headers.Authorization = "Bearer $Token" }
    $response = Invoke-UlanziWizardGet -Uri $uri -Headers $headers -EndpointLabel (Get-UlanziText -Key 'a fonte JSON') -CancellationToken $CancellationToken
    if ($response.StatusCode -in @(301, 302, 307, 308)) { throw (Get-UlanziText -Key 'A fonte JSON redirecionou a conexao. Informe a URL final.') }
    if ($response.StatusCode -in @(401, 403)) { throw (Get-UlanziText -Key 'A fonte JSON recusou a credencial informada.') }
    if (-not $response.IsSuccess) { throw (Get-UlanziText -Key 'A fonte JSON respondeu com erro HTTP {0}.' -Arguments @(($($response.StatusCode)))) }
    try { $reading = $response.Body | ConvertFrom-Json } catch { throw (Get-UlanziText -Key 'A fonte JSON respondeu em um formato inesperado.') }
    if (
        $null -eq $reading -or
        $null -eq $reading.PSObject.Properties["valueMgDl"] -or
        $null -eq $reading.PSObject.Properties["timestamp"]
    ) {
        throw (Get-UlanziText -Key 'A resposta JSON nao contem valueMgDl e timestamp.')
    }
    return (Get-UlanziText -Key 'Fonte JSON conectada e leitura encontrada.')
}

function Test-UlanziAwtrixConnection {
    param(
        [Parameter(Mandatory = $true)][string]$HostUrl,
        [AllowEmptyString()][string]$Username,
        [AllowEmptyString()][string]$Password,
        [int]$TimeoutMilliseconds = 5000,
        [switch]$AllowAuthenticationRequired,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )

    $baseUri = Test-UlanziWizardUrl -Value $HostUrl -Label (Get-UlanziText -Key 'O endereco do TC001') -DisallowPath
    $headers = Get-UlanziBasicHeader -Username $Username -Password $Password
    $ngDeviceUri = Join-UlanziApiUrl -BaseUri $baseUri -ApiPath "/api/v1/device"
    $ngDevice = Invoke-UlanziWizardGet -Uri $ngDeviceUri -Headers $headers -TimeoutMilliseconds $TimeoutMilliseconds -EndpointLabel (Get-UlanziText -Key 'o TC001') -CancellationToken $CancellationToken
    if ($ngDevice.StatusCode -in @(401, 403)) {
        if ($AllowAuthenticationRequired) { return "auth-required" }
        throw (Get-UlanziText -Key 'O TC001 exige usuario e senha, ou recusou os dados informados.')
    }
    if ($ngDevice.IsSuccess) {
        try { $ngIdentity = $ngDevice.Body | ConvertFrom-Json } catch { $ngIdentity = $null }
        $boardTypeProperty = if ($null -ne $ngIdentity) { $ngIdentity.PSObject.Properties["boardType"] } else { $null }
        if ($null -ne $boardTypeProperty -and [string]$boardTypeProperty.Value -ceq "awtrixng") {
            return (Get-UlanziText -Key 'AWTRIX NG conectado.')
        }
    }

    # Compatibility fallback for early AWTRIX NG builds that expose the
    # version route but not the full device identity document.
    if ($ngDevice.StatusCode -in @(404, 405)) {
        $ngVersionUri = Join-UlanziApiUrl -BaseUri $baseUri -ApiPath "/api/v1/version"
        $ngVersion = Invoke-UlanziWizardGet -Uri $ngVersionUri -Headers $headers -TimeoutMilliseconds $TimeoutMilliseconds -EndpointLabel (Get-UlanziText -Key 'o TC001') -CancellationToken $CancellationToken
        if ($ngVersion.StatusCode -in @(401, 403)) {
            if ($AllowAuthenticationRequired) { return "auth-required" }
            throw (Get-UlanziText -Key 'O TC001 exige usuario e senha, ou recusou os dados informados.')
        }
        if ($ngVersion.IsSuccess) { return (Get-UlanziText -Key 'AWTRIX NG conectado (modo compativel).') }
    }

    $CancellationToken.ThrowIfCancellationRequested()
    $legacyUri = Join-UlanziApiUrl -BaseUri $baseUri -ApiPath "/api/stats"
    $legacy = Invoke-UlanziWizardGet -Uri $legacyUri -Headers $headers -TimeoutMilliseconds $TimeoutMilliseconds -EndpointLabel (Get-UlanziText -Key 'o TC001') -CancellationToken $CancellationToken
    if ($legacy.StatusCode -in @(401, 403)) {
        if ($AllowAuthenticationRequired) { return "auth-required" }
        throw (Get-UlanziText -Key 'O TC001 exige usuario e senha, ou recusou os dados informados.')
    }
    if ($legacy.IsSuccess) { return (Get-UlanziText -Key 'AWTRIX 3 conectado.') }
    throw (Get-UlanziText -Key 'O endereco respondeu, mas nao parece executar AWTRIX NG nem AWTRIX 3.')
}

function Find-UlanziAwtrix {
    param(
        [AllowEmptyString()][string]$CurrentAddress,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )

    # Safe discovery only: try the current address, the official AWTRIX NG UDP
    # discovery packet and a small allow-list of legacy/common mDNS names.
    # Deliberately do not scan the local subnet or enumerate unrelated devices.
    $candidates = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($CurrentAddress)) { $candidates.Add($CurrentAddress.Trim()) }

    if ($candidates.Count -eq 1) {
        $CancellationToken.ThrowIfCancellationRequested()
        try {
            $currentResult = Test-UlanziAwtrixConnection -HostUrl $candidates[0] -Username "" -Password "" -TimeoutMilliseconds 1500 -AllowAuthenticationRequired -CancellationToken $CancellationToken
            return [pscustomobject]@{
                Address = $candidates[0]
                AuthenticationRequired = $currentResult -eq "auth-required"
            }
        } catch [OperationCanceledException] {
            throw
        } catch {
            # A stale/manual address must not prevent official discovery.
            $candidates.Clear()
        }
    }

    $udp = $null
    try {
        $CancellationToken.ThrowIfCancellationRequested()
        $udp = [Net.Sockets.UdpClient]::new(4211)
        $udp.EnableBroadcast = $true
        $udp.Client.ReceiveTimeout = 2200
        $message = [Text.Encoding]::ASCII.GetBytes("FIND_AWTRIXNG")
        [void]$udp.Send($message, $message.Length, "255.255.255.255", 4210)
        $remoteEndpoint = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
        try {
            $replyBytes = $udp.Receive([ref]$remoteEndpoint)
            $CancellationToken.ThrowIfCancellationRequested()
            $reply = [Text.Encoding]::ASCII.GetString($replyBytes).Trim()
            if ($reply -match '^[A-Za-z0-9][A-Za-z0-9-]{0,62}(?::(?<port>[0-9]{1,5}))?$') {
                $portText = [string]$Matches["port"]
                $port = if ([string]::IsNullOrWhiteSpace($portText)) { 80 } else { [int]$portText }
                if ($port -ge 1 -and $port -le 65535) {
                    $address = "http://$($remoteEndpoint.Address)"
                    if ($port -ne 80) { $address = "$address`:$port" }
                    if (-not $candidates.Contains($address)) { $candidates.Add($address) }
                }
            }
        } catch [Net.Sockets.SocketException] {
            if ($_.Exception.SocketErrorCode -ne [Net.Sockets.SocketError]::TimedOut) { throw }
        }
    } catch [OperationCanceledException] {
        throw
    } catch {
        # Port 4211 may already be in use or a firewall may reject broadcasts.
        # The explicit address and mDNS fallbacks below remain available.
    } finally {
        if ($null -ne $udp) { $udp.Dispose() }
    }

    foreach ($candidate in @("http://awtrix-ng.local", "http://awtrix.local", "http://ulanzi.local")) {
        if (-not $candidates.Contains($candidate)) { $candidates.Add($candidate) }
    }
    foreach ($candidate in $candidates) {
        $CancellationToken.ThrowIfCancellationRequested()
        try {
            $result = Test-UlanziAwtrixConnection -HostUrl $candidate -Username "" -Password "" -TimeoutMilliseconds 1500 -AllowAuthenticationRequired -CancellationToken $CancellationToken
            return [pscustomobject]@{
                Address = $candidate
                AuthenticationRequired = $result -eq "auth-required"
            }
        } catch [OperationCanceledException] {
            throw
        } catch {
            # Continue only across this small allow-list of mDNS names.
        }
    }
    return $null
}

function Get-UlanziWizardSerialPorts {
    # Read-only hint for the USB preparation page. A serial port proves only
    # that Windows sees some serial device; it never identifies or flashes it.
    try { return @([IO.Ports.SerialPort]::GetPortNames() | Sort-Object) } catch { return @() }
}

function Open-UlanziWizardSafePage {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("awtrix-flashing", "awtrix-first-boot", "awtrix-provisioning")]
        [string]$Page
    )

    $allowedPages = @{
        "awtrix-flashing" = "https://blueforcer.github.io/awtrix-ng/getting-started/flashing/"
        "awtrix-first-boot" = "https://blueforcer.github.io/awtrix-ng/getting-started/first-boot/"
        "awtrix-provisioning" = "http://192.168.4.1/"
    }
    Start-Process -FilePath $allowedPages[$Page] -ErrorAction Stop
}

function New-UlanziWizardLabel {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height = 24,
        [switch]$Bold
    )

    $label = [Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.Location = [Drawing.Point]::new($X, $Y)
    $label.Size = [Drawing.Size]::new($Width, $Height)
    if ($Bold) { $label.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold) }
    return $label
}

function New-UlanziWizardTextBox {
    param([int]$X, [int]$Y, [int]$Width, [switch]$Password)

    $box = [Windows.Forms.TextBox]::new()
    $box.Location = [Drawing.Point]::new($X, $Y)
    $box.Size = [Drawing.Size]::new($Width, 27)
    $box.Font = [Drawing.Font]::new("Segoe UI", 9)
    $box.UseSystemPasswordChar = $Password
    return $box
}

function New-UlanziWizardHelpLink {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width
    )

    $link = [Windows.Forms.LinkLabel]::new()
    $link.Text = $Text
    $link.Location = [Drawing.Point]::new($X, $Y)
    $link.Size = [Drawing.Size]::new($Width, 24)
    $link.Font = [Drawing.Font]::new("Segoe UI", 9)
    $link.LinkBehavior = [Windows.Forms.LinkBehavior]::HoverUnderline
    $link.LinkColor = [Drawing.ColorTranslator]::FromHtml("#176B87")
    $link.ActiveLinkColor = [Drawing.ColorTranslator]::FromHtml("#0E4D64")
    $link.Cursor = [Windows.Forms.Cursors]::Hand
    return $link
}

function Show-UlanziFirstRunWizard {
    param(
        [switch]$HasExistingConfiguration,
        [ValidateSet("mgdl", "mmol")][string]$InitialDisplayUnits = "mgdl",
        [ValidateRange(0, 365)][decimal]$InitialSensorLifetimeDays = 0
    )

    [Windows.Forms.Application]::EnableVisualStyles()
    if ($HasExistingConfiguration) {
        $replace = [Windows.Forms.MessageBox]::Show(
            (Get-UlanziText -Key 'Ja existe uma configuracao. Continuar substituira os dados atuais somente depois da revisao final.'),
            (Get-UlanziText -Key 'Refazer configuracao'),
            [Windows.Forms.MessageBoxButtons]::YesNo,
            [Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($replace -ne [Windows.Forms.DialogResult]::Yes) { return $null }
    }

    $form = [Windows.Forms.Form]::new()
    $form.Text = (Get-UlanziText -Key 'Primeira configuracao - Ulanzi Glucose')
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = [Drawing.Size]::new(780, 590)
    $form.MinimumSize = [Drawing.Size]::new(720, 560)
    $form.Font = [Drawing.Font]::new("Segoe UI", 9)
    $form.MaximizeBox = $false
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
    $form.Tag = "Window"
    $visualColors = [ordered]@{
        Accent = [Drawing.ColorTranslator]::FromHtml("#1D5D7A")
        Success = [Drawing.ColorTranslator]::FromHtml("#147A45")
        Warning = [Drawing.ColorTranslator]::FromHtml("#A85E00")
        Error = [Drawing.Color]::Firebrick
        Muted = [Drawing.Color]::DimGray
    }
    $setIconCommand = Get-Command Set-UlanziUiApplicationIcon -ErrorAction SilentlyContinue
    if ($null -ne $setIconCommand) {
        [void](& $setIconCommand -Form $form -ProjectRoot (Split-Path -Parent $PSScriptRoot))
    }

    $header = [Windows.Forms.Panel]::new()
    $header.Dock = [Windows.Forms.DockStyle]::Top
    $header.Height = 82
    $header.BackColor = [Drawing.ColorTranslator]::FromHtml("#1D5D7A")
    $header.Tag = "Accent"
    $titleLabel = New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Configurar o Ulanzi Glucose') -X 24 -Y 13 -Width 700 -Height 30 -Bold
    $titleLabel.Font = [Drawing.Font]::new("Segoe UI", 16, [Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [Drawing.Color]::White
    $titleLabel.Tag = "AccentText"
    $stepLabel = New-UlanziWizardLabel -Text "" -X 25 -Y 48 -Width 700 -Height 24
    $stepLabel.ForeColor = [Drawing.ColorTranslator]::FromHtml("#D9EEF7")
    $stepLabel.Tag = "AccentText"
    $header.Controls.AddRange(@($titleLabel, $stepLabel))

    $navigation = [Windows.Forms.Panel]::new()
    $navigation.Dock = [Windows.Forms.DockStyle]::Bottom
    $navigation.Height = 72
    $navigation.BackColor = [Drawing.ColorTranslator]::FromHtml("#F4F6F8")
    $navigation.Tag = "Surface"
    $statusLabel = New-UlanziWizardLabel -Text "" -X 22 -Y 9 -Width 390 -Height 27
    $statusLabel.Name = "wizardStatusLabel"
    $statusLabel.ForeColor = $visualColors.Muted
    $progressBar = [Windows.Forms.ProgressBar]::new()
    $progressBar.Name = "wizardProgressBar"
    $progressBar.Location = [Drawing.Point]::new(22, 39)
    $progressBar.Size = [Drawing.Size]::new(390, 7)
    $progressBar.Style = [Windows.Forms.ProgressBarStyle]::Marquee
    $progressBar.MarqueeAnimationSpeed = 24
    $progressBar.Visible = $false
    $backButton = [Windows.Forms.Button]::new()
    $backButton.Text = (Get-UlanziText -Key '< Voltar')
    $backButton.Location = [Drawing.Point]::new(430, 19)
    $backButton.Size = [Drawing.Size]::new(100, 34)
    $nextButton = [Windows.Forms.Button]::new()
    $nextButton.Text = (Get-UlanziText -Key 'Avancar >')
    $nextButton.Location = [Drawing.Point]::new(538, 19)
    $nextButton.Size = [Drawing.Size]::new(105, 34)
    $nextButton.Tag = "Accent"
    $cancelButton = [Windows.Forms.Button]::new()
    $cancelButton.Text = (Get-UlanziText -Key 'Cancelar')
    $cancelButton.Location = [Drawing.Point]::new(651, 19)
    $cancelButton.Size = [Drawing.Size]::new(100, 34)
    $navigation.Controls.AddRange(@($statusLabel, $progressBar, $backButton, $nextButton, $cancelButton))

    $content = [Windows.Forms.Panel]::new()
    $content.Dock = [Windows.Forms.DockStyle]::Fill
    $content.Padding = [Windows.Forms.Padding]::new(24)
    $content.BackColor = [Drawing.Color]::White
    $content.Tag = "Window"

    $pages = [Collections.Generic.List[Windows.Forms.Panel]]::new()
    foreach ($index in 0..6) {
        $page = [Windows.Forms.Panel]::new()
        $page.Dock = [Windows.Forms.DockStyle]::Fill
        $page.Visible = $false
        $page.Tag = "Window"
        $pages.Add($page)
        $content.Controls.Add($page)
    }

    # Page 1: welcome and the complete path.
    $welcomeTitle = New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Vamos preparar tudo em um unico percurso') -X 4 -Y 4 -Width 700 -Height 34 -Bold
    $welcomeTitle.Font = [Drawing.Font]::new("Segoe UI", 14, [Drawing.FontStyle]::Bold)
    $pages[0].Controls.Add($welcomeTitle)
    $pages[0].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'O assistente vai orientar o relogio, testar as conexoes e salvar apenas quando estiver tudo confirmado.') -X 4 -Y 48 -Width 690 -Height 42))
    $welcomeCard = [Windows.Forms.Panel]::new()
    $welcomeCard.Location = [Drawing.Point]::new(4, 104)
    $welcomeCard.Size = [Drawing.Size]::new(690, 184)
    $welcomeCard.BackColor = [Drawing.ColorTranslator]::FromHtml("#F0F7FA")
    $welcomeCard.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
    $welcomeCard.Tag = "Elevated"
    $welcomeCard.Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key '1   Preparar o TC001 com AWTRIX e Wi-Fi') -X 22 -Y 20 -Width 635 -Height 30 -Bold))
    $welcomeCard.Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key '2   Escolher e testar a fonte de glicemia') -X 22 -Y 72 -Width 635 -Height 30 -Bold))
    $welcomeCard.Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key '3   Confirmar o relogio, as preferencias e ativar o bridge') -X 22 -Y 124 -Width 635 -Height 30 -Bold))
    $pages[0].Controls.Add($welcomeCard)
    $welcomeNote = New-UlanziWizardLabel -Text (Get-UlanziText -Key 'O USB serve para instalar o firmware e alimentar o TC001. Depois, os dados chegam pelo Wi-Fi e este computador precisa permanecer ligado.') -X 4 -Y 310 -Width 690 -Height 54 -Bold
    $welcomeNote.ForeColor = [Drawing.ColorTranslator]::FromHtml("#1D5D7A")
    $pages[0].Controls.Add($welcomeNote)

    # Page 2: prepare AWTRIX and Wi-Fi. Firmware changes always remain under
    # explicit user control in the official browser flasher.
    $pages[1].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Preparar o TC001') -X 4 -Y 4 -Width 680 -Height 32 -Bold))
    $pages[1].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Escolha o ponto em que voce esta. Nenhuma gravacao sera iniciada automaticamente.') -X 4 -Y 38 -Width 690 -Height 32))
    $awtrixReadyRadio = [Windows.Forms.RadioButton]::new()
    $awtrixReadyRadio.Name = "awtrixAlreadyReadyRadio"
    $awtrixReadyRadio.Text = (Get-UlanziText -Key 'Meu TC001 ja mostra AWTRIX e esta no Wi-Fi')
    $awtrixReadyRadio.Location = [Drawing.Point]::new(18, 74)
    $awtrixReadyRadio.Size = [Drawing.Size]::new(430, 28)
    $awtrixNeedsSetupRadio = [Windows.Forms.RadioButton]::new()
    $awtrixNeedsSetupRadio.Name = "awtrixNeedsSetupRadio"
    $awtrixNeedsSetupRadio.Text = (Get-UlanziText -Key 'Preciso instalar ou preparar o AWTRIX NG')
    $awtrixNeedsSetupRadio.Location = [Drawing.Point]::new(18, 106)
    $awtrixNeedsSetupRadio.Size = [Drawing.Size]::new(430, 28)
    if ($HasExistingConfiguration) {
        $awtrixReadyRadio.Checked = $true
    } else {
        $awtrixNeedsSetupRadio.Checked = $true
    }
    $pages[1].Controls.AddRange(@($awtrixReadyRadio, $awtrixNeedsSetupRadio))

    $awtrixPreparationPanel = [Windows.Forms.Panel]::new()
    $awtrixPreparationPanel.Location = [Drawing.Point]::new(4, 142)
    $awtrixPreparationPanel.Size = [Drawing.Size]::new(690, 178)
    $awtrixPreparationPanel.BackColor = [Drawing.ColorTranslator]::FromHtml("#FFF8E8")
    $awtrixPreparationPanel.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
    $awtrixPreparationPanel.Tag = "Elevated"
    $awtrixRiskLabel = New-UlanziWizardLabel -Text (Get-UlanziText -Key 'A instalacao inicial substitui o firmware e as configuracoes atuais. Faca backup do que deseja preservar e use um cabo USB de dados.') -X 14 -Y 10 -Width 658 -Height 43 -Bold
    $awtrixRiskLabel.ForeColor = [Drawing.ColorTranslator]::FromHtml("#704B00")
    $awtrixRiskLabel.Tag = "Warning"
    $usbPortsStatusLabel = New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Verificando portas USB seriais...') -X 14 -Y 56 -Width 480 -Height 28
    $usbPortsStatusLabel.Name = "usbPortsStatusLabel"
    $refreshUsbPortsButton = [Windows.Forms.Button]::new()
    $refreshUsbPortsButton.Name = "refreshUsbPortsButton"
    $refreshUsbPortsButton.Text = (Get-UlanziText -Key 'Atualizar USB')
    $refreshUsbPortsButton.Location = [Drawing.Point]::new(535, 52)
    $refreshUsbPortsButton.Size = [Drawing.Size]::new(135, 31)
    $openAwtrixFlasherButton = [Windows.Forms.Button]::new()
    $openAwtrixFlasherButton.Name = "openOfficialAwtrixFlasherButton"
    $openAwtrixFlasherButton.Text = (Get-UlanziText -Key '1. Abrir gravador oficial')
    $openAwtrixFlasherButton.Location = [Drawing.Point]::new(14, 101)
    $openAwtrixFlasherButton.Size = [Drawing.Size]::new(176, 36)
    $openAwtrixWifiGuideButton = [Windows.Forms.Button]::new()
    $openAwtrixWifiGuideButton.Name = "openOfficialAwtrixWifiGuideButton"
    $openAwtrixWifiGuideButton.Text = (Get-UlanziText -Key '2. Ver como configurar Wi-Fi')
    $openAwtrixWifiGuideButton.Location = [Drawing.Point]::new(201, 101)
    $openAwtrixWifiGuideButton.Size = [Drawing.Size]::new(190, 36)
    $openAwtrixPortalButton = [Windows.Forms.Button]::new()
    $openAwtrixPortalButton.Name = "openAwtrixProvisioningPortalButton"
    $openAwtrixPortalButton.Text = (Get-UlanziText -Key '3. Abrir 192.168.4.1')
    $openAwtrixPortalButton.Location = [Drawing.Point]::new(402, 101)
    $openAwtrixPortalButton.Size = [Drawing.Size]::new(168, 36)
    $awtrixPreparationPanel.Controls.AddRange(@(
        $awtrixRiskLabel,
        $usbPortsStatusLabel,
        $refreshUsbPortsButton,
        $openAwtrixFlasherButton,
        $openAwtrixWifiGuideButton,
        $openAwtrixPortalButton
    ))
    $pages[1].Controls.Add($awtrixPreparationPanel)
    $awtrixReadyBox = [Windows.Forms.CheckBox]::new()
    $awtrixReadyBox.Name = "awtrixReadyBox"
    $awtrixReadyBox.Text = (Get-UlanziText -Key 'Conclui esta etapa: o TC001 mostra AWTRIX e esta conectado ao meu Wi-Fi')
    $awtrixReadyBox.Location = [Drawing.Point]::new(4, 334)
    $awtrixReadyBox.Size = [Drawing.Size]::new(680, 42)
    $awtrixReadyBox.Checked = [bool]$HasExistingConfiguration
    $pages[1].Controls.Add($awtrixReadyBox)

    # Page 3: data source.
    $pages[2].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'De onde vem a glicemia?') -X 4 -Y 5 -Width 680 -Height 32 -Bold))
    $pages[2].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Escolha a fonte que recebe os dados do seu CGM. O aplicativo nao pede a senha do fabricante.') -X 4 -Y 42 -Width 690 -Height 30))
    $nightscoutRadio = [Windows.Forms.RadioButton]::new()
    $nightscoutRadio.Text = (Get-UlanziText -Key 'Nightscout (recomendado)')
    $nightscoutRadio.Location = [Drawing.Point]::new(18, 96)
    $nightscoutRadio.Size = [Drawing.Size]::new(350, 28)
    $nightscoutRadio.Checked = $true
    $pages[2].Controls.Add($nightscoutRadio)
    $pages[2].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Usa uma instalacao Nightscout que voce ja controla e permite identificar a troca do sensor.') -X 42 -Y 126 -Width 650 -Height 26))
    $jsonRadio = [Windows.Forms.RadioButton]::new()
    $jsonRadio.Text = (Get-UlanziText -Key 'Endpoint JSON autorizado')
    $jsonRadio.Location = [Drawing.Point]::new(18, 174)
    $jsonRadio.Size = [Drawing.Size]::new(350, 28)
    $pages[2].Controls.Add($jsonRadio)
    $pages[2].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Opcao avancada para integracoes proprias que retornam valueMgDl, trend e timestamp.') -X 42 -Y 204 -Width 650 -Height 26))
    $mockRadio = [Windows.Forms.RadioButton]::new()
    $mockRadio.Text = (Get-UlanziText -Key 'Somente demonstracao')
    $mockRadio.Location = [Drawing.Point]::new(18, 252)
    $mockRadio.Size = [Drawing.Size]::new(350, 28)
    $pages[2].Controls.Add($mockRadio)
    $pages[2].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Mostra 112 mg/dL simulado e ficara identificado como DEMONSTRACAO. Nao use para acompanhamento real.') -X 42 -Y 282 -Width 650 -Height 40))
    $sourcePreparationHelpLink = New-UlanziWizardHelpLink -Text (Get-UlanziText -Key 'Ainda nao tenho uma fonte pronta') -X 18 -Y 338 -Width 280
    $sourcePreparationHelpLink.Name = "sourcePreparationHelpLink"
    $pages[2].Controls.Add($sourcePreparationHelpLink)

    # Page 4: source connection.
    $sourceTitle = New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Conectar a fonte de glicemia') -X 4 -Y 5 -Width 680 -Height 32 -Bold
    $pages[3].Controls.Add($sourceTitle)
    $nightscoutPanel = [Windows.Forms.Panel]::new()
    $nightscoutPanel.Location = [Drawing.Point]::new(4, 48)
    $nightscoutPanel.Size = [Drawing.Size]::new(710, 340)
    $nightscoutPanel.Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'URL HTTPS do Nightscout') -X 0 -Y 2 -Width 300 -Bold))
    $nightscoutUrlHelpLink = New-UlanziWizardHelpLink -Text (Get-UlanziText -Key 'Onde encontro esta URL?') -X 465 -Y 2 -Width 185
    $nightscoutUrlHelpLink.Name = "nightscoutUrlHelpLink"
    $nightscoutUrlBox = New-UlanziWizardTextBox -X 0 -Y 28 -Width 650
    $nightscoutPanel.Controls.AddRange(@($nightscoutUrlHelpLink, $nightscoutUrlBox))
    $nightscoutPanel.Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Autenticacao') -X 0 -Y 72 -Width 200 -Bold))
    $nightscoutAuthBox = [Windows.Forms.ComboBox]::new()
    $nightscoutAuthBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $nightscoutAuthBox.Location = [Drawing.Point]::new(0, 99)
    $nightscoutAuthBox.Size = [Drawing.Size]::new(260, 28)
    [void]$nightscoutAuthBox.Items.AddRange(@("Access token", "API_SECRET", (Get-UlanziText -Key 'Acesso publico')))
    $nightscoutAuthBox.SelectedIndex = 0
    $nightscoutAccessHelpLink = New-UlanziWizardHelpLink -Text (Get-UlanziText -Key 'Como escolher e preencher?') -X 280 -Y 101 -Width 220
    $nightscoutAccessHelpLink.Name = "nightscoutAccessHelpLink"
    $nightscoutPanel.Controls.AddRange(@($nightscoutAuthBox, $nightscoutAccessHelpLink))
    $nightscoutSecretLabel = New-UlanziWizardLabel -Text "Access token" -X 0 -Y 143 -Width 220 -Bold
    $nightscoutSecretBox = New-UlanziWizardTextBox -X 0 -Y 170 -Width 420 -Password
    $nightscoutPanel.Controls.AddRange(@($nightscoutSecretLabel, $nightscoutSecretBox))
    $testSourceButton = [Windows.Forms.Button]::new()
    $testSourceButton.Text = (Get-UlanziText -Key 'Testar Nightscout')
    $testSourceButton.Location = [Drawing.Point]::new(0, 222)
    $testSourceButton.Size = [Drawing.Size]::new(160, 36)
    $sourceTestLabel = New-UlanziWizardLabel -Text (Get-UlanziText -Key 'O teste nao salva nem mostra sua credencial.') -X 175 -Y 227 -Width 465 -Height 45
    $sourceTestLabel.ForeColor = $visualColors.Muted
    $nightscoutPanel.Controls.AddRange(@($testSourceButton, $sourceTestLabel))

    $jsonPanel = [Windows.Forms.Panel]::new()
    $jsonPanel.Location = [Drawing.Point]::new(4, 48)
    $jsonPanel.Size = [Drawing.Size]::new(710, 340)
    $jsonPanel.Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'URL HTTPS do endpoint JSON') -X 0 -Y 2 -Width 320 -Bold))
    $jsonUrlBox = New-UlanziWizardTextBox -X 0 -Y 28 -Width 650
    $jsonPanel.Controls.Add($jsonUrlBox)
    $jsonPanel.Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Bearer token (opcional)') -X 0 -Y 75 -Width 260 -Bold))
    $jsonTokenBox = New-UlanziWizardTextBox -X 0 -Y 102 -Width 420 -Password
    $jsonPanel.Controls.Add($jsonTokenBox)
    $testJsonButton = [Windows.Forms.Button]::new()
    $testJsonButton.Text = (Get-UlanziText -Key 'Testar fonte JSON')
    $testJsonButton.Location = [Drawing.Point]::new(0, 154)
    $testJsonButton.Size = [Drawing.Size]::new(160, 36)
    $jsonTestLabel = New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Formato esperado: valueMgDl, trend e timestamp.') -X 175 -Y 159 -Width 460 -Height 45
    $jsonTestLabel.ForeColor = $visualColors.Muted
    $jsonPanel.Controls.AddRange(@($testJsonButton, $jsonTestLabel))

    $mockPanel = [Windows.Forms.Panel]::new()
    $mockPanel.Location = [Drawing.Point]::new(4, 48)
    $mockPanel.Size = [Drawing.Size]::new(710, 260)
    $mockPanel.Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'O modo de demonstracao nao precisa de internet nem de credenciais.') -X 0 -Y 20 -Width 670 -Height 40))
    $mockWarning = New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Importante: os valores sao simulados e nao representam uma pessoa real.') -X 0 -Y 82 -Width 670 -Height 40 -Bold
    $mockWarning.ForeColor = $visualColors.Error
    $mockPanel.Controls.Add($mockWarning)
    $pages[3].Controls.AddRange(@($nightscoutPanel, $jsonPanel, $mockPanel))

    # Page 5: TC001 discovery and validation.
    $pages[4].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Localizar e testar o TC001') -X 4 -Y 5 -Width 680 -Height 32 -Bold))
    $pages[4].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Deixe o computador e o TC001 na mesma rede. Primeiro tente Procurar; use o IP da tela se necessario.') -X 4 -Y 39 -Width 690 -Height 36))
    $pages[4].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Endereco do TC001') -X 4 -Y 82 -Width 240 -Bold))
    $awtrixAddressHelpLink = New-UlanziWizardHelpLink -Text (Get-UlanziText -Key 'Onde encontro o endereco?') -X 245 -Y 82 -Width 220
    $awtrixAddressHelpLink.Name = "awtrixAddressHelpLink"
    $pages[4].Controls.Add($awtrixAddressHelpLink)
    $awtrixHostBox = New-UlanziWizardTextBox -X 4 -Y 108 -Width 470
    $awtrixHostBox.Text = ""
    $findAwtrixButton = [Windows.Forms.Button]::new()
    $findAwtrixButton.Text = (Get-UlanziText -Key 'Procurar')
    $findAwtrixButton.Location = [Drawing.Point]::new(488, 106)
    $findAwtrixButton.Size = [Drawing.Size]::new(105, 31)
    $pages[4].Controls.AddRange(@($awtrixHostBox, $findAwtrixButton))
    $pages[4].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'A busca usa a descoberta oficial do AWTRIX NG e nomes conhecidos; ela nao varre a rede.') -X 4 -Y 143 -Width 680 -Height 30))
    $pages[4].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Usuario HTTP (deixe vazio se desativado)') -X 4 -Y 187 -Width 330 -Bold))
    $awtrixUserBox = New-UlanziWizardTextBox -X 4 -Y 213 -Width 300
    $pages[4].Controls.Add($awtrixUserBox)
    $pages[4].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Senha HTTP') -X 330 -Y 187 -Width 190 -Bold))
    $awtrixPasswordBox = New-UlanziWizardTextBox -X 330 -Y 213 -Width 300 -Password
    $pages[4].Controls.Add($awtrixPasswordBox)
    $testAwtrixButton = [Windows.Forms.Button]::new()
    $testAwtrixButton.Text = (Get-UlanziText -Key 'Testar TC001')
    $testAwtrixButton.Location = [Drawing.Point]::new(4, 274)
    $testAwtrixButton.Size = [Drawing.Size]::new(145, 36)
    $awtrixTestLabel = New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Teste a conexao antes de avancar.') -X 165 -Y 279 -Width 500 -Height 45
    $awtrixTestLabel.ForeColor = $visualColors.Muted
    $pages[4].Controls.AddRange(@($testAwtrixButton, $awtrixTestLabel))

    # Page 6: essential behavior.
    $pages[5].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Preferencias essenciais') -X 4 -Y 5 -Width 680 -Height 32 -Bold))
    $pages[5].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Estes limites controlam as cores do visor. Os limites sonoros comecam iguais e podem ser ajustados depois.') -X 4 -Y 38 -Width 700 -Height 40))
    $pages[5].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Unidade das leituras') -X 390 -Y 90 -Width 280 -Bold))
    $displayUnitsBox = [Windows.Forms.ComboBox]::new()
    $displayUnitsBox.Name = "displayUnitsControl"
    $displayUnitsBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $displayUnitsBox.Location = [Drawing.Point]::new(390, 118)
    $displayUnitsBox.Size = [Drawing.Size]::new(130, 28)
    [void]$displayUnitsBox.Items.AddRange(@("mg/dL", "mmol/L"))
    $displayUnitsBox.SelectedIndex = if ($InitialDisplayUnits -eq "mmol") { 1 } else { 0 }
    $pages[5].Controls.Add($displayUnitsBox)
    $pages[5].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'A unidade altera as leituras. Os limites desta tela continuam em mg/dL.') -X 530 -Y 118 -Width 165 -Height 88))
    $pages[5].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Cor de glicemia baixa (mg/dL)') -X 4 -Y 90 -Width 250 -Bold))
    $lowBox = [Windows.Forms.NumericUpDown]::new()
    $lowBox.Location = [Drawing.Point]::new(260, 87)
    $lowBox.Size = [Drawing.Size]::new(100, 28)
    $lowBox.Minimum = 20
    $lowBox.Maximum = 300
    $lowBox.Value = 70
    $pages[5].Controls.Add($lowBox)
    $pages[5].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Cor de glicemia alta (mg/dL)') -X 4 -Y 132 -Width 250 -Bold))
    $highBox = [Windows.Forms.NumericUpDown]::new()
    $highBox.Location = [Drawing.Point]::new(260, 129)
    $highBox.Size = [Drawing.Size]::new(100, 28)
    $highBox.Minimum = 40
    $highBox.Maximum = 600
    $highBox.Value = 180
    $pages[5].Controls.Add($highBox)
    $pages[5].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Considerar dado antigo depois de') -X 4 -Y 174 -Width 250 -Bold))
    $staleBox = [Windows.Forms.NumericUpDown]::new()
    $staleBox.Location = [Drawing.Point]::new(260, 171)
    $staleBox.Size = [Drawing.Size]::new(100, 28)
    $staleBox.Minimum = 2
    $staleBox.Maximum = 240
    $staleBox.Value = 15
    $pages[5].Controls.Add($staleBox)
    $pages[5].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'minutos') -X 370 -Y 174 -Width 100))
    $pages[5].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Estimativa de duracao do sensor') -X 4 -Y 216 -Width 250 -Bold))
    $sensorDurationBox = [Windows.Forms.ComboBox]::new()
    $sensorDurationBox.Name = "sensorDurationControl"
    $sensorDurationBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $sensorDurationBox.Location = [Drawing.Point]::new(260, 212)
    $sensorDurationBox.Size = [Drawing.Size]::new(145, 28)
    [void]$sensorDurationBox.Items.AddRange(@((Get-UlanziText -Key 'Desativada'), (Get-UlanziText -Key '7 dias'), (Get-UlanziText -Key '10 dias'), (Get-UlanziText -Key '14 dias'), (Get-UlanziText -Key '15 dias'), (Get-UlanziText -Key 'Personalizado')))
    $sensorPresets = @(0, 7, 10, 14, 15)
    $sensorDurationBox.SelectedIndex = if ($sensorPresets -contains $InitialSensorLifetimeDays) { [Array]::IndexOf($sensorPresets, [int]$InitialSensorLifetimeDays) } else { 5 }
    $sensorCustomBox = [Windows.Forms.NumericUpDown]::new()
    $sensorCustomBox.Name = "sensorCustomDurationControl"
    $sensorCustomBox.Location = [Drawing.Point]::new(420, 212)
    $sensorCustomBox.Size = [Drawing.Size]::new(80, 28)
    $sensorCustomBox.Minimum = 0.01
    $sensorCustomBox.Maximum = 365
    $sensorCustomBox.DecimalPlaces = 2
    $sensorCustomBox.Increment = 0.5
    $sensorCustomBox.Value = if ($InitialSensorLifetimeDays -gt 0) { $InitialSensorLifetimeDays } else { 1 }
    $sensorCustomBox.Visible = $sensorDurationBox.SelectedIndex -eq 5
    $sensorCustomDaysLabel = New-UlanziWizardLabel -Text (Get-UlanziText -Key 'dias') -X 510 -Y 216 -Width 55
    $sensorCustomDaysLabel.Visible = $sensorCustomBox.Visible
    $pages[5].Controls.AddRange(@($sensorDurationBox, $sensorCustomBox, $sensorCustomDaysLabel))
    $pages[5].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Estimativa opcional: requer Sensor Start/Change no Nightscout. Confira a duracao do seu modelo; mantenha desativada se nao souber.') -X 4 -Y 246 -Width 690 -Height 32))
    $alarmEnabledBox = [Windows.Forms.CheckBox]::new()
    $alarmEnabledBox.Text = (Get-UlanziText -Key 'Ativar alarmes sonoros de glicemia')
    $alarmEnabledBox.Location = [Drawing.Point]::new(4, 282)
    $alarmEnabledBox.Size = [Drawing.Size]::new(420, 30)
    $alarmEnabledBox.Checked = $false
    $pages[5].Controls.Add($alarmEnabledBox)
    $pages[5].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'As regras sonoras pre-selecionadas so terao efeito depois de ativar esta opcao.') -X 28 -Y 316 -Width 640 -Height 34))

    # Page 7: review.
    $pages[6].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Revisar, salvar e ativar') -X 4 -Y 5 -Width 680 -Height 32 -Bold))
    $pages[6].Controls.Add((New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Confira os dados abaixo. Senhas e tokens nunca aparecem nesta revisao.') -X 4 -Y 40 -Width 690 -Height 30))
    $reviewBox = [Windows.Forms.TextBox]::new()
    $reviewBox.Location = [Drawing.Point]::new(4, 82)
    $reviewBox.Size = [Drawing.Size]::new(690, 228)
    $reviewBox.Multiline = $true
    $reviewBox.ReadOnly = $true
    $reviewBox.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
    $reviewBox.BackColor = [Drawing.ColorTranslator]::FromHtml("#F7F9FA")
    $reviewBox.Font = [Drawing.Font]::new("Segoe UI", 10)
    $pages[6].Controls.Add($reviewBox)
    $alarmReviewWarning = New-UlanziWizardLabel -Text (Get-UlanziText -Key 'ATENCAO: os alarmes sonoros estao DESATIVADOS. O TC001 nao emitira alertas de glicemia.') -X 4 -Y 318 -Width 690 -Height 40 -Bold
    $alarmReviewWarning.Name = "alarmDisabledReviewWarning"
    $alarmReviewWarning.BackColor = [Drawing.ColorTranslator]::FromHtml("#FFF4CE")
    $alarmReviewWarning.ForeColor = [Drawing.ColorTranslator]::FromHtml("#704B00")
    $alarmReviewWarning.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
    $alarmReviewWarning.Padding = [Windows.Forms.Padding]::new(10, 0, 8, 0)
    $alarmReviewWarning.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
    $alarmReviewWarning.Visible = $false
    $pages[6].Controls.Add($alarmReviewWarning)
    $reviewNote = New-UlanziWizardLabel -Text (Get-UlanziText -Key 'Ao concluir, o Windows protege as credenciais; o painel valida os arquivos e inicia o bridge.') -X 4 -Y 365 -Width 690 -Height 24 -Bold
    $reviewNote.ForeColor = [Drawing.ColorTranslator]::FromHtml("#1D5D7A")
    $pages[6].Controls.Add($reviewNote)

    $form.Controls.Add($content)
    $form.Controls.Add($navigation)
    $form.Controls.Add($header)
    $form.AcceptButton = $nextButton
    $form.CancelButton = $cancelButton

    $state = [pscustomobject]@{
        Step = 0
        Result = $null
        SourceTestPassed = $false
        AwtrixTestPassed = $false
    }
    $stepNames = @((Get-UlanziText -Key 'Preparacao'), "AWTRIX NG", (Get-UlanziText -Key 'Fonte'), (Get-UlanziText -Key 'Conexao fonte'), "TC001", (Get-UlanziText -Key 'Preferencias'), (Get-UlanziText -Key 'Revisao'))
    $getSource = {
        if ($jsonRadio.Checked) { return "json" }
        if ($mockRadio.Checked) { return "mock" }
        return "nightscout"
    }
    $getNightscoutAuth = {
        if ($nightscoutAuthBox.SelectedIndex -eq 1) { return "api-secret" }
        if ($nightscoutAuthBox.SelectedIndex -eq 2) { return "public" }
        return "token"
    }
    $getSensorLifetimeDays = {
        if ($sensorDurationBox.SelectedIndex -ge 0 -and $sensorDurationBox.SelectedIndex -lt $sensorPresets.Count) { return $sensorPresets[$sensorDurationBox.SelectedIndex] }
        if ($sensorDurationBox.SelectedIndex -eq 5) { return [decimal]$sensorCustomBox.Value }
        return $null
    }
    $setStatus = {
        param([string]$Message, [bool]$IsError)
        $statusLabel.Text = $Message
        $statusLabel.ForeColor = if ($IsError) { $visualColors.Error } else { $visualColors.Accent }
    }
    $refreshSourcePanel = {
        $source = & $getSource
        $nightscoutPanel.Visible = $source -eq "nightscout"
        $jsonPanel.Visible = $source -eq "json"
        $mockPanel.Visible = $source -eq "mock"
    }
    $refreshAuth = {
        $authentication = & $getNightscoutAuth
        $nightscoutSecretLabel.Text = if ($authentication -eq "api-secret") { "API_SECRET" } else { "Access token" }
        $nightscoutSecretLabel.Visible = $authentication -ne "public"
        $nightscoutSecretBox.Visible = $authentication -ne "public"
    }
    $refreshSensorDuration = {
        $isCustom = $sensorDurationBox.SelectedIndex -eq 5
        $sensorCustomBox.Visible = $isCustom
        $sensorCustomDaysLabel.Visible = $isCustom
        if ($isCustom) { $sensorCustomBox.Select() }
    }
    $refreshUsbPorts = {
        $serialPorts = @(Get-UlanziWizardSerialPorts)
        if ($serialPorts.Count -eq 0) {
            $usbPortsStatusLabel.Text = (Get-UlanziText -Key 'Nenhuma porta serial apareceu. Confira se o cabo USB transmite dados.')
            $usbPortsStatusLabel.ForeColor = $visualColors.Error
        } else {
            $portList = $serialPorts -join ", "
            $usbPortsStatusLabel.Text = (Get-UlanziText -Key 'Windows encontrou: {0}. Confirme a porta no navegador.' -Arguments @(($portList)))
            $usbPortsStatusLabel.ForeColor = $visualColors.Success
        }
    }
    $refreshAwtrixPreparation = {
        $awtrixPreparationPanel.Enabled = $awtrixNeedsSetupRadio.Checked
        if ($awtrixNeedsSetupRadio.Checked) { & $refreshUsbPorts }
    }
    $refreshReview = {
        $source = & $getSource
        $sourceDescription = if ($source -eq "nightscout") { "Nightscout" } elseif ($source -eq "json") { "Endpoint JSON" } else { (Get-UlanziText -Key 'Demonstracao (dados simulados)') }
        $sourceAddress = if ($source -eq "nightscout") { $nightscoutUrlBox.Text.Trim() } elseif ($source -eq "json") { $jsonUrlBox.Text.Trim() } else { (Get-UlanziText -Key 'Nao se aplica') }
        $credential = (Get-UlanziText -Key 'Nao configurada')
        if ($source -eq "nightscout") {
            $auth = & $getNightscoutAuth
            $credential = if ($auth -eq "public") { (Get-UlanziText -Key 'Acesso publico') } elseif ($auth -eq "api-secret") { (Get-UlanziText -Key 'API_SECRET protegido') } else { (Get-UlanziText -Key 'Access token protegido') }
        } elseif ($source -eq "json" -and -not [string]::IsNullOrWhiteSpace($jsonTokenBox.Text)) {
            $credential = (Get-UlanziText -Key 'Bearer token protegido')
        }
        $awtrixCredential = if ([string]::IsNullOrWhiteSpace($awtrixUserBox.Text)) { (Get-UlanziText -Key 'Autenticacao desativada') } else { (Get-UlanziText -Key 'Usuario e senha protegidos') }
        $sensorLifetimeDays = & $getSensorLifetimeDays
        $sensorLifetimeDescription = if ($null -eq $sensorLifetimeDays) { (Get-UlanziText -Key 'Nao escolhida') } elseif ($sensorLifetimeDays -eq 0) { (Get-UlanziText -Key 'Desativada') } else { (Get-UlanziText -Key '{0} dias' -Arguments @(($sensorLifetimeDays))) }
        $alarmStatus = if ($alarmEnabledBox.Checked) { (Get-UlanziText -Key 'ATIVADOS') } else { (Get-UlanziText -Key 'DESATIVADOS - o TC001 nao emitira alertas de glicemia') }
        $reviewBox.Text = @(
            (Get-UlanziText -Key 'Fonte: {0}' -Arguments @(($sourceDescription))),
            (Get-UlanziText -Key 'Endereco da fonte: {0}' -Arguments @(($sourceAddress))),
            (Get-UlanziText -Key 'Credencial da fonte: {0}' -Arguments @(($credential))),
            "",
            "TC001: $($awtrixHostBox.Text.Trim())",
            (Get-UlanziText -Key 'Acesso ao TC001: {0}' -Arguments @(($awtrixCredential))),
            "",
            (Get-UlanziText -Key 'Unidade das leituras: {0}' -Arguments @(($($displayUnitsBox.SelectedItem)))),
            (Get-UlanziText -Key 'Cor baixa no visor: {0} mg/dL' -Arguments @(($([int]$lowBox.Value)))),
            (Get-UlanziText -Key 'Cor alta no visor: {0} mg/dL' -Arguments @(($([int]$highBox.Value)))),
            (Get-UlanziText -Key 'Dado antigo: {0} minutos' -Arguments @(($([int]$staleBox.Value)))),
            (Get-UlanziText -Key 'Duracao do sensor: {0}' -Arguments @(($sensorLifetimeDescription))),
            (Get-UlanziText -Key 'Alarmes sonoros: {0}' -Arguments @(($alarmStatus))),
            (Get-UlanziText -Key 'Setas de queda: para baixo ou diagonal abaixo de 90 mg/dL (quando os alarmes estiverem ativados)')
        ) -join [Environment]::NewLine
        $alarmReviewWarning.Visible = -not $alarmEnabledBox.Checked
    }
    $showStep = {
        param([int]$Step)
        $state.Step = $Step
        foreach ($page in $pages) { $page.Visible = $false }
        $pages[$Step].Visible = $true
        $pages[$Step].BringToFront()
        $stepLabel.Text = (Get-UlanziText -Key 'Etapa {0} de 7 - {1}' -Arguments @(($($Step + 1)), ($($stepNames[$Step]))))
        $backButton.Enabled = $Step -gt 0
        $nextButton.Text = if ($Step -eq 6) { (Get-UlanziText -Key 'Salvar e ativar') } else { (Get-UlanziText -Key 'Avancar >') }
        $statusLabel.Text = ""
        if ($Step -eq 1) { & $refreshAwtrixPreparation }
        if ($Step -eq 3) { & $refreshSourcePanel }
        if ($Step -eq 6) { & $refreshReview }
    }

    # Network checks run in an isolated PowerShell runspace. The WinForms thread
    # only starts the work and polls its completion, so painting, moving and
    # closing the window remain responsive without Application.DoEvents.
    $workerScriptPath = Join-Path $PSScriptRoot "primeira-configuracao-ui.ps1"
    $workerScript = @'
param($ScriptPath, $Operation, $Payload, $CancellationToken, $Language = "en")
$ErrorActionPreference = "Stop"
try {
    . $ScriptPath
    [void](Set-UlanziLanguage -Language $Language)
    $CancellationToken.ThrowIfCancellationRequested()
    $message = ""
    $data = $null
    switch ($Operation) {
        "nightscout" {
            $operationOutput = @(Test-UlanziNightscoutConnection -BaseUrl $Payload.BaseUrl -Authentication $Payload.Authentication -Secret $Payload.Secret -CancellationToken $CancellationToken)
            $message = [string]$operationOutput[-1]
        }
        "json" {
            $operationOutput = @(Test-UlanziJsonConnection -Url $Payload.Url -Token $Payload.Token -CancellationToken $CancellationToken)
            $message = [string]$operationOutput[-1]
        }
        "find-awtrix" {
            $data = Find-UlanziAwtrix -CurrentAddress $Payload.CurrentAddress -CancellationToken $CancellationToken
            if ($null -eq $data) {
                throw (Get-UlanziText -Key 'Nenhum TC001 foi encontrado automaticamente. Digite o IP mostrado no relogio e tente novamente.')
            }
            $message = (Get-UlanziText -Key 'TC001 encontrado.')
        }
        "test-awtrix" {
            $operationOutput = @(Test-UlanziAwtrixConnection -HostUrl $Payload.HostUrl -Username $Payload.Username -Password $Payload.Password -CancellationToken $CancellationToken)
            $message = [string]$operationOutput[-1]
        }
        default { throw (Get-UlanziText -Key 'Operacao de conexao desconhecida.') }
    }
    $CancellationToken.ThrowIfCancellationRequested()
    [pscustomobject]@{ Status = "success"; Message = $message; Data = $data }
} catch {
    if ($CancellationToken.IsCancellationRequested) {
        [pscustomobject]@{ Status = "cancelled"; Message = (Get-UlanziText -Key 'Operacao cancelada.'); Data = $null }
    } else {
        [pscustomobject]@{ Status = "error"; Message = [string]$_.Exception.Message; Data = $null }
    }
}
'@
    $operationState = [ordered]@{
        Busy = $false
        PowerShell = $null
        AsyncResult = $null
        Cancellation = $null
        Completion = $null
        PendingClose = $false
        CancelDeadlineUtc = [DateTime]::MinValue
        StopRequested = $false
        StopAsyncResult = $null
    }
    $operationCancelGraceMilliseconds = 1500
    $operationTimer = [Windows.Forms.Timer]::new()
    $operationTimer.Interval = 75

    $setBusyUi = {
        param([bool]$Busy, [string]$Message = "")
        $content.Enabled = -not $Busy
        $content.UseWaitCursor = $Busy
        $backButton.Enabled = -not $Busy -and $state.Step -gt 0
        $nextButton.Enabled = -not $Busy
        $progressBar.Visible = $Busy
        $cancelButton.Text = if ($Busy) { (Get-UlanziText -Key 'Cancelar teste') } else { (Get-UlanziText -Key 'Cancelar') }
        $cancelButton.Enabled = $true
        if ($Busy) {
            & $setStatus $Message $false
        } else {
            $statusLabel.Text = ""
        }
    }
    $requestOperationCancellation = {
        if (-not $operationState.Busy -or $null -eq $operationState.Cancellation) { return }
        if (-not $operationState.Cancellation.IsCancellationRequested) {
            $operationState.Cancellation.Cancel()
            $operationState.CancelDeadlineUtc = [DateTime]::UtcNow.AddMilliseconds($operationCancelGraceMilliseconds)
        } elseif ($operationState.CancelDeadlineUtc -eq [DateTime]::MinValue) {
            $operationState.CancelDeadlineUtc = [DateTime]::UtcNow.AddMilliseconds($operationCancelGraceMilliseconds)
        }
        $statusLabel.Text = (Get-UlanziText -Key 'Cancelando com seguranca...')
        $statusLabel.ForeColor = $visualColors.Muted
        $cancelButton.Text = (Get-UlanziText -Key 'Cancelando...')
        $cancelButton.Enabled = $false
    }
    $startOperation = {
        param(
            [string]$Operation,
            [pscustomobject]$Payload,
            [string]$BusyMessage,
            [scriptblock]$OnCompleted
        )

        if ($operationState.Busy) { return }
        $operationState.Busy = $true
        $operationState.PendingClose = $false
        $operationState.CancelDeadlineUtc = [DateTime]::MinValue
        $operationState.StopRequested = $false
        $operationState.StopAsyncResult = $null
        $operationState.Cancellation = [Threading.CancellationTokenSource]::new()
        $operationState.Completion = $OnCompleted
        & $setBusyUi $true $BusyMessage

        try {
            $workerPowerShell = [PowerShell]::Create()
            [void]$workerPowerShell.AddScript($workerScript)
            [void]$workerPowerShell.AddArgument($workerScriptPath)
            [void]$workerPowerShell.AddArgument($Operation)
            [void]$workerPowerShell.AddArgument($Payload)
            [void]$workerPowerShell.AddArgument($operationState.Cancellation.Token)
            [void]$workerPowerShell.AddArgument((Get-UlanziLanguage))
            $operationState.PowerShell = $workerPowerShell
            $operationTimer.Start()
            $operationState.AsyncResult = $workerPowerShell.BeginInvoke()
        } catch {
            $operationTimer.Stop()
            if ($null -ne $operationState.PowerShell) { $operationState.PowerShell.Dispose() }
            if ($null -ne $operationState.Cancellation) { $operationState.Cancellation.Dispose() }
            $operationState.PowerShell = $null
            $operationState.AsyncResult = $null
            $operationState.Cancellation = $null
            $operationState.Completion = $null
            $operationState.CancelDeadlineUtc = [DateTime]::MinValue
            $operationState.StopRequested = $false
            $operationState.StopAsyncResult = $null
            $operationState.Busy = $false
            & $setBusyUi $false
            & $OnCompleted ([pscustomobject]@{
                Status = "error"
                Message = (Get-UlanziText -Key 'Nao foi possivel iniciar o teste. Tente novamente.')
                Data = $null
            })
        }
    }
    $operationTimer.add_Tick({
        if (-not $operationState.Busy) { return }

        $workerPowerShell = $operationState.PowerShell
        $asyncResult = $operationState.AsyncResult
        $cancellation = $operationState.Cancellation
        if ($null -eq $workerPowerShell -or $null -eq $asyncResult -or $null -eq $cancellation) { return }

        if (
            $cancellation.IsCancellationRequested -and
            -not $asyncResult.IsCompleted -and
            -not $operationState.StopRequested -and
            $operationState.CancelDeadlineUtc -ne [DateTime]::MinValue -and
            [DateTime]::UtcNow -ge $operationState.CancelDeadlineUtc
        ) {
            $operationState.StopRequested = $true
            try {
                # BeginStop is intentionally asynchronous. EndStop and Dispose
                # happen only after the timer observes completion.
                $operationState.StopAsyncResult = $workerPowerShell.BeginStop($null, $null)
                $statusLabel.Text = (Get-UlanziText -Key 'Encerrando a operacao...')
            } catch {
                # The pipeline may have completed between IsCompleted and
                # BeginStop. EndInvoke below remains the source of truth.
                $operationState.StopAsyncResult = $null
            }
        }

        if ($null -ne $operationState.StopAsyncResult) {
            if (-not $operationState.StopAsyncResult.IsCompleted) { return }
            $stopAsyncResult = $operationState.StopAsyncResult
            try { $workerPowerShell.EndStop($stopAsyncResult) } catch { }
            $operationState.StopAsyncResult = $null
        }

        if (-not $asyncResult.IsCompleted) { return }

        $operationTimer.Stop()
        $completion = $operationState.Completion
        $pendingClose = $operationState.PendingClose
        $result = $null
        try {
            $outputs = @($workerPowerShell.EndInvoke($asyncResult))
            if ($outputs.Count -gt 0) { $result = $outputs[-1] }
            if ($null -eq $result -or $null -eq $result.PSObject.Properties["Status"]) {
                throw (Get-UlanziText -Key 'O teste terminou sem retornar um resultado.')
            }
        } catch {
            $result = if ($cancellation.IsCancellationRequested) {
                [pscustomobject]@{ Status = "cancelled"; Message = (Get-UlanziText -Key 'Operacao cancelada.'); Data = $null }
            } else {
                [pscustomobject]@{
                    Status = "error"
                    Message = (Get-UlanziText -Key 'Nao foi possivel concluir o teste. Tente novamente.')
                    Data = $null
                }
            }
        } finally {
            if ($null -ne $workerPowerShell) { $workerPowerShell.Dispose() }
            if ($null -ne $cancellation) { $cancellation.Dispose() }
            $operationState.PowerShell = $null
            $operationState.AsyncResult = $null
            $operationState.Cancellation = $null
            $operationState.Completion = $null
            $operationState.CancelDeadlineUtc = [DateTime]::MinValue
            $operationState.StopRequested = $false
            $operationState.StopAsyncResult = $null
            $operationState.Busy = $false
            & $setBusyUi $false
        }

        if ($pendingClose) {
            $form.DialogResult = [Windows.Forms.DialogResult]::Cancel
            $form.Close()
            return
        }
        try {
            & $completion $result
        } catch {
            & $setStatus (Get-UlanziText -Key 'O resultado do teste nao pode ser exibido. Tente novamente.') $true
        }
    })

    $openSafePage = {
        param([string]$Page, [string]$FailureMessage)
        try {
            Open-UlanziWizardSafePage -Page $Page
            & $setStatus (Get-UlanziText -Key 'Pagina aberta no navegador. Volte a este assistente quando terminar.') $false
        } catch {
            & $setStatus $FailureMessage $true
        }
    }
    $refreshUsbPortsButton.add_Click({ & $refreshUsbPorts })
    $awtrixReadyRadio.add_CheckedChanged({ & $refreshAwtrixPreparation })
    $awtrixNeedsSetupRadio.add_CheckedChanged({ & $refreshAwtrixPreparation })
    $openAwtrixFlasherButton.add_Click({
        $confirmation = [Windows.Forms.MessageBox]::Show(
            $form,
            (Get-UlanziText -Key 'Wizard.FirmwareConfirm'),
            (Get-UlanziText -Key 'Instalar AWTRIX NG com seguranca'),
            [Windows.Forms.MessageBoxButtons]::YesNo,
            [Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirmation -eq [Windows.Forms.DialogResult]::Yes) {
            & $openSafePage "awtrix-flashing" (Get-UlanziText -Key 'Nao foi possivel abrir a pagina oficial do AWTRIX NG. Confira seu navegador e tente novamente.')
        }
    })
    $openAwtrixWifiGuideButton.add_Click({
        & $openSafePage "awtrix-first-boot" (Get-UlanziText -Key 'Nao foi possivel abrir as instrucoes oficiais de Wi-Fi. Confira seu navegador e tente novamente.')
    })
    $openAwtrixPortalButton.add_Click({
        & $openSafePage "awtrix-provisioning" (Get-UlanziText -Key 'Conecte o computador a rede awtrixng-* e tente abrir 192.168.4.1 novamente.')
    })

    $nightscoutUrlHelpLink.add_LinkClicked({
        $helpText = @(
            (Get-UlanziText -Key 'Use o endereco principal que voce abre no navegador para acessar o Nightscout.'),
            "",
            (Get-UlanziText -Key 'Copie desde https:// ate o nome do site. Nao inclua /api/..., ?token=... nem qualquer senha.'),
            "",
            (Get-UlanziText -Key 'Se o Nightscout esta em outro computador ou na internet, use um endereco HTTPS.')
        ) -join [Environment]::NewLine
        [void][Windows.Forms.MessageBox]::Show(
            $form,
            $helpText,
            (Get-UlanziText -Key 'Ajuda - URL do Nightscout'),
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Information
        )
    })
    $sourcePreparationHelpLink.add_LinkClicked({
        $helpText = @(
            (Get-UlanziText -Key 'Para usar dados reais, voce precisa ter um Nightscout que abra no navegador e ja mostre leituras, ou um endpoint JSON autorizado.'),
            "",
            (Get-UlanziText -Key 'O Ulanzi Glucose le os dados disponiveis no Nightscout; nao se conecta diretamente ao fabricante do CGM. A integracao do sensor com o Nightscout e configurada separadamente.'),
            "",
            (Get-UlanziText -Key 'Se a fonte ainda nao estiver pronta, cancele sem medo e volte a este mesmo assistente depois. Nenhuma configuracao e substituida antes de Salvar e ativar.'),
            "",
            (Get-UlanziText -Key 'Somente demonstracao serve para conferir o relogio, mas nao representa uma leitura real.')
        ) -join [Environment]::NewLine
        [void][Windows.Forms.MessageBox]::Show(
            $form,
            $helpText,
            (Get-UlanziText -Key 'Preparar a fonte de glicemia'),
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Information
        )
    })
    $nightscoutAccessHelpLink.add_LinkClicked({
        $helpText = @(
            (Get-UlanziText -Key 'Access token (recomendado): entre no Nightscout com seu API_SECRET, abra o menu, escolha Admin Tools e Add New Subject. Crie um acesso com a funcao readable, salve e copie o token. Nao use a funcao admin.'),
            (Get-UlanziText -Key 'Cole somente o valor do token, sem escrever token=.'),
            "",
            (Get-UlanziText -Key 'API_SECRET: escolha esta opcao somente se quiser usar o segredo original configurado no Nightscout. O aplicativo faz a protecao necessaria; nao cole um hash.'),
            "",
            (Get-UlanziText -Key 'Acesso publico: escolha apenas se o Nightscout permite consultar a glicemia sem credencial.'),
            "",
            (Get-UlanziText -Key 'A credencial fica oculta nesta tela e nao aparece na revisao.')
        ) -join [Environment]::NewLine
        [void][Windows.Forms.MessageBox]::Show(
            $form,
            $helpText,
            (Get-UlanziText -Key 'Ajuda - acesso ao Nightscout'),
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Information
        )
    })
    $awtrixAddressHelpLink.add_LinkClicked({
        $helpText = @(
            (Get-UlanziText -Key 'Primeiro, deixe o computador e o TC001 conectados a mesma rede Wi-Fi e use Procurar. A busca envia apenas o pacote oficial FIND_AWTRIXNG e tenta alguns nomes conhecidos.'),
            "",
            (Get-UlanziText -Key 'Quando o AWTRIX entra no Wi-Fi, o TC001 mostra AWTRIX e o endereco IP. Digite-o neste formato: http://192.168.1.50'),
            "",
            (Get-UlanziText -Key 'Se a tela mostrar AP MODE, volte a etapa AWTRIX NG, conecte-se a rede awtrixng-* e conclua o Wi-Fi em 192.168.4.1.'),
            "",
            (Get-UlanziText -Key 'Informe somente o endereco, sem adicionar /api ou outro caminho.')
        ) -join [Environment]::NewLine
        [void][Windows.Forms.MessageBox]::Show(
            $form,
            $helpText,
            (Get-UlanziText -Key 'Ajuda - endereco do TC001'),
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Information
        )
    })

    $nightscoutAuthBox.add_SelectedIndexChanged({ & $refreshAuth })
    $sensorDurationBox.add_SelectedIndexChanged({ & $refreshSensorDuration })
    $nightscoutUrlBox.add_TextChanged({ $state.SourceTestPassed = $false })
    $nightscoutSecretBox.add_TextChanged({ $state.SourceTestPassed = $false })
    $nightscoutAuthBox.add_SelectedIndexChanged({ $state.SourceTestPassed = $false })
    $jsonUrlBox.add_TextChanged({ $state.SourceTestPassed = $false })
    $jsonTokenBox.add_TextChanged({ $state.SourceTestPassed = $false })
    $nightscoutRadio.add_CheckedChanged({ $state.SourceTestPassed = $false })
    $jsonRadio.add_CheckedChanged({ $state.SourceTestPassed = $false })
    $mockRadio.add_CheckedChanged({ $state.SourceTestPassed = $false })
    $awtrixHostBox.add_TextChanged({ $state.AwtrixTestPassed = $false })
    $awtrixUserBox.add_TextChanged({ $state.AwtrixTestPassed = $false })
    $awtrixPasswordBox.add_TextChanged({ $state.AwtrixTestPassed = $false })
    $testSourceButton.add_Click({
        $state.SourceTestPassed = $false
        $sourceTestLabel.Text = (Get-UlanziText -Key 'Testando conexao...')
        $sourceTestLabel.ForeColor = $visualColors.Muted
        $payload = [pscustomobject]@{
            BaseUrl = $nightscoutUrlBox.Text
            Authentication = (& $getNightscoutAuth)
            Secret = $nightscoutSecretBox.Text
        }
        & $startOperation "nightscout" $payload (Get-UlanziText -Key 'Conectando ao Nightscout...') {
            param($result)
            if ($result.Status -eq "success") {
                $state.SourceTestPassed = $true
                $sourceTestLabel.Text = $result.Message
                $sourceTestLabel.ForeColor = $visualColors.Success
            } elseif ($result.Status -eq "cancelled") {
                $sourceTestLabel.Text = (Get-UlanziText -Key 'Teste cancelado. Revise os dados ou tente novamente.')
                $sourceTestLabel.ForeColor = $visualColors.Muted
            } else {
                $sourceTestLabel.Text = $result.Message
                $sourceTestLabel.ForeColor = $visualColors.Error
            }
        }
    })
    $testJsonButton.add_Click({
        $state.SourceTestPassed = $false
        $jsonTestLabel.Text = (Get-UlanziText -Key 'Testando conexao...')
        $jsonTestLabel.ForeColor = $visualColors.Muted
        $payload = [pscustomobject]@{
            Url = $jsonUrlBox.Text
            Token = $jsonTokenBox.Text
        }
        & $startOperation "json" $payload (Get-UlanziText -Key 'Conectando a fonte JSON...') {
            param($result)
            if ($result.Status -eq "success") {
                $state.SourceTestPassed = $true
                $jsonTestLabel.Text = $result.Message
                $jsonTestLabel.ForeColor = $visualColors.Success
            } elseif ($result.Status -eq "cancelled") {
                $jsonTestLabel.Text = (Get-UlanziText -Key 'Teste cancelado. Revise os dados ou tente novamente.')
                $jsonTestLabel.ForeColor = $visualColors.Muted
            } else {
                $jsonTestLabel.Text = $result.Message
                $jsonTestLabel.ForeColor = $visualColors.Error
            }
        }
    })
    $findAwtrixButton.add_Click({
        $awtrixTestLabel.Text = (Get-UlanziText -Key 'Procurando por nomes conhecidos...')
        $awtrixTestLabel.ForeColor = $visualColors.Muted
        $payload = [pscustomobject]@{ CurrentAddress = $awtrixHostBox.Text }
        & $startOperation "find-awtrix" $payload (Get-UlanziText -Key 'Procurando o TC001 na rede...') {
            param($result)
            if ($result.Status -eq "success") {
                $awtrixHostBox.Text = [string]$result.Data.Address
                $awtrixTestLabel.Text = if ([bool]$result.Data.AuthenticationRequired) {
                    (Get-UlanziText -Key 'TC001 encontrado. Informe usuario e senha para testar.')
                } else {
                    (Get-UlanziText -Key 'TC001 encontrado. Use Testar TC001 para confirmar.')
                }
                $awtrixTestLabel.ForeColor = $visualColors.Success
            } elseif ($result.Status -eq "cancelled") {
                $awtrixTestLabel.Text = (Get-UlanziText -Key 'Busca cancelada. Digite o IP do TC001 ou tente novamente.')
                $awtrixTestLabel.ForeColor = $visualColors.Muted
            } else {
                $awtrixTestLabel.Text = $result.Message
                $awtrixTestLabel.ForeColor = $visualColors.Error
            }
        }
    })
    $testAwtrixButton.add_Click({
        $state.AwtrixTestPassed = $false
        $awtrixTestLabel.Text = (Get-UlanziText -Key 'Testando conexao...')
        $awtrixTestLabel.ForeColor = $visualColors.Muted
        $payload = [pscustomobject]@{
            HostUrl = $awtrixHostBox.Text
            Username = $awtrixUserBox.Text
            Password = $awtrixPasswordBox.Text
        }
        & $startOperation "test-awtrix" $payload (Get-UlanziText -Key 'Conectando ao TC001...') {
            param($result)
            if ($result.Status -eq "success") {
                $state.AwtrixTestPassed = $true
                $awtrixTestLabel.Text = $result.Message
                $awtrixTestLabel.ForeColor = $visualColors.Success
            } elseif ($result.Status -eq "cancelled") {
                $awtrixTestLabel.Text = (Get-UlanziText -Key 'Teste cancelado. Confira o endereco e tente novamente.')
                $awtrixTestLabel.ForeColor = $visualColors.Muted
            } else {
                $awtrixTestLabel.Text = $result.Message
                $awtrixTestLabel.ForeColor = $visualColors.Error
            }
        }
    })
    $backButton.add_Click({ if (-not $operationState.Busy -and $state.Step -gt 0) { & $showStep ($state.Step - 1) } })
    $form.add_FormClosing({
        param($sender, $eventArgs)
        if ($operationState.Busy) {
            $eventArgs.Cancel = $true
            $operationState.PendingClose = $true
            & $requestOperationCancellation
        }
    })
    $cancelButton.add_Click({
        if ($operationState.Busy) {
            & $requestOperationCancellation
            return
        }
        $form.DialogResult = [Windows.Forms.DialogResult]::Cancel
        $form.Close()
    })
    $nextButton.add_Click({
        if ($operationState.Busy) { return }
        try {
            if ($state.Step -eq 1) {
                if (-not $awtrixReadyBox.Checked) {
                    throw (Get-UlanziText -Key 'Confirme que o TC001 ja mostra AWTRIX e esta conectado ao seu Wi-Fi.')
                }
            } elseif ($state.Step -eq 3) {
                $source = & $getSource
                if ($source -eq "nightscout") {
                    [void](Test-UlanziWizardUrl -Value $nightscoutUrlBox.Text -Label (Get-UlanziText -Key 'A URL do Nightscout') -RequireHttpsOutsideLocalhost)
                    if ((& $getNightscoutAuth) -ne "public" -and [string]::IsNullOrWhiteSpace($nightscoutSecretBox.Text)) { throw (Get-UlanziText -Key 'Informe a credencial do Nightscout.') }
                    if (-not $state.SourceTestPassed) { throw (Get-UlanziText -Key 'Use Testar Nightscout e confirme a conexao antes de avancar.') }
                } elseif ($source -eq "json") {
                    [void](Test-UlanziWizardUrl -Value $jsonUrlBox.Text -Label (Get-UlanziText -Key 'A URL da fonte JSON') -RequireHttpsOutsideLocalhost)
                    if (-not $state.SourceTestPassed) { throw (Get-UlanziText -Key 'Use Testar fonte JSON e confirme a conexao antes de avancar.') }
                }
            } elseif ($state.Step -eq 4) {
                [void](Test-UlanziWizardUrl -Value $awtrixHostBox.Text -Label (Get-UlanziText -Key 'O endereco do TC001') -DisallowPath)
                if ([string]::IsNullOrWhiteSpace($awtrixUserBox.Text) -and -not [string]::IsNullOrEmpty($awtrixPasswordBox.Text)) { throw (Get-UlanziText -Key 'Informe o usuario do TC001 ou apague a senha.') }
                if (-not $state.AwtrixTestPassed) { throw (Get-UlanziText -Key 'Use Testar TC001 e confirme a conexao antes de avancar.') }
            } elseif ($state.Step -eq 5) {
                if ($highBox.Value -le $lowBox.Value) { throw (Get-UlanziText -Key 'O limite alto deve ser maior que o limite baixo.') }
                if ($null -eq (& $getSensorLifetimeDays)) {
                    throw (Get-UlanziText -Key 'Escolha a duracao do seu sensor antes de avancar.')
                }
            }
            if ($state.Step -lt 6) {
                & $showStep ($state.Step + 1)
                return
            }

            $source = & $getSource
            $authentication = & $getNightscoutAuth
            $sensorLifetimeDays = & $getSensorLifetimeDays
            if ($null -eq $sensorLifetimeDays) {
                throw (Get-UlanziText -Key 'Volte para Preferencias e escolha a duracao do seu sensor.')
            }
            $toSecureString = {
                param([string]$Value)
                if ([string]::IsNullOrEmpty($Value)) { return $null }
                return ConvertTo-SecureString -String $Value -AsPlainText -Force
            }
            $state.Result = [pscustomobject]@{
                Source = $source
                AwtrixHost = $awtrixHostBox.Text.Trim()
                AwtrixUser = $awtrixUserBox.Text.Trim()
                AwtrixPassword = (& $toSecureString $awtrixPasswordBox.Text)
                NightscoutUrl = if ($source -eq "nightscout") { $nightscoutUrlBox.Text.Trim() } else { "" }
                NightscoutToken = if ($source -eq "nightscout" -and $authentication -eq "token") { & $toSecureString $nightscoutSecretBox.Text } else { $null }
                NightscoutApiSecret = if ($source -eq "nightscout" -and $authentication -eq "api-secret") { & $toSecureString $nightscoutSecretBox.Text } else { $null }
                JsonSourceUrl = if ($source -eq "json") { $jsonUrlBox.Text.Trim() } else { "" }
                JsonToken = if ($source -eq "json") { & $toSecureString $jsonTokenBox.Text } else { $null }
                DisplayUnits = if ($displayUnitsBox.SelectedIndex -eq 1) { "mmol" } else { "mgdl" }
                LowThreshold = [string][int]$lowBox.Value
                HighThreshold = [string][int]$highBox.Value
                StaleMinutes = [string][int]$staleBox.Value
                SensorLifetimeDays = ([decimal]$sensorLifetimeDays).ToString([Globalization.CultureInfo]::InvariantCulture)
                AlarmEnabled = $alarmEnabledBox.Checked.ToString().ToLowerInvariant()
                UpSlightThreshold = "140"
                DownThreshold = "90"
                DoubleUpEnabled = "true"
                NoDataEnabled = "true"
                AlarmHysteresis = "5"
                AlarmCooldown = "5"
                AlarmOnStartupExtreme = "true"
                AlarmOnRecoveryExtreme = "true"
                AlarmMaxDeliveryAttempts = "3"
                AlarmDeliveryRetrySeconds = "30"
            }
            $form.DialogResult = [Windows.Forms.DialogResult]::OK
            $form.Close()
        } catch {
            & $setStatus $_.Exception.Message $true
        }
    })

    $dialogResult = [Windows.Forms.DialogResult]::Cancel
    $result = $null
    try {
        & $refreshAuth
        & $refreshSensorDuration
        & $showStep 0
        $applyThemeCommand = Get-Command Apply-UlanziUiTheme -ErrorAction SilentlyContinue
        if ($null -ne $applyThemeCommand) {
            try {
                $wizardTheme = "system"
                $themePreferenceCommand = Get-Command Get-UlanziUiThemePreference -ErrorAction SilentlyContinue
                if ($null -ne $themePreferenceCommand) { $wizardTheme = [string](& $themePreferenceCommand) }
                & $applyThemeCommand -Control $form -Theme $wizardTheme
                $paletteCommand = Get-Command Get-UlanziUiPalette -ErrorAction SilentlyContinue
                if ($null -ne $paletteCommand) {
                    $wizardPalette = & $paletteCommand -Theme $wizardTheme
                    $visualColors.Accent = $wizardPalette.Accent
                    $visualColors.Success = $wizardPalette.Success
                    $visualColors.Warning = $wizardPalette.Warning
                    $visualColors.Error = $wizardPalette.Error
                    $visualColors.Muted = $wizardPalette.Muted
                    foreach ($helpLink in @($sourcePreparationHelpLink, $nightscoutUrlHelpLink, $nightscoutAccessHelpLink, $awtrixAddressHelpLink)) {
                        $helpLink.LinkColor = $wizardPalette.Accent
                        $helpLink.ActiveLinkColor = $wizardPalette.HeaderMuted
                    }
                }
            } catch {
                # Theme is visual only and must never block configuration.
            }
        }
        $dialogResult = $form.ShowDialog()
        $result = $state.Result
    } finally {
        $operationTimer.Stop()

        # Normal closes reach this point only after the timer has completed the
        # worker. This branch also protects exceptional ShowDialog termination.
        if ($operationState.Busy) {
            $cleanupPowerShell = $operationState.PowerShell
            $cleanupAsyncResult = $operationState.AsyncResult
            $cleanupCancellation = $operationState.Cancellation
            $cleanupStopAsyncResult = $operationState.StopAsyncResult
            $cleanupDeadlineUtc = [DateTime]::UtcNow.AddSeconds(5)
            $cleanupSafeToDispose = $null -eq $cleanupPowerShell
            try {
                if ($null -ne $cleanupCancellation -and -not $cleanupCancellation.IsCancellationRequested) {
                    $cleanupCancellation.Cancel()
                }
                if (
                    $null -ne $cleanupPowerShell -and
                    $null -ne $cleanupAsyncResult -and
                    -not $cleanupAsyncResult.IsCompleted -and
                    $null -eq $cleanupStopAsyncResult
                ) {
                    try {
                        $cleanupStopAsyncResult = $cleanupPowerShell.BeginStop($null, $null)
                    } catch { }
                }
                while (
                    $null -ne $cleanupStopAsyncResult -and
                    -not $cleanupStopAsyncResult.IsCompleted -and
                    [DateTime]::UtcNow -lt $cleanupDeadlineUtc
                ) {
                    [Threading.Thread]::Sleep(25)
                }
                if ($null -ne $cleanupStopAsyncResult -and $cleanupStopAsyncResult.IsCompleted) {
                    try { $cleanupPowerShell.EndStop($cleanupStopAsyncResult) } catch { }
                    $cleanupStopAsyncResult = $null
                }
                while (
                    $null -ne $cleanupAsyncResult -and
                    -not $cleanupAsyncResult.IsCompleted -and
                    [DateTime]::UtcNow -lt $cleanupDeadlineUtc
                ) {
                    [Threading.Thread]::Sleep(25)
                }
                if ($null -ne $cleanupAsyncResult -and $cleanupAsyncResult.IsCompleted) {
                    try { [void]$cleanupPowerShell.EndInvoke($cleanupAsyncResult) } catch { }
                }
                $cleanupSafeToDispose = (
                    $null -eq $cleanupPowerShell -or
                    (
                        ($null -eq $cleanupStopAsyncResult) -and
                        ($null -eq $cleanupAsyncResult -or $cleanupAsyncResult.IsCompleted)
                    )
                )
            } finally {
                # Never race Dispose against an unfinished BeginStop/BeginInvoke.
                if ($cleanupSafeToDispose -and $null -ne $cleanupPowerShell) {
                    $cleanupPowerShell.Dispose()
                    $operationState.PowerShell = $null
                }
                if ($cleanupSafeToDispose -and $null -ne $cleanupCancellation) {
                    $cleanupCancellation.Dispose()
                    $operationState.Cancellation = $null
                }
            }
        }

        $operationTimer.Dispose()
        $form.Dispose()
    }
    if ($dialogResult -ne [Windows.Forms.DialogResult]::OK) { return $null }
    return $result
}
