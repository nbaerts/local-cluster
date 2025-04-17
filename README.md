# Uncomplicated local cluster setup on k0s

## Requirement
Download the setup tool and the value-template.txt file on the target Debian(ish) server:
```
curl -o ~/local-cluster-setup.sh https://raw.githubusercontent.com/nbaerts/local-cluster/main/setup.sh && chmod 700 ~/local-cluster-setup.sh
curl -o ~/local-cluster-values.txt https://raw.githubusercontent.com/nbaerts/local-cluster/main/value-template.txt
```
Edit the value file `~/local-cluster-value.txt` as per the new local cluster to setup

## Setup the cluster
Execute the following command under root (or sudo root):
```
~/local-cluster-setup.sh -f ./local-cluster-values.txt install
```

## Upgrade the cluster to the latest third parties
Execute the following command under root (or sudo root):
```
~/local-cluster-setup.sh -f ./local-cluster-values.txt upgrade
```

## Upgrade the k0s dynamic config only [no downtime]
Execute the following command under root (or sudo root):
```
~/local-cluster-setup.sh -f ./local-cluster-values.txt upgradeConfig
```

## Upgrade the helm charts only [no downtime]
Execute the following command under root (or sudo root):
```
~/local-cluster-setup.sh upgradeHelm
```

## Uninstall k0s
Execute the following command under root (or sudo root):
```
~/local-cluster-setup.sh uninstall
```

## List of apps
- 🏠 `hello-world`: httpd hello-world application to test the local cluster
- 🪼 [`jellyfin`](https://jellyfin.org/): The free software media system.
    - 🪼 [`jellyseerr`](https://github.com/fallenbagel/jellyseerr): Integrate the *arr stack in Jellyfin
        - ⏺️ [`sonarr`](https://sonarr.tv/): Automated TV show downloader
        - 🎬 [`radarr`](https://radarr.video/): Automated movie downloader
        - 🐯 [`prowlarr`](https://github.com/Prowlarr/Prowlarr): Indexer for the *arr stack
        - ⏬ [`qbittorrent`](https://www.qbittorrent.org/): Torrent client
        - 📰 [`sabnzbd`](https://sabnzbd.org/): Usenet download tool
- 🔒 [`vaultwarden`](https://github.com/dani-garcia/vaultwarden):  Lightweight, open-source (password manager,...) server for Bitwarden clients

## Thanks
Built on the backs of [`k0s`](https://docs.k0sproject.io/stable/), [`ultimatehomeserver.com`](https://ultimatehomeserver.com/), [`*arr stack`](https://wiki.servarr.com/), [`linuxserver.io`](https://www.linuxserver.io/), and more awesome open-source projects.