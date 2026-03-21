#!/bin/bash

# ==============================================================================
# PLEX OFFLINE BACKEND - JSON GENERATOR (Glacier UI)
# Version: 5.8
# Description: Extracts library data, handles OMDB ratings fallback, downloads
# posters, and compiles a zero-latency JSON file for the Home Assistant dashboard.
# ==============================================================================

# --- CONFIGURATION (REPLACE WITH YOUR DATA) ---
PLEX_IP="<YOUR_PLEX_IP>"               # e.g., 192.168.1.50
PLEX_PORT="32400"                      # Default is 32400
PLEX_TOKEN="<YOUR_PLEX_TOKEN>"         # Your Plex authentication token
MOVIE_SECTION="<YOUR_MOVIE_LIBRARY_ID>" # e.g., 1
TV_SECTION="<YOUR_TV_LIBRARY_ID>"       # e.g., 2
OMDB_API_KEY="<YOUR_OMDB_API_KEY>"     # Get one at omdbapi.com

# --- INTERNAL TIMESTAMPS ---
TS=$(date +%s)
THIRTY_DAYS_AGO=$((TS - 2592000))
FOURTEEN_DAYS_AGO=$((TS - 1209600))

# --- PING GUARD (OFFLINE PROTECTION) ---
# Check if Plex is reachable before doing anything. If not, safely abort.
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "http://$PLEX_IP:$PLEX_PORT/?X-Plex-Token=$PLEX_TOKEN")
if [ "$HTTP_STATUS" != "200" ]; then
    echo "Plex is offline or unreachable (HTTP $HTTP_STATUS). Aborting to protect existing JSON cache."
    exit 1
fi

# --- DIRECTORY & TEMP FILE PREPARATION ---
# Create required folders in Home Assistant's local www directory
mkdir -p /config/www/posters/movies
mkdir -p /config/www/posters/shows
mkdir -p /config/www/posters/collections

# Ratings cache to prevent hammering the OMDB API
CACHE_FILE="/config/www/posters/ratings_cache_v2.txt"
touch "$CACHE_FILE"

# Temp files for processing
TMP_MOVIES="/tmp/plex_movies.jsonl"
TMP_SHOWS="/tmp/plex_shows.jsonl"
TMP_COLS_RAW="/tmp/plex_cols_raw.jsonl"
TMP_COLS="/tmp/plex_cols.json"
FINAL_JSON="/config/www/plex_data.json"

rm -f "$TMP_MOVIES" "$TMP_SHOWS" "$TMP_COLS_RAW" "$TMP_COLS"
touch "$TMP_MOVIES" "$TMP_SHOWS" "$TMP_COLS_RAW"

# Fetch Machine ID (needed for direct links to Plex Web)
MACHINE_ID=$(curl -s -H "Accept: application/json" "http://$PLEX_IP:$PLEX_PORT/?X-Plex-Token=$PLEX_TOKEN" | jq -r '.MediaContainer.machineIdentifier // ""')

# ==============================================================================
# PHASE 1: EXTRACT COLLECTIONS
# ==============================================================================
extract_collections() {
    local section=$1
    curl -s -H "Accept: application/json" "http://$PLEX_IP:$PLEX_PORT/library/sections/$section/collections?X-Plex-Token=$PLEX_TOKEN" | jq -c '.MediaContainer.Metadata[]? | {title: .title, thumb: .thumb, key: .ratingKey}' | while read -r col; do
        C_TITLE=$(echo "$col" | jq -r '.title')
        C_THUMB=$(echo "$col" | jq -r '.thumb // ""')
        C_KEY=$(echo "$col" | jq -r '.key')
        
        # Download Collection Poster if it exists
        if [ -n "$C_THUMB" ] && [ "$C_THUMB" != "null" ]; then
            C_PATH="/config/www/posters/collections/${C_KEY}.jpg"
            if [ ! -f "$C_PATH" ]; then 
                curl -s "http://$PLEX_IP:$PLEX_PORT${C_THUMB}?X-Plex-Token=$PLEX_TOKEN" -o "$C_PATH"
            fi
            # Add to temporary JSON mapping
            jq -n --arg k "$C_TITLE" --arg v "/local/posters/collections/${C_KEY}.jpg" '{($k): $v}' >> "$TMP_COLS_RAW"
        fi
    done
}

extract_collections "$MOVIE_SECTION"
extract_collections "$TV_SECTION"
jq -s 'add // {}' "$TMP_COLS_RAW" > "$TMP_COLS"

