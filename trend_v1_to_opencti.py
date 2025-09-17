import os, time, json, datetime, requests
from typing import Dict, Any, List, Optional, Tuple
from pycti import OpenCTIApiClient

# ---- env / config ----
OPENCTI_URL   = os.getenv("OPENCTI_URL")
OPENCTI_TOKEN = os.getenv("OPENCTI_TOKEN")

TV1_API_ROOT  = os.getenv("TV1_API_ROOT", "https://api.eu.xdr.trendmicro.com")
TV1_API_KEY   = os.getenv("TV1_API_KEY")
TV1_PATH_FEED = "/v3.0/threatintel/feeds"
TV1_PATH_FDEF = "/v3.0/threatintel/feeds/filterDefinition"

POLL_MINUTES      = int(os.getenv("POLL_MINUTES", "60"))
SLEEP_SECONDS     = int(os.getenv("SLEEP_SECONDS", "900"))
TOP_REPORT        = int(os.getenv("TOP_REPORT", "200"))      # safer default; API may reject very large values
RESPONSE_FORMAT   = os.getenv("RESPONSE_FORMAT", "stixBundle")
CONTEXTUAL_FILTER = os.getenv("TV1_CONTEXTUAL_FILTER", "").strip()
DEBUG             = os.getenv("DEBUG", "0") == "1"

# ---- http session ----
http = requests.Session()
http.headers.update({
    "Authorization": f"Bearer {TV1_API_KEY}",
    "Accept": "application/json",
})

def _log(*a):
    if DEBUG:
        print(*a, flush=True)

# ---- time helpers with milliseconds ----
def iso_now_ms() -> str:
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.000Z")

def iso_minus_minutes_ms(m: int) -> str:
    return (datetime.datetime.utcnow() - datetime.timedelta(minutes=m)).strftime("%Y-%m-%dT%H:%M:%S.000Z")

# ---- low-level GET with retries/backoff ----
def get_json(url: str, headers: Optional[Dict[str, str]]=None, params: Optional[Dict[str, Any]]=None,
             max_retries: int = 5) -> Dict[str, Any]:
    backoff = 1
    last_err: Optional[str] = None
    for attempt in range(1, max_retries+1):
        try:
            _log(f"[DEBUG] GET {url} params={params} headers={(headers or {})}")
            r = http.get(url, headers=headers, params=params, timeout=90)
            ct = r.headers.get("Content-Type", "")
            _log(f"[DEBUG] -> {r.status_code} CT={ct}")
            if r.status_code == 204:
                return {"value": [], "nextLink": None}
            if r.status_code == 400 and params and params.get("responseObjectFormat") == "stixBundle":
                # Some tenants/requests prefer taxiiEnvelope; retry once with envelope
                _log("[DEBUG] 400 on stixBundle; retrying with taxiiEnvelope")
                params = {**params, "responseObjectFormat": "taxiiEnvelope"}
                r = http.get(url, headers=headers, params=params, timeout=90)
                ct = r.headers.get("Content-Type", "")
                _log(f"[DEBUG] retry -> {r.status_code} CT={ct}")
            if r.status_code in (429, 500, 502, 503, 504):
                last_err = f"{r.status_code}: transient; body={r.text[:500]}"
                time.sleep(backoff)
                backoff = min(backoff * 2, 16)
                continue
            r.raise_for_status()
            if "application/json" not in ct:
                raise RuntimeError(f"Unexpected Content-Type: {ct}")
            return r.json()
        except requests.RequestException as e:
            last_err = f"{type(e).__name__}: {e}"
            time.sleep(backoff)
            backoff = min(backoff * 2, 16)
    raise RuntimeError(f"Max retries exceeded: {last_err}")

