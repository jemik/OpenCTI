import os, time, json, datetime, requests
from typing import Dict, Any, List, Optional, Tuple
from pycti import OpenCTIApiClient

# -------- env --------
OPENCTI_URL   = os.getenv("OPENCTI_URL")
OPENCTI_TOKEN = os.getenv("OPENCTI_TOKEN")

TV1_API_ROOT  = os.getenv("TV1_API_ROOT", "https://api.eu.xdr.trendmicro.com")
TV1_API_KEY   = os.getenv("TV1_API_KEY")
TV1_PATH_FEED = "/v3.0/threatintel/feeds"
TV1_PATH_FDEF = "/v3.0/threatintel/feeds/filterDefinition"

POLL_MINUTES      = int(os.getenv("POLL_MINUTES", "60"))
SLEEP_SECONDS     = int(os.getenv("SLEEP_SECONDS", "900"))
TOP_REPORT        = int(os.getenv("TOP_REPORT", "200"))
RESPONSE_FORMAT   = os.getenv("RESPONSE_FORMAT", "taxiiEnvelope")  # start with envelope (more forgiving)
USER_FILTER       = "location eq 'No specified locations' and industry eq 'No specified industries'"
DEBUG             = os.getenv("DEBUG", "0") == "1"

# -------- http --------
http = requests.Session()
http.headers.update({
    "Authorization": f"Bearer {TV1_API_KEY}",
    "Accept": "application/json",
})

def _dbg(*a): 
    if DEBUG: print(*a, flush=True)

# -------- time helpers --------
def iso_now_ms() -> str:
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.000Z")

def iso_minus_minutes_ms(m: int) -> str:
    return (datetime.datetime.utcnow() - datetime.timedelta(minutes=m)).strftime("%Y-%m-%dT%H:%M:%S.000Z")

# -------- filterDefinition → default contextual filter --------
def get_default_filter(api_root: str) -> str:
    try:
        r = http.get(api_root + TV1_PATH_FDEF, timeout=30)
        r.raise_for_status()
        data = r.json()
        loc_vals = data.get("location", []) or []
        ind_vals = data.get("industry", []) or []
        loc_default = next((v for v in loc_vals if v.lower().startswith("no specified")), "No specified locations")
        ind_default = next((v for v in ind_vals if v.lower().startswith("no specified")), "No specified industries")
        # permissive default = include “No specified …” too
        return f"(location eq '{loc_default}' or location eq '{loc_default}') and industry eq '{ind_default}'"
    except Exception as e:
        _dbg("[DEBUG] filterDefinition fetch failed:", e)
        return "(location eq 'No specified locations') and industry eq 'No specified industries'"

# -------- GET with retries/backoff --------
def get_json(url: str, headers: Dict[str, str], params: Dict[str, Any], max_retries: int = 5) -> Dict[str, Any]:
    backoff = 1
    last_err = ""
    for attempt in range(1, max_retries + 1):
        _dbg(f"[DEBUG] GET {url} params={params} headers={{...}} (attempt {attempt})")
        try:
            r = http.get(url, headers=headers, params=params, timeout=90)
            ct = r.headers.get("Content-Type", "")
            _dbg(f"[DEBUG] -> {r.status_code} CT={ct}")
            if r.status_code == 204:
                return {"value": [], "nextLink": None}
            if r.status_code in (429, 500, 502, 503, 504):
                last_err = f"{r.status_code}: transient; body={r.text[:500]}"
                time.sleep(backoff); backoff = min(backoff * 2, 16); continue
            if r.status_code == 400:
                # surface server message
                raise requests.HTTPError(f"400 BadRequest: {r.text[:800]}", response=r)
            r.raise_for_status()
            if "application/json" not in ct:
                raise RuntimeError(f"Unexpected Content-Type: {ct}")
            return r.json()
        except requests.RequestException as e:
            last_err = f"{type(e).__name__}: {e}"
            time.sleep(backoff); backoff = min(backoff * 2, 16)
    raise RuntimeError(f"Max retries exceeded: {last_err}")

