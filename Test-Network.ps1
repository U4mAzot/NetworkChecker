<#
.SYNOPSIS
    Diagnozuje połączenie sieciowe krok po kroku i podpowiada, gdzie leży problem.

.DESCRIPTION
    Skrypt sprawdza po kolei: kartę sieciową, adres IP (w tym brak DHCP),
    bramę domyślną, dostęp do internetu, rozpoznawanie nazw DNS oraz wybrane porty TCP.
    Na końcu wyświetla diagnozę ("problem z DNS", "brak połączenia z routerem" itp.)
    i zapisuje wyniki do logu.

    Z przełącznikiem -Fix, jeśli wykryto błędy, wykonuje podstawowe kroki naprawcze
    (czyszczenie pamięci podręcznej DNS, odnowienie dzierżawy DHCP) i powtarza testy.

.PARAMETER Hosts
    Adresy do testu ping (dostęp do internetu).

.PARAMETER DnsNames
    Nazwy domen do testu rozpoznawania DNS.

.PARAMETER Ports
    Lista "host:port" do testu połączeń TCP.

.PARAMETER Fix
    Wykonuje kroki naprawcze, jeśli wykryto problemy.

.EXAMPLE
    .\Test-Network.ps1

.EXAMPLE
    .\Test-Network.ps1 -Fix

.EXAMPLE
    .\Test-Network.ps1 -Ports 'serwer-plikow:445', 'intranet.firma.pl:443'
#>
[CmdletBinding()]
param(
    [string[]]$Hosts    = @('8.8.8.8', '1.1.1.1'),
    [string[]]$DnsNames = @('google.com', 'microsoft.com'),
    [string[]]$Ports    = @('google.com:443', 'outlook.office365.com:443'),
    [switch]$Fix,
    [string]$LogFolder
)

# Domyślne ścieżki względem folderu skryptu (w PowerShell 5.1 $PSScriptRoot bywa pusty w bloku param)
if (-not $LogFolder) { $LogFolder = Join-Path $PSScriptRoot 'logs' }

function New-Result($Category, $Target, $Ok, $Details) {
    [pscustomobject]@{
        Kategoria = $Category
        Cel       = $Target
        Status    = if ($Ok) { 'OK' } else { 'BŁĄD' }
        Szczegóły = $Details
    }
}

function Test-Ping([string]$Target) {
    try {
        $reply = (New-Object System.Net.NetworkInformation.Ping).Send($Target, 1500)
        if ($reply.Status -eq 'Success') {
            return @{ Ok = $true;  Details = "$($reply.RoundtripTime) ms" }
        }
        return @{ Ok = $false; Details = "$($reply.Status)" }
    } catch {
        return @{ Ok = $false; Details = 'Nie można rozpoznać nazwy lub host niedostępny' }
    }
}

function Test-TcpPort([string]$Target, [int]$Port, [int]$TimeoutMs = 2000) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($Target, $Port)
        if ($task.Wait($TimeoutMs) -and $client.Connected) {
            return @{ Ok = $true; Details = 'Port otwarty' }
        }
        return @{ Ok = $false; Details = 'Przekroczono czas połączenia' }
    } catch {
        return @{ Ok = $false; Details = 'Połączenie odrzucone lub host nieznany' }
    } finally {
        $client.Dispose()
    }
}

function Invoke-NetworkTests {
    $results = @()

    # 1. Karta sieciowa
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
    if ($adapters.Count -gt 0) {
        $details = ($adapters | ForEach-Object { "$($_.InterfaceDescription) ($($_.LinkSpeed))" }) -join '; '
        $results += New-Result 'Karta sieciowa' ($adapters.Name -join ', ') $true $details
    } else {
        $results += New-Result 'Karta sieciowa' '-' $false 'Brak aktywnej karty sieciowej'
    }

    # 2. Adres IP i brama
    $config = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
        Select-Object -First 1

    if ($config) {
        $ip = $config.IPv4Address.IPAddress | Select-Object -First 1
        if ($ip -like '169.254.*') {
            $results += New-Result 'Adres IP' $ip $false 'Adres APIPA - komputer nie dostał adresu z DHCP'
        } else {
            $results += New-Result 'Adres IP' $ip $true "Interfejs: $($config.InterfaceAlias)"
        }

        $gateway = $config.IPv4DefaultGateway.NextHop | Select-Object -First 1
        $ping = Test-Ping $gateway
        $results += New-Result 'Brama domyślna' $gateway $ping.Ok $ping.Details
    } else {
        $results += New-Result 'Adres IP' '-' $false 'Brak konfiguracji IP z bramą domyślną'
        $results += New-Result 'Brama domyślna' '-' $false 'Brak bramy domyślnej'
    }

    # 3. Internet (ping po adresie IP - bez udziału DNS)
    foreach ($target in $Hosts) {
        $ping = Test-Ping $target
        $results += New-Result 'Internet (ping)' $target $ping.Ok $ping.Details
    }

    # 4. DNS
    foreach ($name in $DnsNames) {
        try {
            $timer = [System.Diagnostics.Stopwatch]::StartNew()
            $answer = Resolve-DnsName -Name $name -Type A -DnsOnly -ErrorAction Stop |
                Where-Object Type -eq 'A' | Select-Object -First 1
            $timer.Stop()
            $results += New-Result 'DNS' $name $true "$($answer.IPAddress) ($($timer.ElapsedMilliseconds) ms)"
        } catch {
            $results += New-Result 'DNS' $name $false 'Nie udało się rozpoznać nazwy'
        }
    }

    # 5. Porty TCP
    foreach ($entry in $Ports) {
        $target, $port = $entry -split ':'
        $tcp = Test-TcpPort $target ([int]$port)
        $results += New-Result 'Port TCP' $entry $tcp.Ok $tcp.Details
    }

    return $results
}