# ---- pagination collector following nextLink ----
def collect_pages(start_iso: str, end_iso: str) -> List[Dict[str, Any]]:
    url = TV1_API_ROOT + TV1_PATH_FEED
    # Never go crazy: cap to 500; try the requested value first
    top = min(max(int(TOP_REPORT), 1), 500)

    base_params = {
        "startDateTime": start_iso,
        "endDateTime": end_iso,
        "topReport": top,
        "responseObjectFormat": RESPONSE_FORMAT,  # may be flipped to taxiiEnvelope inside get_json
    }
    hdrs = {}
    if CONTEXTUAL_FILTER:
        hdrs["TMV1-Contextual-Filter"] = CONTEXTUAL_FILTER

    items: List[Dict[str, Any]] = []
    page = 1
    next_url: Optional[str] = url
    next_params: Optional[Dict[str, Any]] = base_params

    while next_url:
        payload = get_json(next_url, headers=hdrs or None, params=next_params)
        # Two response shapes observed:
        # 1) Envelope-like: {"value": [...], "nextLink": "..."}  (or array root)
        # 2) Single object or bundle per page
        page_items: Optional[List[Dict[str, Any]]] = None

        if isinstance(payload, list):
            page_items = payload
        elif isinstance(payload, dict) and isinstance(payload.get("value"), list):
            page_items = payload["value"]

        if page_items is not None:
            items.extend(page_items)
            _log(f"[DEBUG] Page {page}: +{len(page_items)} (total {len(items)})")
        else:
            # Some responses return a single object (e.g., a bundle/envelope not wrapped in 'value')
            items.append(payload if isinstance(payload, dict) else {"content": payload})
            _log(f"[DEBUG] Page {page}: appended single object; total {len(items)}")

        next_link = payload.get("nextLink") if isinstance(payload, dict) else None
        if next_link:
            next_url = next_link
            next_params = None  # Next link is a full URL with its own query
            page += 1
        else:
            break

    return items

# ---- convert collected pages to STIX bundles and import ----
def import_collected(client: OpenCTIApiClient, collected: List[Dict[str, Any]]) -> Tuple[int, int]:
    """Returns (bundles_imported, objects_total)."""
    bundles = 0
    objects_total = 0

    # Two shapes to support:
    #  A) taxiiEnvelope: array of items each with {"content": {"type":"bundle", ...}}
    #  B) stixBundle: list with a single element being a {"type":"bundle", ...}
    for entry in collected:
        # taxiiEnvelope item
        content = entry.get("content") if isinstance(entry, dict) else None
        if isinstance(content, dict) and content.get("type") == "bundle":
            client.stix2.import_bundle_from_json(content, update=True)
            bundles += 1
            objects_total += len(content.get("objects", []))
            continue
        # direct bundle
        if isinstance(entry, dict) and entry.get("type") == "bundle":
            client.stix2.import_bundle_from_json(entry, update=True)
            bundles += 1
            objects_total += len(entry.get("objects", []))
            continue

    return bundles, objects_total

def run_once(client: OpenCTIApiClient):
    end_iso, start_iso = iso_now_ms(), iso_minus_minutes_ms(POLL_MINUTES)
    _log(f"[DEBUG] Window {start_iso} -> {end_iso}")

    try:
        collected = collect_pages(start_iso, end_iso)
    except Exception as e:
        print(f"[ERROR] Fetch failed: {e}")
        return

    if not collected:
        print("[INFO] No results for current window/filter.")
        return

    bundles, objs = import_collected(client, collected)
    if bundles == 0 and objs == 0:
        # Not recognized as bundle/envelope items
        preview = json.dumps(collected[:1], indent=2)[:800]
        print("[WARN] No STIX bundles detected in response. First item preview:\n", preview)
        return

    print(f"[OK] Imported {bundles} bundle(s), {objs} object(s) from {len(collected)} page item(s) for window {start_iso} → {end_iso}")

def main():
    # Hard-stop if required envs missing
    missing = [k for k in ("OPENCTI_URL","OPENCTI_TOKEN","TV1_API_KEY") if not os.getenv(k)]
    if missing:
        raise SystemExit(f"Missing required env var(s): {', '.join(missing)}")

    client = OpenCTIApiClient(OPENCTI_URL, OPENCTI_TOKEN)

    # Optional: discover filterDefinition for operator feedback
    try:
        r = http.get(TV1_API_ROOT + TV1_PATH_FDEF, timeout=30)
        if r.ok:
            _log("[info] filterDefinition keys:", list(r.json().keys()))
    except Exception as e:
        _log(f"[info] filterDefinition not retrieved: {e}")

    while True:
        try:
            run_once(client)
        except requests.HTTPError as e:
            body = getattr(e.response, "text", "")[:800]
            print(f"[HTTP ERROR] {e}\n{body}")
        except Exception as e:
            print(f"[ERROR] {e}")
        time.sleep(SLEEP_SECONDS)

if __name__ == "__main__":
    main()