#!/bin/bash

# ==============================================================================
# *ARR OFFLINE CALENDAR BACKEND (JSON GENERATOR)
# ==============================================================================

# --- CONFIGURATION (CHANGE THESE) ---
NAS_IP="<YOUR_NAS_IP>"
RADARR_PORT="7878"
RADARR_API="<YOUR_RADARR_API>"
SONARR_PORT="8989"
SONARR_API="<YOUR_SONARR_API>"
OMDB_API_KEY="<YOUR_OMDB_API_KEY>"
DAYS_AHEAD="90"

# --- POSIX DATE MATH ---
TS=$(date +%s)
START_DATE=$(date -d "@$((TS - 86400))" '+%Y-%m-%d')
END_DATE=$(date -d "@$((TS + DAYS_AHEAD * 86400))" '+%Y-%m-%d')

# --- SAFETY GUARDS ---
RADARR_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "http://$NAS_IP:$RADARR_PORT/api/v3/system/status?apiKey=$RADARR_API")
if [ "$RADARR_STATUS" != "200" ]; then echo "Radarr offline. Aborting."; exit 1; fi

SONARR_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "http://$NAS_IP:$SONARR_PORT/api/v3/system/status?apiKey=$SONARR_API")
if [ "$SONARR_STATUS" != "200" ]; then echo "Sonarr offline. Aborting."; exit 1; fi

# --- DIRECTORY PREP ---
mkdir -p /config/www/posters/arr
TMP_RADARR="/tmp/arr_movies.jsonl"
TMP_SONARR="/tmp/arr_shows.jsonl"
FINAL_JSON="/config/www/arr_data.json"
rm -f "$TMP_RADARR" "$TMP_SONARR"
touch "$TMP_RADARR" "$TMP_SONARR"