# ==============================================================================
# PHASE 2: PROCESSING ENGINE (MOVIES & SHOWS)
# ==============================================================================
process_item() {
    local item=$1
    local type=$2
    
    # Extract Base Metadata
    ID=$(echo "$item" | jq -r '.ratingKey')
    TITLE=$(echo "$item" | jq -r '.title // ""')
    THUMB=$(echo "$item" | jq -r '.thumb // ""')
    SUMMARY=$(echo "$item" | jq -r '.summary // ""')
    GENRES=$(echo "$item" | jq -r 'if .Genre then [.Genre[].tag] | join(",") else "" end')
    COLLECTIONS=$(echo "$item" | jq -r 'if .Collection then [.Collection[].tag] | join(",") else "" end')
    
    VIEW_COUNT=$(echo "$item" | jq -r '.viewCount // 0')
    ADDED_AT=$(echo "$item" | jq -r '.addedAt // 0')
    LAST_VIEWED_AT=$(echo "$item" | jq -r '.lastViewedAt // 0')
    UPDATED_AT=$(echo "$item" | jq -r '.updatedAt // 0')
    
    if [ "$LAST_VIEWED_AT" == "null" ]; then LAST_VIEWED_AT=0; fi

    # Extract Type-Specific Data (Runtime, Unwatched Status, Release Date)
    if [ "$type" == "movie" ]; then
        DURATION=$(echo "$item" | jq -r '.duration // 0')
        RELEASE_DATE=$(echo "$item" | jq -r '.originallyAvailableAt // ""')
        
        if [ "$DURATION" -gt 0 ]; then RUNTIME=$((DURATION / 60000)); else RUNTIME=0; fi
        IS_UNWATCHED=0; if [ "$VIEW_COUNT" == "0" ] || [ "$VIEW_COUNT" == "null" ]; then IS_UNWATCHED=1; fi
    else
        TOTAL=$(echo "$item" | jq -r '.leafCount // 0')
        WATCHED=$(echo "$item" | jq -r '.viewedLeafCount // 0')
        UNWATCHED=$((TOTAL - WATCHED))
        RUNTIME=0
        
        IS_UNWATCHED=0; if [ "$UNWATCHED" -gt 0 ]; then IS_UNWATCHED=1; fi
        
        # Determine newest episode release date for sorting
        LATEST_EP_JSON=$(curl -s -H "Accept: application/json" "http://$PLEX_IP:$PLEX_PORT/library/metadata/${ID}/allLeaves?X-Plex-Token=$PLEX_TOKEN" | jq -c '.MediaContainer.Metadata // [] | map(select(.originallyAvailableAt != null)) | sort_by(.originallyAvailableAt) | last // empty')
        if [ -n "$LATEST_EP_JSON" ]; then
            RELEASE_DATE=$(echo "$LATEST_EP_JSON" | jq -r '.originallyAvailableAt // ""')
            VIEW_COUNT=$(echo "$LATEST_EP_JSON" | jq -r '.viewCount // 0')
        else
            RELEASE_DATE=$(echo "$item" | jq -r '.originallyAvailableAt // ""')
        fi
    fi

    if [ -n "$RELEASE_DATE" ]; then RELEASE_TS=$(date -d "$RELEASE_DATE" +%s 2>/dev/null || echo 0); else RELEASE_TS=0; fi

    # --- RATINGS ENGINE & CACHE ---
    CACHE_ENTRY=$(grep "^$ID|" "$CACHE_FILE" 2>/dev/null || echo "")
    CACHED_RATING=$(echo "$CACHE_ENTRY" | cut -d'|' -f2)
    CACHED_TS=$(echo "$CACHE_ENTRY" | cut -d'|' -f3)
    CACHED_SOURCE=$(echo "$CACHE_ENTRY" | cut -d'|' -f4)

    NEEDS_UPDATE=0
    if [ -z "$CACHED_RATING" ] || [ "$CACHED_RATING" == "N/A" ]; then NEEDS_UPDATE=1;
    elif [ "$RELEASE_TS" -gt "$THIRTY_DAYS_AGO" ]; then
        if [ "$CACHED_TS" -lt "$((TS - 86400))" ]; then NEEDS_UPDATE=1; fi
    fi

    if [ "$NEEDS_UPDATE" == "1" ]; then
        RATING="N/A"
        RATING_SOURCE="generic"
        ITEM_META=$(curl -s -H "Accept: application/json" "http://$PLEX_IP:$PLEX_PORT/library/metadata/$ID?X-Plex-Token=$PLEX_TOKEN" | jq -c '.MediaContainer.Metadata[0] // empty')
        
        if [ -n "$ITEM_META" ]; then
            # 1. Try to get native IMDB rating from Plex
            IMDB_R=$(echo "$ITEM_META" | jq -r '.Rating[]? | select(.image and (.image | contains("imdb"))) | .value' 2>/dev/null | head -n 1)
            if [ -n "$IMDB_R" ] && [ "$IMDB_R" != "null" ]; then
                RATING="$IMDB_R"; RATING_SOURCE="imdb"
            else
                # 2. Extract IMDB ID and query OMDB API
                IMDB_ID=$(echo "$ITEM_META" | jq -r '.Guid[]? | select(.id | startswith("imdb://")) | .id' | sed 's/imdb:\/\///' | head -n 1)
                NEW_RATING="N/A"
                if [ -n "$IMDB_ID" ] && [ -n "$OMDB_API_KEY" ]; then 
                    NEW_RATING=$(curl -s "http://www.omdbapi.com/?i=$IMDB_ID&apikey=$OMDB_API_KEY" | jq -r '.imdbRating // "N/A"')
                elif [ -n "$OMDB_API_KEY" ]; then
                    # Fallback to OMDB Title Search
                    YEAR=$(echo "$ITEM_META" | jq -r '.year // ""')
                    ENCODED_TITLE=$(echo -n "$TITLE" | jq -sRr @uri)
                    NEW_RATING=$(curl -s "http://www.omdbapi.com/?t=$ENCODED_TITLE&y=$YEAR&apikey=$OMDB_API_KEY" | jq -r '.imdbRating // "N/A"')
                fi
                
                if [ "$NEW_RATING" != "N/A" ] && [ "$NEW_RATING" != "null" ]; then
                    RATING="$NEW_RATING"; RATING_SOURCE="imdb"
                else
                    # 3. Fallback to Plex Audience/Critic Ratings
                    PLEX_AUD_RATING=$(echo "$ITEM_META" | jq -r '.audienceRating // "null"')
                    if [ "$PLEX_AUD_RATING" != "null" ]; then
                        RATING="$PLEX_AUD_RATING"; PLEX_AUD_IMAGE=$(echo "$ITEM_META" | jq -r '.audienceRatingImage // ""')
                        if [[ "$PLEX_AUD_IMAGE" == *"rottentomatoes"* ]]; then RATING_SOURCE="rt"; elif [[ "$PLEX_AUD_IMAGE" == *"themoviedb"* ]]; then RATING_SOURCE="tmdb"; elif [[ "$PLEX_AUD_IMAGE" == *"imdb"* ]]; then RATING_SOURCE="imdb"; fi
                    else
                        PLEX_CRIT_RATING=$(echo "$ITEM_META" | jq -r '.rating // "null"')
                        if [ "$PLEX_CRIT_RATING" != "null" ]; then
                            RATING="$PLEX_CRIT_RATING"; PLEX_CRIT_IMAGE=$(echo "$ITEM_META" | jq -r '.ratingImage // ""')
                            if [[ "$PLEX_CRIT_IMAGE" == *"rottentomatoes"* ]]; then RATING_SOURCE="rt"; elif [[ "$PLEX_CRIT_IMAGE" == *"themoviedb"* ]]; then RATING_SOURCE="tmdb"; elif [[ "$PLEX_CRIT_IMAGE" == *"imdb"* ]]; then RATING_SOURCE="imdb"; fi
                        fi
                    fi
                fi
            fi
        fi
        # Update Cache File
        grep -v "^$ID|" "$CACHE_FILE" > "${CACHE_FILE}.tmp" 2>/dev/null || touch "${CACHE_FILE}.tmp"
        echo "$ID|$RATING|$TS|$RATING_SOURCE" >> "${CACHE_FILE}.tmp"
        mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
    else
        RATING="$CACHED_RATING"; RATING_SOURCE="$CACHED_SOURCE"
    fi

    # --- BADGE LOGIC (NEW vs RECENT) ---
    IS_NEW=0; IS_RECENT_ADD=0
    if [ "$RELEASE_TS" -gt "$THIRTY_DAYS_AGO" ]; then
        if [ "$type" == "movie" ] && [ "$IS_UNWATCHED" == "1" ]; then IS_NEW=1; fi
        if [ "$type" == "show" ] && ([ "$VIEW_COUNT" == "0" ] || [ "$VIEW_COUNT" == "null" ]); then IS_NEW=1; fi
    elif [ "$ADDED_AT" -gt "$FOURTEEN_DAYS_AGO" ]; then IS_RECENT_ADD=1; fi

    # --- POSTER DOWNLOAD LOGIC ---
    IMG_URL=""
    if [ "$THUMB" != "null" ] && [ -n "$THUMB" ]; then
        POSTER_PATH="/config/www/posters/${type}s/${ID}_${UPDATED_AT}.jpg"
        if [ ! -f "$POSTER_PATH" ]; then
            # Clean up old posters for this ID if updated
            rm -f /config/www/posters/${type}s/${ID}_*.jpg 2>/dev/null
            curl -s "http://$PLEX_IP:$PLEX_PORT${THUMB}?X-Plex-Token=$PLEX_TOKEN" -o "$POSTER_PATH"
        fi
        IMG_URL="/local/posters/${type}s/${ID}_${UPDATED_AT}.jpg"
    fi

    # --- COMPILE JSON LINE ---
    jq -n \
        --arg id "$ID" \
        --arg title "$TITLE" \
        --arg img "$IMG_URL" \
        --arg summary "$SUMMARY" \
        --arg genres "$GENRES" \
        --arg cols "$COLLECTIONS" \
        --arg rating "$RATING" \
        --arg rsource "$RATING_SOURCE" \
        --arg type "$type" \
        --argjson release "$RELEASE_TS" \
        --argjson added "$ADDED_AT" \
        --argjson viewed "$LAST_VIEWED_AT" \
        --argjson runtime "$RUNTIME" \
        --argjson unwatched "$IS_UNWATCHED" \
        --argjson isnew "$IS_NEW" \
        --argjson recent "$IS_RECENT_ADD" \
        --argjson unwatchedCount "${UNWATCHED:-0}" \
        '{id: $id, type: $type, title: $title, img: $img, summary: $summary, genres: $genres, collections: $cols, rating: $rating, ratingSource: $rsource, release: $release, added: $added, lastViewed: $viewed, runtime: $runtime, unwatched: ($unwatched==1), isNew: ($isnew==1), isRecent: ($recent==1), unwatchedCount: $unwatchedCount}'
}

