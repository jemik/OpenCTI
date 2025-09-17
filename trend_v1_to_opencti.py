import os
import json
import time
import requests
from uuid import uuid4
from datetime import datetime, timedelta
from typing import Any, Dict, List, Optional, Tuple
from pycti import OpenCTIApiClient

# -------- OpenCTI env --------
OPENCTI_URL   = os.getenv("OPENCTI_URL")
OPENCTI_TOKEN = os.getenv("OPENCTI_TOKEN")

# -------- Trend Vision One env --------
URL_BASE      = os.getenv("TV1_API_ROOT", "https://api.eu.xdr.trendmicro.com").rstrip("/")
URL_PATH      = "/v3.0/threatintel/feeds"
TV1_API_KEY   = os.getenv("TV1_API_KEY")

# -------- Feed options --------
POLL_MINUTES        = int(os.getenv("POLL_MINUTES", "60"))
RESPONSE_FORMAT     = os.getenv("RESPONSE_FORMAT", "taxiiEnvelope")  # or "stixBundle"
TOP_REPORT_DEFAULT  = int(os.getenv("TOP_REPORT", "100"))            # requested per-page size
SLEEP_SECONDS       = int(os.getenv("SLEEP_SECONDS", "900"))

# Contextual filter:
# If TV1_CONTEXTUAL_FILTER is given, we use it as-is.
# Else we construct the header from TV1_LOCATION / TV1_INDUSTRY (defaults match your sample).
USER_FILTER         = ("").strip()
TV1_LOCATION        = os.getenv("TV1_LOCATION", "No specified locations")
TV1_INDUSTRY        = os.getenv("TV1_INDUSTRY", "No specified industries")

DEBUG               = os.getenv("DEBUG", "0") == "1"

# Optional: keep bundles at a sane size for OpenCTI imports.
MAX_OBJECTS_PER_BUNDLE = int(os.getenv("MAX_OBJECTS_PER_BUNDLE", "5000"))

def to_iso_z(dt: datetime) -> str:
    # match your sample with milliseconds set to .000Z
    return dt.strftime("%Y-%m-%dT%H:%M:%S.000Z")

def log(*a):
    if DEBUG: print(*a, flush=True)

def get_json(session: requests.Session, url: str, headers: dict, params=None, max_retries=5):
    backoff = 1
    for _ in range(max_retries):
        resp = session.get(url, headers=headers, params=params, timeout=60)
        ct = resp.headers.get("Content-Type", "")
        log(f"[HTTP] {resp.status_code} {url}  CT={ct}")
        if resp.status_code == 200:
            if "application/json" in ct:
                return resp.json()
            raise RuntimeError(f"Unexpected content-type: {ct}")
        if resp.status_code == 204:
            # No content is a valid response → treat like empty page
            return {"value": [], "nextLink": None}
        if resp.status_code in (429, 500, 502, 503, 504):
            time.sleep(backoff)
            backoff = min(backoff * 2, 16)
            continue
        # surface server error body for 400/401/etc.
        raise RuntimeError(f"HTTP {resp.status_code}: {resp.text[:1000]}")
    raise RuntimeError("Max retries exceeded")

def extract_items(payload):
    # Exactly like your sample
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict) and isinstance(payload.get("value"), list):
        return payload["value"]
    return None

def collect_all(session, headers, params, debug=False) -> List[Dict[str, Any]]:
    items: List[Dict[str, Any]] = []
    next_url = f"{URL_BASE}{URL_PATH}"
    next_params = params
    page = 1
    while True:
        payload = get_json(session, next_url, headers, params=next_params)
        arr = extract_items(payload)
        if arr is not None:
            items.extend(arr)
            if debug:
                print(f"Fetched page {page}: {len(arr)} items; total {len(items)}")
        else:
            if isinstance(payload, dict):
                p = dict(payload)
                p.pop("nextLink", None)
                items.append(p)
                if debug:
                    print(f"Fetched page {page}: appended full page object (no 'value' array).")
        next_link = payload.get("nextLink") if isinstance(payload, dict) else None
        if not next_link:
            break
        next_url = next_link
        next_params = None  # important: nextLink already has its own query
        page += 1
    return items