# ==============================================================================
# PHASE 1: RADARR (MOVIES)
# ==============================================================================
curl -s "http://$NAS_IP:$RADARR_PORT/api/v3/movie?apiKey=$RADARR_API" | jq -c '.[]' | while read -r movie; do
    MONITORED=$(echo "$movie" | jq -r '.monitored')
    if [ "$MONITORED" != "true" ]; then continue; fi

    ID=$(echo "$movie" | jq -r '.id')
    IMDB_ID=$(echo "$movie" | jq -r '.imdbId // "null"')
    TITLE=$(echo "$movie" | jq -r '.title // ""' | sed 's/&/\&amp;/g; s/"/\&quot;/g; s/'\''/\&#39;/g')
    HAS_FILE=$(echo "$movie" | jq -r '.hasFile // false')
    
    CINEMA_DATE=$(echo "$movie" | jq -r '.inCinemas // "null"')
    DIGITAL_DATE=$(echo "$movie" | jq -r '.digitalRelease // "null"')
    if [ "$DIGITAL_DATE" == "null" ] || [ -z "$DIGITAL_DATE" ]; then DIGITAL_DATE=$(echo "$movie" | jq -r '.physicalRelease // "null"'); fi
    
    RATING=$(echo "$movie" | jq -r '.ratings.imdb.value // "0"')
    if [ "$CINEMA_DATE" == "null" ] && [ "$DIGITAL_DATE" == "null" ]; then continue; fi

    POSTER_PATH="/config/www/posters/arr/radarr_${ID}.jpg"
    IMG_LOCAL=""
    
    if [ ! -f "$POSTER_PATH" ]; then
        DOWNLOADED=false
        if [ -n "$OMDB_API_KEY" ]; then
            OMDB_POSTER="null"
            if [ "$IMDB_ID" != "null" ] && [ -n "$IMDB_ID" ]; then OMDB_POSTER=$(curl -s "http://www.omdbapi.com/?i=$IMDB_ID&apikey=$OMDB_API_KEY" | jq -r '.Poster // "null"'); fi
            if [ "$OMDB_POSTER" == "null" ] || [ "$OMDB_POSTER" == "N/A" ]; then
                ENCODED_TITLE=$(echo -n "$TITLE" | jq -sRr @uri)
                OMDB_POSTER=$(curl -s "http://www.omdbapi.com/?t=$ENCODED_TITLE&apikey=$OMDB_API_KEY" | jq -r '.Poster // "null"')
                if [ "$OMDB_POSTER" == "null" ] || [ "$OMDB_POSTER" == "N/A" ]; then
                    CLEAN_TITLE=$(echo "$TITLE" | sed -E 's/ \([0-9]{4}\)//')
                    if [ "$CLEAN_TITLE" != "$TITLE" ]; then
                        ENCODED_CLEAN=$(echo -n "$CLEAN_TITLE" | jq -sRr @uri)
                        OMDB_POSTER=$(curl -s "http://www.omdbapi.com/?t=$ENCODED_CLEAN&apikey=$OMDB_API_KEY" | jq -r '.Poster // "null"')
                    fi
                fi
            fi
            if [ "$OMDB_POSTER" != "null" ] && [ "$OMDB_POSTER" != "N/A" ]; then curl -s -o "$POSTER_PATH" "$OMDB_POSTER"; DOWNLOADED=true; fi
        fi
        
        if [ "$DOWNLOADED" = false ]; then
            IMAGE_URL=$(echo "$movie" | jq -r '.images[]? | select(.coverType=="poster") | .url' | head -n 1)
            if [ -n "$IMAGE_URL" ] && [ "$IMAGE_URL" != "null" ]; then
                IMAGE_URL="/${IMAGE_URL#/}"
                if [[ "$IMAGE_URL" == *"?"* ]]; then DL_URL="${IMAGE_URL}&apikey=${RADARR_API}"; else DL_URL="${IMAGE_URL}?apikey=${RADARR_API}"; fi
                curl -s -o "$POSTER_PATH" "http://$NAS_IP:$RADARR_PORT${DL_URL}"
            fi
        fi
    fi

    if [ -f "$POSTER_PATH" ]; then IMG_LOCAL="/local/posters/arr/radarr_${ID}.jpg"; fi

    jq -n --arg id "$ID" --arg title "$TITLE" --arg img "$IMG_LOCAL" --arg cinema "$CINEMA_DATE" --arg digital "$DIGITAL_DATE" --arg rating "$RATING" --argjson hasFile "$HAS_FILE" '{id: $id, type: "movie", title: $title, img: $img, cinemaRelease: $cinema, digitalRelease: $digital, rating: $rating, hasFile: $hasFile}' >> "$TMP_RADARR"
done

# ==============================================================================
# PHASE 2: SONARR (TV SHOWS)
# ==============================================================================
curl -s "http://$NAS_IP:$SONARR_PORT/api/v3/calendar?apiKey=$SONARR_API&start=$START_DATE&end=$END_DATE&includeSeries=true" | jq -c '.[]' | while read -r ep; do
    ID=$(echo "$ep" | jq -r '.id')
    SERIES_ID=$(echo "$ep" | jq -r '.seriesId')
    IMDB_ID=$(echo "$ep" | jq -r '.series.imdbId // "null"')
    SHOW_TITLE=$(echo "$ep" | jq -r '.series.title // "Unknown Show"' | sed 's/&/\&amp;/g; s/"/\&quot;/g; s/'\''/\&#39;/g')
    EP_TITLE=$(echo "$ep" | jq -r '.title // "TBA"' | sed 's/&/\&amp;/g; s/"/\&quot;/g; s/'\''/\&#39;/g')
    SEASON=$(echo "$ep" | jq -r '.seasonNumber // 0')
    EPISODE=$(echo "$ep" | jq -r '.episodeNumber // 0')
    RUNTIME=$(echo "$ep" | jq -r '.series.runtime // 0')
    AIR_DATE=$(echo "$ep" | jq -r '.airDateUtc // ""')
    HAS_FILE=$(echo "$ep" | jq -r '.hasFile // false')
    SXXEYY=$(printf "S%02dE%02d" "$SEASON" "$EPISODE")

    POSTER_PATH="/config/www/posters/arr/sonarr_${SERIES_ID}.jpg"
    IMG_LOCAL=""

    if [ ! -f "$POSTER_PATH" ]; then
        DOWNLOADED=false
        if [ -n "$OMDB_API_KEY" ]; then
            OMDB_POSTER="null"
            if [ "$IMDB_ID" != "null" ] && [ -n "$IMDB_ID" ]; then OMDB_POSTER=$(curl -s "http://www.omdbapi.com/?i=$IMDB_ID&apikey=$OMDB_API_KEY" | jq -r '.Poster // "null"'); fi
            if [ "$OMDB_POSTER" == "null" ] || [ "$OMDB_POSTER" == "N/A" ]; then
                ENCODED_TITLE=$(echo -n "$SHOW_TITLE" | jq -sRr @uri)
                OMDB_POSTER=$(curl -s "http://www.omdbapi.com/?t=$ENCODED_TITLE&apikey=$OMDB_API_KEY" | jq -r '.Poster // "null"')
                if [ "$OMDB_POSTER" == "null" ] || [ "$OMDB_POSTER" == "N/A" ]; then
                    CLEAN_TITLE=$(echo "$SHOW_TITLE" | sed -E 's/ \([0-9]{4}\)//')
                    if [ "$CLEAN_TITLE" != "$SHOW_TITLE" ]; then
                        ENCODED_CLEAN=$(echo -n "$CLEAN_TITLE" | jq -sRr @uri)
                        OMDB_POSTER=$(curl -s "http://www.omdbapi.com/?t=$ENCODED_CLEAN&apikey=$OMDB_API_KEY" | jq -r '.Poster // "null"')
                    fi
                fi
            fi
            if [ "$OMDB_POSTER" != "null" ] && [ "$OMDB_POSTER" != "N/A" ]; then curl -s -o "$POSTER_PATH" "$OMDB_POSTER"; DOWNLOADED=true; fi
        fi
        
        if [ "$DOWNLOADED" = false ]; then
            IMAGE_URL=$(echo "$ep" | jq -r '.series.images[]? | select(.coverType=="poster") | .url' | head -n 1)
            if [ -n "$IMAGE_URL" ] && [ "$IMAGE_URL" != "null" ]; then
                IMAGE_URL="/${IMAGE_URL#/}"
                if [[ "$IMAGE_URL" == *"?"* ]]; then DL_URL="${IMAGE_URL}&apikey=${SONARR_API}"; else DL_URL="${IMAGE_URL}?apikey=${SONARR_API}"; fi
                curl -s -o "$POSTER_PATH" "http://$NAS_IP:$SONARR_PORT${DL_URL}"
            fi
        fi
    fi

    if [ -f "$POSTER_PATH" ]; then IMG_LOCAL="/local/posters/arr/sonarr_${SERIES_ID}.jpg"; fi

    jq -n --arg id "$ID" --arg showTitle "$SHOW_TITLE" --arg epTitle "$EP_TITLE" --arg sxxeyy "$SXXEYY" --arg img "$IMG_LOCAL" --arg airDate "$AIR_DATE" --argjson runtime "$RUNTIME" --argjson hasFile "$HAS_FILE" '{id: $id, type: "show", showTitle: $showTitle, epTitle: $epTitle, sxxeyy: $sxxeyy, img: $img, airDate: $airDate, runtime: $runtime, hasFile: $hasFile}' >> "$TMP_SONARR"
done

# --- COMPILE ---
jq -s '.' "$TMP_RADARR" > "${TMP_RADARR}.array"
jq -s '.' "$TMP_SONARR" > "${TMP_SONARR}.array"

jq -n \
  --slurpfile r "${TMP_RADARR}.array" \
  --slurpfile s "${TMP_SONARR}.array" \
  '{movies: $r[0], shows: $s[0]}' > "${FINAL_JSON}.tmp"

mv "${FINAL_JSON}.tmp" "$FINAL_JSON"
rm -f "$TMP_RADARR" "$TMP_SONARR" "${TMP_RADARR}.array" "${TMP_SONARR}.array"