# -------- page collector (follows nextLink absolute URL) --------
def collect_all(api_root: str, start_iso: str, end_iso: str, fmt: str, top: int, contextual_filter: str) -> List[Dict[str, Any]]:
    url = api_root + TV1_PATH_FEED
    params = {
        "startDateTime": start_iso,
        "endDateTime": end_iso,
        "topReport": max(1, min(int(top), 500)),
        "responseObjectFormat": fmt,
    }
    headers = {}
    # Always send contextual filter (some tenants 400 without it)
    headers["TMV1-Contextual-Filter"] = contextual_filter

    items: List[Dict[str, Any]] = []
    next_url: Optional[str] = url
    next_params: Optional[Dict[str, Any]] = params
    page = 1

    while next_url:
        payload = get_json(next_url, headers, next_params or {})
        # possible shapes: list, {"value":[...],"nextLink":...}, or a single dict/bundle
        if isinstance(payload, list):
            items.extend(payload); _dbg(f"[DEBUG] Page {page}: +{len(payload)} (total {len(items)})")
        elif isinstance(payload, dict) and isinstance(payload.get("value"), list):
            batch = payload["value"]; items.extend(batch); _dbg(f"[DEBUG] Page {page}: +{len(batch)} (total {len(items)})")
        else:
            items.append(payload); _dbg(f"[DEBUG] Page {page}: appended single object (total {len(items)})")

        next_link = payload.get("nextLink") if isinstance(payload, dict) else None
        if next_link:
            next_url = next_link
            next_params = None
            page += 1
        else:
            break

    return items

# -------- convert & import --------
def import_to_opencti(client: OpenCTIApiClient, collected: List[Dict[str, Any]]) -> Tuple[int, int]:
    bundles = 0
    objects = 0
    for entry in collected:
        # taxiiEnvelope: items -> {"content": {"type":"bundle", ...}}
        content = entry.get("content") if isinstance(entry, dict) else None
        if isinstance(content, dict) and content.get("type") == "bundle":
            client.stix2.import_bundle_from_json(content, update=True)
            bundles += 1
            objects += len(content.get("objects", []))
            continue
        # raw bundle
        if isinstance(entry, dict) and entry.get("type") == "bundle":
            client.stix2.import_bundle_from_json(entry, update=True)
            bundles += 1
            objects += len(entry.get("objects", []))
            continue
    return bundles, objects

def run_once(client: OpenCTIApiClient):
    end_iso, start_iso = iso_now_ms(), iso_minus_minutes_ms(POLL_MINUTES)
    _dbg(f"[DEBUG] Window {start_iso} -> {end_iso}")

    # contextual filter: use user’s, else build safe default from filterDefinition
    contextual = USER_FILTER or get_default_filter(TV1_API_ROOT)

    # fallback ladder: (format, topReport)
    ladders = [
        (RESPONSE_FORMAT, TOP_REPORT),
        ("taxiiEnvelope", 200),
        ("taxiiEnvelope", 100),
        ("taxiiEnvelope", 50),
        ("stixBundle", 200),
        ("stixBundle", 100),
    ]

    last_error = None
    # try current region, then global as a final fallback
    root = TV1_API_ROOT
    for fmt, top in ladders:
        try:
            _dbg(f"[DEBUG] Try api_root={root}, fmt={fmt}, top={top}")
            collected = collect_all(root, start_iso, end_iso, fmt, top, contextual)
            if not collected:
                print("[INFO] No results for current window/filter.")
                return
            b, o = import_to_opencti(client, collected)
            if b == 0 and o == 0:
                preview = json.dumps(collected[:1], indent=2)[:500]
                print("[WARN] No STIX bundles found; first item preview:\n", preview)
                return
            print(f"[OK] Imported {b} bundle(s), {o} object(s) from {len(collected)} item(s) [{fmt}, top={top}]")
            return
        except Exception as e:
            last_error = e
            _dbg(f"[DEBUG] Attempt failed: {e}")
            time.sleep(1)

    print(f"[ERROR] All attempts failed. Last error: {last_error}")

def main():
    missing = [k for k in ("OPENCTI_URL","OPENCTI_TOKEN","TV1_API_KEY") if not os.getenv(k)]
    if missing:
        raise SystemExit(f"Missing required env var(s): {', '.join(missing)}")

    client = OpenCTIApiClient(OPENCTI_URL, OPENCTI_TOKEN)

    while True:
        try:
            run_once(client)
        except Exception as e:
            print(f"[ERROR] Unhandled: {e}")
        time.sleep(SLEEP_SECONDS)

if __name__ == "__main__":
    main()