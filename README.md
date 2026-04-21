# homecloud

Homecloud auf einem Intel NUC – Docker-Stacks, verwaltet via Portainer GitOps.

## Architektur

### Komponenten

| Komponente       | Rolle                                                                   |
|------------------|-------------------------------------------------------------------------|
| **Traefik**      | Ingress Controller: TLS-Terminierung (Let's Encrypt), Routing per Label |
| **cloudflared**  | Cloudflare Tunnel Client: ausgehender Tunnel zu Cloudflare Edge         |
| **CoreDNS**      | Lokaler DNS-Resolver: Split-DNS für `*.tlandsberger.de`                 |
| **Portainer CE** | Stack-Verwaltung via GitOps (dieses Repo)                               |

---

### Zugriff & Split-DNS

**Split-DNS**

```
Anfrage: *.tlandsberger.de
      │
      ├── von intern  →  CoreDNS  →  NUC-LAN-IP (192.168.11.11)
      └── von extern  →  Cloudflare-DNS  →  Cloudflare Edge-IP
```

CoreDNS beantwortet alle A-Anfragen für `*.tlandsberger.de` mit der NUC-LAN-IP.
AAAA-Anfragen werden mit NOERROR + leerem Ergebnis beantwortet (kein IPv6-Record).
Alle anderen Domains werden an den Router weitergeleitet.

**Warum AAAA-Unterdrückung?**
Ohne den `template IN AAAA { rcode NOERROR }` Block beantwortet CoreDNS AAAA-Anfragen nicht.
Das Betriebssystem fragt dann den nächsten DNS-Server (FritzBox, via IPv6 RA verteilt) – dieser
kennt die Split-DNS-Logik nicht und gibt die öffentliche Cloudflare-IPv6-Adresse zurück.
Da IPv6 gegenüber IPv4 bevorzugt wird, landet der Traffic bei Cloudflare statt beim NUC.

**Interner Zugriff (LAN → Service)**

```
Browser (LAN)
      │
      ▼  DNS-Anfrage: portainer.tlandsberger.de
CoreDNS  (NUC, Port 53)
      │  → antwortet mit NUC-LAN-IP (Split-DNS)
      ▼
Traefik  (NUC-LAN-IP:443, direkt über LAN)
      │
      ▼
Service
```

LAN-Geräte sprechen Traefik **direkt** an – kein Umweg über Cloudflare.
CoreDNS wird über den FritzBox-DHCP-Server als primärer DNS-Server
an alle LAN-Geräte verteilt.

**Externer Zugriff (Internet → Service)**

```
Browser (Internet)
      │
      ▼
Cloudflare Edge  ──  Zero Trust Access Check (E-Mail OTP)
      │
      │  Cloudflare Zero Trust Tunnel (ausgehende Verbindung von cloudflared)
      ▼
cloudflared  (Docker, Netzwerk: proxy)
      │
      ▼
Traefik  (Docker, Port 443, Let's Encrypt TLS)
      │
      ▼
Service (z.B. portainer.tlandsberger.de)
```

Der Cloudflare-Tunnel wird von `cloudflared` **ausgehend** aufgebaut –
am Router muss kein Port freigegeben werden. Cloudflare Access fungiert
als vorgelagerter Identity Provider (E-Mail OTP).

**FritzBox-Konfiguration (erforderlich):**

- DNS-Rebind-Schutz-Ausnahme für `tlandsberger.de`
  (sonst blockiert FritzBox Antworten, die eine öffentliche Domain auf eine private IP auflösen)
- DHCP: NUC-LAN-IP als primären DNS-Server an LAN-Geräte verteilen
- Optional: IPv6 RA DNS-Advertisement deaktivieren, um FritzBox vollständig als DNS-Fallback zu entfernen

---

### TLS & Zertifikate

Traefik bezieht Let's Encrypt-Zertifikate über **DNS-Challenge** – kein eingehender Port nötig:

1. Traefik setzt einen DNS-TXT-Eintrag via Cloudflare API (`CF_DNS_API_TOKEN`)
2. Let's Encrypt validiert den Eintrag gegen das öffentliche Cloudflare-DNS
3. Cloudflare-Modus: **Full (Strict)** – Cloudflare verifiziert das Zertifikat von Traefik

---

### Docker-Netzwerk

| Netzwerk | Typ    | Zweck                                            |
|----------|--------|--------------------------------------------------|
| `proxy`  | extern | Verbindet Traefik, cloudflared und alle Services |

**Secret-Management:** Portainer Stack-Umgebungsvariablen (in Portainers Data-Volume)

---

### GitOps-Workflow

```
Änderung im Repo → git push → Portainer erkennt nach ≤60s → automatisches Redeploy
```

---

### Automatische Image-Updates (Renovate)

Alle Image-Tags sind auf feste Versionen gepinnt. [Renovate Bot](https://github.com/apps/renovate)
öffnet automatisch Pull Requests für neue Versionen – Konfiguration in `renovate.json`.

#### Einmalige Einrichtung

[Renovate GitHub App](https://github.com/apps/renovate) auf dem Repository installieren –
Renovate liest `renovate.json` dann automatisch aus.

#### Update-Kritikalität

| Update-Typ | Paket                    | Behandlung                  |
|------------|--------------------------|-----------------------------|
| Patch      | alle                     | automatisch gemerged        |
| Minor      | Nicht-Infrastruktur      | automatisch gemerged        |
| Minor      | Infrastruktur¹           | **Approval erforderlich**   |
| Major      | alle                     | **Approval erforderlich**   |

¹ Infrastruktur-Pakete: `traefik`, `coredns/coredns`, `cloudflare/cloudflared`, `portainer/portainer-ce`

#### Kritische Updates genehmigen

Approval erfolgt über das **„Renovate Dependency Dashboard"**-Issue im GitHub-Repo
(automatisch von Renovate erstellt). Dort erscheinen alle ausstehenden Updates, die
manuelles Eingreifen erfordern.

---

## Vollständiges Setup-Runbook

Alle Schritte in chronologischer Reihenfolge – vollständig ausführbar bei Systemwechsel.

---

### Schritt 1 – Cloudflare vorbereiten

#### 1.1 Domain zu Cloudflare hinzufügen

1. [dash.cloudflare.com](https://dash.cloudflare.com) → **Add a Site** → `tlandsberger.de`
2. Free-Plan auswählen → Cloudflare zeigt zwei Nameserver an (z.B. `ada.ns.cloudflare.com`)
3. Bei **IONOS**: Nameserver von IONOS auf die Cloudflare-Nameserver umstellen
4. Warten auf DNS-Propagation (5–30 Minuten, prüfen mit `dig NS tlandsberger.de`)

#### 1.2 Cloudflare API-Token erstellen (für Let's Encrypt DNS-Challenge)

1. [dash.cloudflare.com](https://dash.cloudflare.com) → **My Profile → API Tokens → Create Token**
2. Template: **Edit zone DNS** → Zone: `tlandsberger.de`
3. Token notieren → wird als `CF_DNS_API_TOKEN` in Portainer hinterlegt

#### 1.3 Cloudflare Tunnel erstellen

1. [one.dash.cloudflare.com](https://one.dash.cloudflare.com) → **Networks → Connectors → Cloudflare Tunnels → Create a
   tunnel**
2. Name: `homecloud` → Connector: Docker
3. Tunnel-Token notieren → wird als `CLOUDFLARE_TUNNEL_TOKEN` in Portainer hinterlegt
4. **Public Hostname** als Wildcard konfigurieren:

   | Subdomain | Domain | Service |
      |---|---|---|
   | `*` | `tlandsberger.de` | `https://traefik:8443` |

   > **TLS-Einstellung:** Unter **Additional application settings → TLS → No TLS Verify aktivieren.**
   > cloudflared verbindet sich intern über `https://traefik:8443` – der Docker-Hostname `traefik`
   > stimmt nicht mit dem öffentlichen Zertifikat überein. No TLS Verify verhindert diesen Fehler.
   > Cloudflare-Modus: **Full (Strict)** (gilt für Browser → Cloudflare Edge, unverändert)

   Cloudflare erstellt automatisch einen Wildcard-CNAME-DNS-Eintrag (
   `*.tlandsberger.de → <tunnel-id>.cfargotunnel.com`).
   Neue Services benötigen danach **keine DNS- oder Tunnel-Änderungen** mehr – nur Traefik-Labels im Compose-File.

#### 1.4 Cloudflare Access Control einrichten

1. [one.dash.cloudflare.com](https://one.dash.cloudflare.com) → **Access controls → Applications → Add an application**
2. Typ: **Self-hosted**
3. Application name: `Homecloud`
4. Application domain: `*.tlandsberger.de` (Wildcard – schützt alle Subdomains auf einmal)
5. Policy erstellen: z.B. **Include → Emails → deine@email.de** (Login via E-Mail OTP)

#### 1.5 htpasswd-Hash für Traefik Dashboard generieren

```bash
# Lokal ausführen, Output als TRAEFIK_DASHBOARD_AUTH in Portainer hinterlegen
htpasswd -nB admin | sed -e 's/\$/\$\$/g'
# Beispiel-Output: admin:$apr1$xyz...
```

---

### Schritt 2 – NUC mit Ubuntu Server vorbereiten

#### 2.1 Ubuntu Server LTS installieren

1. Aktuelle LTS-ISO von [ubuntu.com/download/server](https://ubuntu.com/download/server) herunterladen
2. Bootfähigen USB-Stick erstellen:
   ```bash
   # macOS/Linux (Dateiname an heruntergeladene ISO anpassen)
   sudo dd if=ubuntu-XX.XX-live-server-amd64.iso of=/dev/sdX bs=4M status=progress
   # Windows: Rufus oder balenaEtcher verwenden
   ```
3. NUC vom USB-Stick booten (F10 beim Start → Boot-Menü)
4. Installationsoptionen:
    - **Minimale Installation** (kein Desktop)
    - **OpenSSH-Server** aktivieren ✓
    - Speicher: LVM ohne Encryption (einfacher für Backups)
    - Hostname: `homecloud`
    - Benutzername: z.B. `ubuntu`

#### 2.2 Feste LAN-IP sicherstellen

Der NUC benötigt eine feste IP im LAN, da er als DNS-Server fungiert.
Die feste LAN-IP des NUC lautet `192.168.11.11`.

> **Heimnetz → Netzwerk → Heimnetz-Übersicht** → NUC-Gerät anklicken
> → „Diesem Gerät immer dieselbe IPv4-Adresse zuweisen" aktivieren

#### 2.3 Setup-Skript ausführen

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tlandsberger/homecloud/main/host/init.sh)
```

> Das Skript zeigt alle verfügbaren Partitionen und lässt interaktiv die Docker- und Media-Partition auswählen.
> Nach dem Playbook wird automatisch ein Reboot ausgeführt, damit die `docker`-Gruppe wirksam wird.
> Der Reboot erfolgt nur beim ersten Durchlauf – bei erneutem Ausführen (idempotent) wird er übersprungen.

> Portainer wird vom Playbook automatisch gestartet und ist danach unter `http://192.168.11.11:9000` erreichbar. Beim ersten Aufruf: Admin-Account anlegen.

`host/playbook.yml` übernimmt: System-Update, automatische Sicherheitsupdates
(Wartungsfenster **Sonntag 4:00 Uhr**, Reboot 4:30 Uhr), Docker-Installation,
`proxy`-Netzwerk, optionale zweite Festplatte für Docker-Volumes,
optionale Media-Disk unter `/mnt/media` (Automount) und einen systemd-Timer
für automatische Portainer-Updates (alle 5 Minuten `git pull` + `docker compose up`).

Das Playbook ist idempotent – es kann jederzeit erneut ausgeführt werden,
um Konfigurationsänderungen sicher einzuspielen.

Konfigurationsdateien in `host/`:

| Datei                             | Ziel auf dem Host                                | Zweck                                |
|-----------------------------------|--------------------------------------------------|--------------------------------------|
| `host/20auto-upgrades`            | `/etc/apt/apt.conf.d/`                           | Automatische Updates aktivieren      |
| `host/50unattended-upgrades`      | `/etc/apt/apt.conf.d/`                           | Sicherheits-Origins, Reboot 4:30 Uhr |
| `host/apt-daily-upgrade.override` | `/etc/systemd/system/apt-daily-upgrade.timer.d/` | Wartungsfenster Sonntag 4:00 Uhr     |

**Zweite Festplatte für Docker-Daten (optional)**

Das Playbook fragt interaktiv nach der UUID der zweiten Festplatte.
Die UUID kann vorab mit `lsblk -f` ermittelt werden (Spalte `UUID`).
Formatierung (ext4), direkter Mount unter `/var/lib/docker` und fstab-Eintrag
laufen vollautomatisch ab. Alle Docker-Daten (Images, Container, Volumes, Build-Cache)
landen auf der zweiten Disk – keine zusätzliche Docker-Konfiguration nötig.

Bei Eingabe von Enter wird dieser Schritt übersprungen – alle Docker-Daten liegen
auf der Haupt-Disk unter `/var/lib/docker/`.

**Media-Disk (optional)**

Das Playbook fragt zusätzlich nach der UUID einer Media-Partition.
Diese wird unter `/mnt/media` mit systemd-Automount eingebunden (On-Demand-Mount
beim ersten Zugriff, 10s Timeout). Unterstützt ext4, exFAT und NTFS.
Wird von Samba, Jellyfin und dem Backup-Stack genutzt.

---

### Schritt 3 – FritzBox konfigurieren

#### 3.1 DNS-Rebind-Schutz-Ausnahme

> **Heimnetz → Netzwerk → DNS-Rebind-Schutz**
> → Hostname eintragen: `tlandsberger.de`

Ohne diese Ausnahme blockiert die FritzBox Antworten, die eine öffentliche Domain
auf eine private IP auflösen.

#### 3.2 DNS-Server auf NUC umstellen (nach Schritt 5 – CoreDNS läuft)

> **Heimnetz → Netzwerk → Heimnetz-Übersicht → DNS-Rebind-Schutz (erweitert)**
> Alternativ: Im DHCP-Server den primären DNS-Server auf die NUC-LAN-IP setzen

Danach lösen alle Heimnetz-Geräte `*.tlandsberger.de` direkt auf die NUC-IP auf
(statt über Cloudflare).

---

### Schritt 4 – Backup

**Strategie:** Alle Docker Volumes täglich um 02:30 Uhr sichern – verschlüsselt, inkrementell, an zwei Standorten:

| Standort | Pfad                              | Zweck                          |
|----------|-----------------------------------|--------------------------------|
| Lokal    | `/mnt/media/backup` (zweite Disk) | Schnelle Wiederherstellung     |
| Remote   | OneDrive                          | Offsite-Kopie bei Disk-Verlust |

**Tools:** `restic` (Verschlüsselung, Deduplizierung, Snapshots) + `rclone` (OneDrive-Transport). Stack:
`infrastructure/backup/`.

**Was wird gesichert:** Alle Docker Volumes (`/var/lib/docker/volumes`), außer regenerierbare Daten (Loki, Prometheus,
Alloy, Plex-Cache).

---

#### 4.1 OneDrive OAuth einrichten (einmalig, auf dem Mac)

```bash
# rclone installieren (einmalig)
brew install rclone

# Interaktiver OAuth-Flow – Browser öffnet sich automatisch
rclone config create homecloud-onedrive onedrive

# Config base64-kodieren → in Portainer als RCLONE_CONFIG_BASE64 hinterlegen
base64 -i ~/.config/rclone/rclone.conf | tr -d '\n'
```

> Der OAuth-Refresh-Token läuft nach 90 Tagen Inaktivität ab. Solange Backups regelmäßig laufen, verlängert er sich automatisch.

---

#### 4.2 Backup-Stack in Portainer deployen

**Portainer-Variablen für `infrastructure/backup/`:**

| Variable               | Wert                                                                                                                                        |
|------------------------|---------------------------------------------------------------------------------------------------------------------------------------------|
| `RESTIC_PASSWORD`      | Encryption-Key für beide Repos. Generieren: `openssl rand -base64 32`. **Sicher aufbewahren** – ohne diesen Key sind alle Backups unlesbar. |
| `RCLONE_CONFIG_BASE64` | Ausgabe aus Schritt 4.1                                                                                                                     |

Stack wie gewohnt über **Stacks → Add stack → Repository** anlegen (Compose-Pfad:
`infrastructure/backup/docker-compose.yml`). Portainer baut das Image beim ersten Deploy automatisch.

---

#### 4.3 Repos werden automatisch initialisiert

Beim ersten Container-Start prüft `entrypoint.sh` ob die Repos existieren und initialisiert sie bei Bedarf – kein manueller Schritt nötig. Die Logs (`docker logs restic-backup`) zeigen ob alles geklappt hat.

---

#### 4.4 Backup-Betrieb

```bash
# Backup sofort auslösen (z.B. vor größeren Änderungen)
docker exec restic-backup /backup.sh

# Snapshots anzeigen
docker exec restic-backup sh -c 'RESTIC_REPOSITORY=/data/backup restic snapshots'        # lokal
docker exec restic-backup sh -c 'RESTIC_REPOSITORY="$RESTIC_REMOTE_REPOSITORY" restic snapshots'  # OneDrive

# Integrität prüfen
docker exec restic-backup sh -c 'RESTIC_REPOSITORY=/data/backup restic check'

# Backup-Logs der letzten 24h
docker logs restic-backup --since 24h
```

---

#### 4.5 Restore

**Einzelnes Volume wiederherstellen** (aus lokalem Repo – schnellste Option):

```bash
# 1. Betroffenen Service stoppen
docker stop homeassistant mosquitto

# 2. Restore (Image-Name = Portainer-Stack-Name + "_restic", z.B. "backup_restic")
docker run --rm \
  -e RESTIC_REPOSITORY=/data/backup \
  -e RESTIC_PASSWORD=<pw> \
  -v /var/lib/docker/volumes:/data/volumes \
  -v /mnt/media/backup:/data/backup:ro \
  --entrypoint sh backup_restic \
  -c 'restic restore latest \
        --path /data/volumes/homeassistant_homeassistant_config \
        --target /'

# 3. Service starten
docker start homeassistant mosquitto
```

**Disaster Recovery – zweite Disk verloren** (aus OneDrive):

```bash
docker run --rm \
  -e RESTIC_REPOSITORY=rclone:homecloud-onedrive:backup/homecloud \
  -e RESTIC_PASSWORD=<pw> \
  -e RCLONE_CONFIG_BASE64=<base64> \
  -v /var/lib/docker/volumes:/data/volumes \
  --entrypoint sh backup_restic \
  -c 'mkdir -p /root/.config/rclone && \
      printf "%s" "$RCLONE_CONFIG_BASE64" | base64 -d > /root/.config/rclone/rclone.conf && \
      restic restore latest --target /'
```

**NUC komplett neu aufsetzen:**

```bash
# 1. host/playbook.yml ausführen
# 2. Portainer bootstrappen (infrastructure/portainer/docker-compose.yml)
# 3. Backup-Stack deployen (Image wird gebaut)
# 4. Alle Volumes restoren (zweite Disk noch vorhanden):
docker run --rm \
  -e RESTIC_REPOSITORY=/data/backup \
  -e RESTIC_PASSWORD=<pw> \
  -v /var/lib/docker/volumes:/data/volumes \
  -v /mnt/media/backup:/data/backup:ro \
  --entrypoint sh backup_restic \
  -c 'restic restore latest --target /'
# 5. Alle anderen Stacks in Portainer deployen → Volumes bereits gefüllt
```

---

### Schritt 5 – Stacks deployen (Reihenfolge einhalten)

Für jeden Stack in Portainer: **Stacks → Add stack → Repository**

- Repository URL: `https://github.com/tlandsberger/homecloud`
- Credentials: (hinterlegter GitHub PAT)
- Compose path: (s. Tabelle unten)
- Auto-Update: **Polling** aktivieren, Intervall: 60 Sekunden

| Reihenfolge | Stack           | Compose-Pfad                                     |
|-------------|-----------------|--------------------------------------------------|
| 1           | `coredns`       | `infrastructure/coredns/docker-compose.yml`      |
| 2           | `traefik`       | `infrastructure/traefik/docker-compose.yml`      |
| 3           | `cloudflared`   | `infrastructure/cloudflared/docker-compose.yml`  |
| 4           | `monitoring`    | `infrastructure/monitoring/docker-compose.yml`   |
| 5           | `keycloak`      | `infrastructure/keycloak/docker-compose.yml`     |
| 6           | `samba`         | `infrastructure/samba/docker-compose.yml`        |
| 7           | `backup`        | `infrastructure/backup/docker-compose.yml`       |
| 8           | `homeassistant` | `application/homeassistant/docker-compose.yml`   |
| 9           | `jellyfin`      | `application/jellyfin/docker-compose.yml`        |
| 10          | `nextcloud`     | `application/nextcloud/docker-compose.yml`       |
| 11          | `windows`       | `application/windows/docker-compose.yml`         |

Nach dem Deploy von CoreDNS: **FritzBox DHCP-DNS auf NUC-IP umstellen** (Schritt 3.2).

**Umgebungsvariablen pro Stack** (beim Anlegen unter *Environment variables* eintragen):

#### infrastructure/traefik

| Variable                 | Wert                                                |
|--------------------------|-----------------------------------------------------|
| `DOMAIN`                 | `tlandsberger.de`                                   |
| `ACME_EMAIL`             | E-Mail-Adresse für Let's Encrypt-Benachrichtigungen |
| `CF_DNS_API_TOKEN`       | Cloudflare API-Token aus Schritt 1.2                |
| `TRAEFIK_DASHBOARD_AUTH` | htpasswd-Hash aus Schritt 1.5                       |

#### infrastructure/cloudflared

| Variable                  | Wert                         |
|---------------------------|------------------------------|
| `CLOUDFLARE_TUNNEL_TOKEN` | Tunnel-Token aus Schritt 1.3 |

#### infrastructure/monitoring

Keine Secrets erforderlich – alle Konfigurationen sind im Compose-File enthalten.

#### infrastructure/keycloak

| Variable               | Wert                                                                                                      |
|------------------------|-----------------------------------------------------------------------------------------------------------|
| `KEYCLOAK_DB_PASSWORD` | PostgreSQL-Passwort für Keycloak. Generieren: `openssl rand -base64 32`                                   |

> Beim ersten Start wird ein temporärer Admin-Account (`temp-admin` / `temp-admin`) erstellt.
> Nach dem ersten Login **sofort ändern**.

#### infrastructure/samba

| Variable       | Wert                                              |
|----------------|---------------------------------------------------|
| `SMB_PASSWORD` | Passwort für den Samba-Benutzer `smb` (beliebig)  |

#### application/homeassistant

| Variable         | Wert                                       |
|------------------|--------------------------------------------|
| `MQTT_USER`      | Benutzername für den MQTT-Broker           |
| `MQTT_PASSWORD`  | Passwort für den MQTT-Broker               |

#### application/jellyfin

Keine Secrets erforderlich. Benötigt GPU-Zugriff (`/dev/dri`) für Hardware-Transcoding
und die Media-Disk unter `/mnt/media`.

#### application/nextcloud

| Variable                | Wert                                                                    |
|-------------------------|-------------------------------------------------------------------------|
| `NEXTCLOUD_DB_PASSWORD` | PostgreSQL-Passwort für Nextcloud. Generieren: `openssl rand -base64 32` |

#### application/windows

Keine Secrets erforderlich. Benötigt KVM-Unterstützung auf dem Host (`/dev/kvm`).
Erreichbar unter `win.tlandsberger.de` (Web-UI) und per RDP auf Port 3389 (direktes Host-Port-Binding).
