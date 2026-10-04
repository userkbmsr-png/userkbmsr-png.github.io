# MediaRR

A one-command installer that sets up a complete, self-hosted media automation stack using Docker and using kiosk mode (Chrome)

## 

## What's included



**Media player**:

* [Stremio](https://www.stremio.com/) — run directly on connected TV or Monitor, or on port 8000 (autostart on screen)
* [Nuvio](nuvio.tv) — free, open-source media app, can be open by selector Mod+Shift+r

**Media server**:

* [Jellyfin](https://jellyfin.org/) — fully open source


**Media management (\*arr stack):**

|Service|Purpose|Port|
|-|-|-|
|[Sonarr](https://sonarr.tv/)|TV show management \& automation|8989|
|[Radarr](https://radarr.video/)|Movie management \& automation|7878|
|[Bazarr](https://www.bazarr.media/)|Automatic subtitle downloads|6767|
|[Prowlarr](https://prowlarr.com/)|Indexer management for Sonarr/Radarr|9696|
|[Scryer](https://www.scryer.media/)|Unified alternative to Sonarr+Radarr+Bazarr|8585|

**Download client:**

* [qBittorrent](https://www.qbittorrent.org/) — torrent client, port 8080

**Behind the scenes:**

* [FlareSolverr](https://github.com/FlareSolverr/FlareSolverr) — helps Prowlarr's indexers get past Cloudflare challenges. No web UI you need to visit; it just needs to be running.

All services share one Docker network (`yams\\\_network`) so they can talk to each other directly.

## Requirements

* A Debian/Ubuntu-based Linux system (tested on Debian 12/13, Ubuntu 22.04/26.04.1 LTS)
* A regular (non-root) user with sudo access — **the installer refuses to run as root**
* Docker \& Docker Compose — the installer offers to install these for you if missing

## Installation

```
curl -fsSL https://raw.githubusercontent.com/userkbmsr-png/MediaRR/main/install-mediarr.sh | sudo bash
```

## Usage

# Mouse
* Clic = play pointed item
* Right click = show/hide rofi (window switcher) with option
    - Stremio
    - Nuvio
    - Jellyfin
    - Scryer
    - Poweroff
      (double click to open)
# Keyboard
   - F1 show rofi (window switcher)
   - F2 Stremio
   - F3 Nuvio
   - F4 Jellyfin
   - F5 Scryer
   - F6 Poweroff
   - Esc hide rofi (window switcher)
   - Enter run selection and hide rofi (window switcher)
 
## Directory layout

```
<install\\\_directory>/         # default: /opt/yams
├── docker-compose.yaml
├── docker-compose.custom.yaml  # add your own services here
├── .env
└── config/                     # one subfolder per service

<media\\\_directory>/           # default: /srv/media
├── tvshows/
├── movies/
├── music/
├── blackhole/                  # torrent watch folder
└── downloads/
    ├── torrents/
   
```

## Managing YAMS

Everything goes through the `yams` command installed during setup:

```bash
yams --help                   # show all commands
yams status                   # check what's running
yams start                    # start every service
yams stop                     # stop every service
yams restart                  # restart every service
yams start jellyfin           # target a single service by name
yams backup /path/to/backup   # stop, archive the install directory, restart
yams update-containers        # pull latest images and restart
yams destroy                  # tear everything down (asks for confirmation)
```

Service URLs are printed at the end of installation and saved to `\\\~/yams\\\_services.txt`.

## Adding your own services

`docker-compose.custom.yaml` is loaded alongside the main compose file and already joins the shared `yams\\\_network` — add any extra container there instead of editing the generated `docker-compose.yaml` directly.

## Credits

Forked from and originally built on [rogsme/yams](https://github.com/rogsme/yams).

Vibecoded with Claude Sonnet 5 — directed and tested by the repo owner.

