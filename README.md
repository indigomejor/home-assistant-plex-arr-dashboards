# Offline Media Dashboards for Home Assistant (Plex & *Arr)
A highly resilient, offline-first dashboard suite for Home Assistant. Features zero-latency rendering for Plex, Radarr, and Sonarr, OMDb poster fallbacks, smart downloaded-status filtering, and dynamic release countdowns. 
<img width="1369" height="526" alt="image" src="https://github.com/user-attachments/assets/b7f2093d-cf6d-4cf5-9ef9-096ff8dbec71" />


Choose between the premium glassmorphic **Glacier UI** or the clean, native **Standard Dark UI**.

## Why This Exists (The Problem it Solves)
Standard Home Assistant integrations and custom cards for Plex, Radarr, and Sonarr rely on **live API connections**. If your NAS reboots, your Docker containers crash, or your Plex server goes down for maintenance, your Home Assistant dashboards break, hang on loading screens, or display ugly error messages. 

**This project decouples the frontend from the backend.** Instead of Home Assistant constantly querying your media servers, lightweight background scripts silently compile your library and calendar data into static JSON files. The Home Assistant frontend then reads *only* these static files. 

**The Result:** Even if your entire media server rack is completely powered off, your Home Assistant media dashboards will load instantly and look flawless.

---

## Features
- **Zero-Latency Rendering:** Static HTML frontends fetch pre-compiled JSON data, eliminating Home Assistant rendering lag.
- **Offline Resilient:** Bash scripts feature ping guards. If your NAS is offline, the scripts abort, protecting your last-known cache so your dashboard stays active.
- **OMDb Cascading Fallback:** If local *Arr poster APIs fail, the system automatically cascades through OMDb using IMDb IDs and Regex-stripped titles to guarantee high-resolution artwork.
- **Smart Filtering:** Automatically hides downloaded/aired content (`hasFile` tracking) and features a dynamic rolling 3-day (TV) and 7-day (Movies) release highlight.
- **Two Design Systems:** Includes both the stylized, glassmorphic "Glacier UI" and a flat, clean "Standard" UI.

