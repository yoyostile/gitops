#!/usr/bin/env python3
"""Regenerate the Lyceum pricing overrides in config.json.

Bifrost's built-in pricing datasheet has no entry for a *custom* provider, so
every Lyceum call is logged with cost 0. Rather than point
`framework.pricing.pricing_url` at our own datasheet — which replaces the whole
catalogue and would drop the maintained Anthropic/OpenAI prices — we add
`governance.pricing_overrides` scoped to `provider: lyceum`. Those are additive.

Prices come from Lyceum's own API, so this needs re-running when they change:

    LYCEUM_API_KEY=$(kubectl -n default get secret bifrost-secrets \
        -o jsonpath='{.data.LYCEUM_API_KEY}' | base64 -d) \
      python3 cluster/apps/default/bifrost/app/gen-lyceum-pricing.py

It rewrites config.json in place, replacing only override ids prefixed
`lyceum-`. Run prettier afterwards; commit the diff like any other change.
"""

import json
import os
import pathlib
import urllib.request

PRICING_URL = "https://api.lyceum.technology/api/v2/external/pricing"
CONFIG = pathlib.Path(__file__).with_name("config.json")
PREFIX = "lyceum-"

# Lyceum meter slug -> Bifrost pricing_patch field.
METERS = {
    "serverless_inference_prompt_tokens": "input_cost_per_token",
    "serverless_inference_completion_tokens": "output_cost_per_token",
    "serverless_inference_cached_prompt_tokens": "cache_read_input_token_cost",
}

# Models Lyceum serves but does not price via the API. Copying a sibling's rates
# is a guess, so it is recorded here rather than hidden in the generated output —
# the alternative is Bifrost reporting these calls at cost 0, which reads as free.
# Drop an entry once the API starts pricing it (the script warns when that happens).
ESTIMATED_FROM = {
    "z-ai/glm-5.2-instant": "z-ai/glm-5.2",
}


def fetch_prices(key):
    req = urllib.request.Request(PRICING_URL, headers={"Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["prices"]


def collect(prices):
    """model wire name -> {bifrost_field: usd_per_token}"""
    out = {}
    for p in prices:
        field = METERS.get(p["meter_slug"])
        if not field:
            continue
        dep = (p.get("applies_to") or {}).get("deployment_id", "")
        if not dep.startswith("serverless:"):
            continue
        price = float(p["unit_price"])
        if price <= 0:
            continue
        out.setdefault(dep.split("serverless:", 1)[1], {})[field] = price
    return out


def main():
    key = os.environ.get("LYCEUM_API_KEY")
    if not key:
        raise SystemExit("LYCEUM_API_KEY is not set")

    models = collect(fetch_prices(key))
    if not models:
        raise SystemExit("no serverless token prices found - did the API shape change?")

    estimated = set()
    for target, source in ESTIMATED_FROM.items():
        if target in models:
            print(f"note: {target} is priced by the API now - drop it from ESTIMATED_FROM")
            continue
        if source not in models:
            print(f"warning: cannot estimate {target}, source {source} is unpriced too")
            continue
        models[target] = dict(models[source])
        estimated.add(target)

    cfg = json.loads(CONFIG.read_text())
    gov = cfg.setdefault("governance", {})
    kept = [o for o in gov.get("pricing_overrides", []) if not o["id"].startswith(PREFIX)]

    new = []
    # Lyceum ships case-variant duplicates of the same model (both
    # moonshotai/kimi-k2.6 and moonshotai/Kimi-K2.6 exist). Case must therefore be
    # preserved in the id, and even then we dedupe defensively: Bifrost refuses to
    # start at all on a duplicate override id ("a record with this id already
    # exists"), so a collision here is a hard outage, not a cosmetic problem.
    seen = set()
    for model, patch in sorted(models.items()):
        # An embedding model has no completion price; bill it as an embedding.
        rt = ["embedding"] if "embedding" in model.lower() else ["chat_completion"]
        label = f"Lyceum {model}"
        if model in estimated:
            label += f" (ESTIMATE, rates copied from {ESTIMATED_FROM[model]})"
        ident = f"{PREFIX}{model.replace('/', '-')}"
        if ident.lower() in seen:
            n = 2
            while f"{ident}-{n}".lower() in seen:
                n += 1
            ident = f"{ident}-{n}"
        seen.add(ident.lower())
        new.append({
            "id": ident,
            "name": label,
            "scope_kind": "provider",
            "provider_id": "lyceum",
            "match_type": "exact",
            # Matched against the wire model, i.e. without the "lyceum/" prefix.
            "pattern": model,
            "request_types": rt,
            "pricing_patch": json.dumps(patch, separators=(",", ":")),
        })

    gov["pricing_overrides"] = kept + new
    CONFIG.write_text(json.dumps(cfg, indent=2) + "\n")
    print(f"wrote {len(new)} lyceum overrides ({len(kept)} non-lyceum kept) to {CONFIG.name}")


if __name__ == "__main__":
    main()