function Get-Diagnosis($Results) {
    $failed = { param($category) @($Results | Where-Object { $_.Kategoria -eq $category -and $_.Status -ne 'OK' }).Count -gt 0 }
    $allFailed = { param($category) -not ($Results | Where-Object { $_.Kategoria -eq $category -and $_.Status -eq 'OK' }) }

    if (& $failed 'Karta sieciowa') { return 'Brak aktywnej karty sieciowej. Sprawdź kabel, Wi-Fi lub tryb samolotowy.' }
    if (& $failed 'Adres IP')       { return 'Komputer nie ma poprawnego adresu IP. Sprawdź DHCP / router lub uruchom skrypt z -Fix.' }
    if (& $failed 'Brama domyślna') { return 'Brak odpowiedzi z routera (bramy). Problem w sieci lokalnej - sprawdź router/switch.' }
    if (& $allFailed 'Internet (ping)') { return 'Sieć lokalna działa, ale brak dostępu do internetu. Problem u dostawcy lub na routerze.' }
    if (& $allFailed 'DNS')         { return 'Internet działa, ale nie działa DNS. Sprawdź ustawienia DNS lub uruchom skrypt z -Fix.' }
    if (& $failed 'Port TCP')       { return 'Połączenie działa, ale część usług jest niedostępna (firewall, proxy lub awaria usługi).' }
    if (& $failed 'Internet (ping)') { return 'Większość testów OK, część hostów nie odpowiada na ping (może być blokowany).' }
    if (& $failed 'DNS')            { return 'Część nazw nie została rozpoznana - sprawdź wpisaną domenę.' }
    return 'Sieć działa poprawnie.'
}

function Show-Results($Results) {
    foreach ($r in $Results) {
        $color = if ($r.Status -eq 'OK') { 'Green' } else { 'Red' }
        Write-Host ('[{0,-4}] ' -f $r.Status) -ForegroundColor $color -NoNewline
        Write-Host ('{0,-16} {1,-28} {2}' -f $r.Kategoria, $r.Cel, $r.Szczegóły)
    }
}

# --- Start ------------------------------------------------------------------
Write-Host "`n=== Diagnostyka sieci: $env:COMPUTERNAME ===`n" -ForegroundColor Cyan
$results = Invoke-NetworkTests
Show-Results $results

$diagnosis = Get-Diagnosis $results
$hasErrors = @($results | Where-Object Status -ne 'OK').Count -gt 0

if ($Fix -and $hasErrors) {
    Write-Host "`nWykryto problemy - wykonuję kroki naprawcze..." -ForegroundColor Yellow

    Write-Host ' - Czyszczenie pamięci podręcznej DNS (ipconfig /flushdns)'
    ipconfig /flushdns | Out-Null

    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host ' - Odnawianie adresu IP (ipconfig /release + /renew)'
        ipconfig /release | Out-Null
        ipconfig /renew   | Out-Null
    } else {
        Write-Host ' - Pominięto odnowienie adresu IP (wymaga uruchomienia jako administrator)' -ForegroundColor DarkYellow
    }

    Write-Host "`nPonowne testy:`n" -ForegroundColor Cyan
    $results = Invoke-NetworkTests
    Show-Results $results
    $diagnosis = Get-Diagnosis $results
}

$color = if ($diagnosis -eq 'Sieć działa poprawnie.') { 'Green' } else { 'Yellow' }
Write-Host "`nDiagnoza: $diagnosis`n" -ForegroundColor $color

# --- Log --------------------------------------------------------------------
if (-not (Test-Path $LogFolder)) {
    New-Item -ItemType Directory -Path $LogFolder | Out-Null
}
$logPath = Join-Path $LogFolder ("network_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
@(
    "Diagnostyka sieci - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    ($results | Format-Table -AutoSize | Out-String -Width 200)
    "Diagnoza: $diagnosis"
) | Out-File -FilePath $logPath -Encoding UTF8

Write-Host "Log zapisany: $logPath" -ForegroundColor DarkGray
