# NetworkChecker - diagnostyka sieci

Skrypt PowerShell, który odtwarza typową ścieżkę diagnostyczną technika helpdesku
przy zgłoszeniu „nie działa mi internet”. Sprawdza połączenie warstwa po warstwie,
na końcu mówi, **gdzie** leży problem, i opcjonalnie próbuje go naprawić.

## Co sprawdza

| Krok | Test | Co wykrywa |
|------|------|------------|
| 1 | Karta sieciowa | odłączony kabel, wyłączone Wi-Fi, tryb samolotowy |
| 2 | Adres IP | brak adresu z DHCP (adres APIPA `169.254.x.x`) |
| 3 | Brama domyślna | brak łączności z routerem |
| 4 | Ping do internetu (po IP) | brak wyjścia do internetu |
| 5 | DNS | internet działa, ale nazwy domen się nie rozpoznają |
| 6 | Porty TCP | blokada przez firewall lub proxy, niedziałająca usługa |

Na podstawie wyników skrypt wyświetla **diagnozę**, np.:

```
Diagnoza: Internet działa, ale nie działa DNS. Sprawdź ustawienia DNS lub uruchom skrypt z -Fix.
```

## Tryb naprawy (`-Fix`)

Jeśli wykryto błędy, skrypt:
1. czyści pamięć podręczną DNS (`ipconfig /flushdns`),
2. odnawia adres IP (`ipconfig /release` + `/renew`), co wymaga uprawnień administratora,
3. ponownie wykonuje wszystkie testy.

## Użycie

```powershell
# Standardowa diagnostyka
.\Test-Network.ps1

# Diagnostyka z próbą naprawy (najlepiej jako administrator)
.\Test-Network.ps1 -Fix

# Test usług firmowych
.\Test-Network.ps1 -Ports 'serwer-plikow:445', 'intranet.firma.pl:443'
```

Wyniki zapisywane są do folderu `logs\`, więc log można dołączyć do zgłoszenia.

## Przykładowy wynik

```
=== Diagnostyka sieci: PC-01 ===

[OK  ] Karta sieciowa   Ethernet                     Intel(R) Ethernet (1 Gbps)
[OK  ] Adres IP         192.168.1.15                 Interfejs: Ethernet
[OK  ] Brama domyślna   192.168.1.1                  1 ms
[OK  ] Internet (ping)  8.8.8.8                      14 ms
[OK  ] DNS              google.com                   142.250.186.206 (21 ms)
[OK  ] Port TCP         outlook.office365.com:443    Port otwarty

Diagnoza: Sieć działa poprawnie.
```

## Wymagania

- Windows 10 / 11, PowerShell 5.1+
- Uprawnienia administratora tylko do odnowienia adresu IP w trybie `-Fix`

## Wykorzystane umiejętności

- Model diagnostyki sieci „od dołu” (karta → IP → brama → internet → DNS → usługa)
- Moduły `NetAdapter`, `NetTCPIP`, `DnsClient`
- Klasy .NET `Ping` i `TcpClient` (szybkie testy z limitem czasu)