def flatten_objects_from_items(collected: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Pull STIX objects out of the common shapes we see:
      A) {"envelope":{"objects":[...]}}  <-- your tenant returns this
      B) {"content":{"type":"bundle","objects":[...]}}
      C) {"type":"bundle","objects":[...]}
      D) {"objects":[...]}  (raw)
    Returns a flat list of STIX objects.
    """
    objs: List[Dict[str, Any]] = []
    for entry in collected:
        if not isinstance(entry, dict):
            continue

        # A) TAXII envelope (exactly like your working sample)
        env = entry.get("envelope")
        if isinstance(env, dict) and isinstance(env.get("objects"), list):
            objs.extend(env["objects"])
            continue

        # B) content as bundle
        content = entry.get("content")
        if isinstance(content, dict):
            if content.get("type") == "bundle" and isinstance(content.get("objects"), list):
                objs.extend(content["objects"])
                continue
            cenv = content.get("envelope")
            if isinstance(cenv, dict) and isinstance(cenv.get("objects"), list):
                objs.extend(cenv["objects"])
                continue

        # C) direct bundle on the item
        if entry.get("type") == "bundle" and isinstance(entry.get("objects"), list):
            objs.extend(entry["objects"])
            continue

        # D) raw objects list
        if isinstance(entry.get("objects"), list):
            objs.extend(entry["objects"])
            continue

    return objs

def chunked_bundles(all_objects: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Split a flat object list into STIX bundles (≤ MAX_OBJECTS_PER_BUNDLE)."""
    bundles: List[Dict[str, Any]] = []
    if not all_objects:
        return bundles
    for i in range(0, len(all_objects), MAX_OBJECTS_PER_BUNDLE):
        chunk = all_objects[i:i+MAX_OBJECTS_PER_BUNDLE]
        if not chunk:
            continue
        bundles.append({"type": "bundle", "id": f"bundle--{uuid4()}", "objects": chunk})
    return bundles

def run_once(client: OpenCTIApiClient):
    # build time window (UTC)
    end_dt = datetime.utcnow()
    start_dt = end_dt - timedelta(minutes=POLL_MINUTES)
    start_iso = to_iso_z(start_dt)
    end_iso   = to_iso_z(end_dt)

    # build session + headers
    session = requests.Session()
    session.headers.update({"Accept": "application/json"})  # explicit
    headers = {
        "Authorization": f"Bearer {TV1_API_KEY}",
    }
    if USER_FILTER:
        headers["TMV1-Contextual-Filter"] = USER_FILTER
    else:
        # (location eq '<loc>' OR location eq 'No specified locations') AND industry eq '<industry>'
        headers["TMV1-Contextual-Filter"] = (
            f"(location eq 'No specified locations') "
            f"and industry eq '{TV1_INDUSTRY}'"
        )

    base_params = {
        "responseObjectFormat": RESPONSE_FORMAT,   # "taxiiEnvelope" (default) or "stixBundle"
        "startDateTime": start_iso,
        "endDateTime": end_iso,
    }

    # fallback sizes order (matches your sample tool)
    fallback_sizes = [TOP_REPORT_DEFAULT, 200, 100, 50, 25, 10]
    tried = set()
    last_err: Optional[Exception] = None

    # fetch + import
    for size in fallback_sizes:
        if size in tried:
            continue
        tried.add(size)
        params = dict(base_params)
        params["topReport"] = size
        label = f"topReport={size}, format={RESPONSE_FORMAT}, filter=ON, end=ON"
        try:
            log(f"Trying: {label} | params={params}")
            collected = collect_all(session, headers, params, debug=DEBUG)

            # Flatten TAXII envelopes & other shapes into STIX objects, then wrap into bundles
            all_objs = flatten_objects_from_items(collected)
            if not all_objs:
                print("[INFO] No STIX objects in TAXII envelopes for current window/filter.")
                return

            bundles = chunked_bundles(all_objs)
            total_objs = sum(len(b.get("objects", [])) for b in bundles)
            for b in bundles:
                # IMPORTANT: pycti expects a JSON string for import_bundle_from_json
                client.stix2.import_bundle_from_json(json.dumps(b), update=True)
            print(f"[OK] Imported {len(bundles)} bundle(s), {total_objs} object(s) using {label}")
            return
        except Exception as e:
            if DEBUG:
                print(f"Attempt failed ({label}): {e}")
            last_err = e
            continue

    raise last_err if last_err else RuntimeError("All attempts failed")

def main():
    if not OPENCTI_URL or not OPENCTI_TOKEN or not TV1_API_KEY:
        missing = [k for k,v in [("OPENCTI_URL",OPENCTI_URL),("OPENCTI_TOKEN",OPENCTI_TOKEN),("TV1_API_KEY",TV1_API_KEY)] if not v]
        raise SystemExit(f"Missing required env var(s): {', '.join(missing)}")

    client = OpenCTIApiClient(OPENCTI_URL, OPENCTI_TOKEN)
    while True:
        try:
            run_once(client)
        except Exception as e:
            print(f"[ERROR] {e}")
        time.sleep(SLEEP_SECONDS)

if __name__ == "__main__":
    main()