## Prerequisites
1. Home Assistant OS (with `curl` and `jq` available in the terminal).
2. Plex Media Server.
3. Radarr & Sonarr.
4. A free [OMDb API Key](http://www.omdbapi.com/apikey.aspx).

---

## Installation & Configuration

### Step 1: Copy Files to Home Assistant
Copy the contents of the `scripts/` folder to your Home Assistant `/config/scripts/` directory.
Copy the contents of the `frontend/` folder to your Home Assistant `/config/www/` directory.

### Step 2: Configure the Backend Scripts
Open both Bash scripts (`update_media_cache.sh` and `update_arr_cache.sh`) and replace the placeholder variables at the top of the files with your actual IPs, API keys, and Tokens.
*Important: Ensure both scripts have UNIX (LF) line endings, not Windows (CRLF). Studio Code Server is very useful for this*

### Step 3: Register the Shell Commands
Open your Home Assistant `/config/configuration.yaml` file and add the following lines to expose the scripts to Home Assistant:

```yaml
shell_command:
  update_plex_cache: "/bin/bash /config/scripts/update_media_cache.sh > /dev/null 2>&1 &"
  update_arr_cache: "/bin/bash /config/scripts/update_arr_cache.sh > /dev/null 2>&1 &"
```
##### Restart Home Assistant to apply these changes.

### Step 4: Initialize the Cache (Generate First JSON)
Before you can view your dashboards, you need to run the scripts once to generate the initial data and download the posters.
In the Home Assistant sidebar, click on Developer Tools.
Navigate to the Actions tab.
In the search box, type and select Shell Command: `update_plex_cache` or 
Click the Perform Action button.
Repeat this process for Shell Command: `update_arr_cache`

(Note: The scripts run in the background. Give them 30-60 seconds to fetch your posters and compile the JSON files).

### Step 5: Automate the Updates
To keep your dashboards up to date, trigger the shell commands automatically. Paste the following into your /config/automations.yaml file.

1st Plex Sync (Triggers when library updates or NAS boots):
(Note: Replace the sensor.your_plex_... entities below with your actual Plex library integration sensors).
```yaml
- alias: "System: Update Plex Offline Dashboard"
  description: "Triggers the JSON compiler when new media is added or when NAS boots."
  mode: single
  trigger:
    - trigger: state
      entity_id:
        - sensor.your_plex_movie_library_sensor
        - sensor.your_plex_tv_library_sensor
    - trigger: state
      entity_id: update.your_plex_media_server_entity
      from: "unavailable"
  condition:
    - condition: template
      value_template: "{{ states('sensor.your_plex_movie_library_sensor') | int(0) > 0 }}"
  action:
    - action: shell_command.update_plex_cache
```
```yaml
- alias: "System: Update Arr Calendar Dashboard"
  description: "Triggers the background JSON compiler for Radarr and Sonarr."
  mode: single
  trigger:
    - trigger: time
      at: "08:00:00"
    - trigger: time
      at: "20:00:00"
  condition: []
  action:
    - action: shell_command.update_arr_cache
```

### Step 6: Add the Dashboards to Lovelace
To display the dashboards, use Home Assistant's native Webpage (iframe) card. Go to your Home Assistant dashboard, click Edit Dashboard, click Add Card, and choose Manual.

Paste the YAML below depending on which UI style you prefer.

##### Option 1: Glacier UI (Glassmorphic & Stylized)
Plex Library:
```yaml
type: iframe
url: /local/offline_media_glacier.html?v=1.0
aspect_ratio: 150%
```

```yaml
type: iframe
url: /local/offline_arr_glacier.html?v=1.0
aspect_ratio: 100%
```

##### Option 2: Standard UI (Clean Dark Theme)
Plex Library:

```yaml
type: iframe
url: /local/offline_media_standard.html?v=1.0
aspect_ratio: 150%
Upcoming Releases:
```

```YAML
type: iframe
url: /local/offline_arr_standard.html?v=1.0
aspect_ratio: 100%
(Tip: Whenever you edit the HTML files in the future, simply change ?v=1.0 to ?v=1.1 in your card configuration. This forces the Home Assistant companion apps to clear their cache and load your latest version).
```

<img width="447" height="532" alt="image" src="https://github.com/user-attachments/assets/70acf940-d787-462d-b665-24a90e2a54d6" />
<img width="912" height="527" alt="image" src="https://github.com/user-attachments/assets/4a538dc0-5348-4d38-b825-6b46333a5b18" />
<img width="891" height="517" alt="image" src="https://github.com/user-attachments/assets/8338174f-3af2-49a9-a015-c5ce8dffa5f9" />

---

## ⚠️ Disclaimer and Terms of Use

This project is a custom, hobbyist creation designed strictly for personal use. It is shared with the community "as is" for educational and inspirational purposes. 

By downloading, installing, or modifying these files, you acknowledge and agree to the following:

* **Use at Your Own Risk:** You are solely responsible for how you use this software. Implementing custom scripts and modifying Home Assistant or server configurations carries inherent risks.
* **No Liability:** Under no circumstances shall the author or contributors be held liable for any direct, indirect, incidental, or consequential damages. This includes, but is not limited to: data loss, server downtime, API bans, hardware failures, or network vulnerabilities arising from the use of this code.
* **No Warranty:** This software is provided without warranty of any kind, express or implied. There is no guarantee that it will function flawlessly, integrate with future versions of Home Assistant or the *Arr stack, or remain compatible with third-party APIs (like OMDb).
* **No Guaranteed Support:** Because this is a personal project, there is no official support, troubleshooting assistance, or guarantee of future updates or bug fixes. 

Please review the code, understand what the bash scripts are executing on your hardware, and proceed only if you are comfortable managing your own server environments.