# Process Movies
curl -s -H "Accept: application/json" "http://$PLEX_IP:$PLEX_PORT/library/sections/$MOVIE_SECTION/all?X-Plex-Token=$PLEX_TOKEN" | jq -c '[.MediaContainer.Metadata[]?] | unique_by(.title) | .[]' | while read -r item; do
    process_item "$item" "movie" >> "$TMP_MOVIES"
done

# Process Shows
curl -s -H "Accept: application/json" "http://$PLEX_IP:$PLEX_PORT/library/sections/$TV_SECTION/all?X-Plex-Token=$PLEX_TOKEN" | jq -c '[.MediaContainer.Metadata[]?] | unique_by(.title) | .[]' | while read -r item; do
    process_item "$item" "show" >> "$TMP_SHOWS"
done

# ==============================================================================
# PHASE 3: MASTER JSON COMPILATION
# ==============================================================================
# Convert individual JSON lines into valid JSON arrays
jq -s '.' "$TMP_MOVIES" > "${TMP_MOVIES}.array"
jq -s '.' "$TMP_SHOWS" > "${TMP_SHOWS}.array"

# Merge everything into the final object
jq -n \
  --slurpfile m "${TMP_MOVIES}.array" \
  --slurpfile s "${TMP_SHOWS}.array" \
  --slurpfile c "$TMP_COLS" \
  --arg machineId "$MACHINE_ID" \
  --arg ip "$PLEX_IP" \
  --arg port "$PLEX_PORT" \
  '{machineId: $machineId, plexIp: $ip, plexPort: $port, collections: $c[0], movies: $m[0], shows: $s[0]}' > "${FINAL_JSON}.tmp"

# Safely overwrite the active file
mv "${FINAL_JSON}.tmp" "$FINAL_JSON"

# Clean up temp files
rm -f "$TMP_MOVIES" "$TMP_SHOWS" "$TMP_COLS_RAW" "$TMP_COLS" "${TMP_MOVIES}.array" "${TMP_SHOWS}.array"

echo "Plex Cache Update Complete."
