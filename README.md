# Glacier Offline Media Dashboards for Home Assistant

A highly resilient, offline-first dashboard suite for Home Assistant. Features zero-latency Glacier UI for Plex, Radarr, and Sonarr, OMDb poster fallbacks, smart downloaded-status filtering, and dynamic release countdowns, all beautifully rendered with glassmorphic design and absolute anchoring.

## Why This Exists (The Problem it Solves)
Standard Home Assistant integrations and custom cards for Plex, Radarr, and Sonarr rely on **live API connections**. If your NAS reboots, your Docker containers crash, or your Plex server goes down for maintenance, your Home Assistant dashboards break, hang on loading screens, or display ugly error messages. 

**This project decouples the frontend from the backend.** Instead of Home Assistant constantly querying your media servers, lightweight background scripts silently compile your library and calendar data into static JSON files. The Home Assistant frontend then reads *only* these static files. 

**The Result:** Even if your entire media server rack is completely powered off, your Home Assistant media dashboards will load instantly and look flawless, showing you exactly what is in your library and what releases are coming up.

---

## Features
- **Zero-Latency Rendering:** Static HTML frontends fetch pre-compiled JSON data, eliminating Home Assistant rendering lag.
- **Offline Resilient:** Bash scripts feature ping guards. If your NAS is offline, the scripts abort, protecting your last-known cache so your dashboard stays active.
- **OMDb Cascading Fallback:** If local *Arr poster APIs fail, the system automatically cascades through OMDb using IMDb IDs and Regex-stripped titles to guarantee high-resolution artwork.
- **Smart Filtering:** Automatically hides downloaded/aired content (`hasFile` tracking) and features a dynamic rolling 3-day (TV) and 7-day (Movies) release highlight.
- **Glacier UI:** Premium glassmorphic design with absolute-anchored UI badges and protected text truncation for mobile screens.

## Prerequisites
1. Home Assistant OS (with `curl` and `jq` available in the terminal).
2. Plex Media Server.
3. Radarr & Sonarr.
4. A free [OMDb API Key](http://www.omdbapi.com/apikey.aspx).

---

## Installation & Configuration

### Step 1: Copy Files to Home Assistant
Copy the contents of the `scripts/` folder to your Home Assistant `/config/scripts/` directory.
Copy the contents of the `www/` folder to your Home Assistant `/config/www/` directory.

### Step 2: Configure the Backend Scripts
Open both Bash scripts and replace the placeholder variables at the top of the files with your actual data.

**In `scripts/update_media_cache.sh`:**
- `PLEX_IP`: Your Plex Server IP (e.g., `"192.168.1.50"`)
- `PLEX_TOKEN`: Your [Plex Token](https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/)
- `MOVIE_SECTION`: The library ID for your Plex Movies (usually `"1"`, `"2"`, etc.)
- `TV_SECTION`: The library ID for your Plex TV Shows
- `OMDB_API_KEY`: Your OMDb API Key

**In `scripts/update_arr_cache.sh`:**
- `NAS_IP`: The IP address of your Radarr/Sonarr host
- `RADARR_API`: Found in Radarr -> Settings -> General
- `SONARR_API`: Found in Sonarr -> Settings -> General
- `OMDB_API_KEY`: Your OMDb API Key

*Important: Ensure both scripts have UNIX (LF) line endings, not Windows (CRLF).*

### Step 3: Configure Home Assistant YAML
Copy the templates from the `home_assistant_templates/` folder into your actual Home Assistant configuration.

1. **`configuration.yaml`**: Adds the shell commands to run the scripts. Restart Home Assistant after adding these.
2. **`automations.yaml`**: Contains the triggers. You must update the `entity_id` placeholders to match your actual Plex library sensors (e.g., `sensor.plex_movies`).
3. **`lovelace_cards.yaml`**: Add these Custom iframe cards to your dashboard. Note the `?v=X.X` URL parameter—increment this number manually to clear the HA app cache if you ever edit the HTML files.

### Step 4: Initialize the Cache
Before opening the dashboards, manually run both scripts once in your Home Assistant terminal to generate the initial `plex_data.json` and `arr_data.json` files:
```bash
bash /config/scripts/update_media_cache.sh
bash /config/scripts/update_arr_cache.sh
