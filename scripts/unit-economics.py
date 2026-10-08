#!/usr/bin/env python3
"""Offline planning model, not billing code or an invoice/profit calculation.

Run python3 scripts/unit-economics.py [--json]. Prices/evidence/limitations:
docs/research/PRICING_RECOMMENDATION_20261008.md. No network or credentials.
"""
from dataclasses import dataclass, asdict
from decimal import Decimal, ROUND_CEILING
import argparse
import json

D = Decimal
CREDIT_USD = D("0.005")


@dataclass(frozen=True)
class Offer:
    name: str
    price: Decimal
    credits: int
    variable_infra: Decimal


OFFERS = (
    Offer("Approved Standard", D("9.99"), 800, D("0.30")),
    Offer("Approved Pro", D("19.99"), 1800, D("0.50")),
    Offer("Approved pack", D("4.99"), 400, D("0")),
    Offer("Proposed Standard", D("9.99"), 500, D("0.30")),
    Offer("Proposed Pro", D("19.99"), 1200, D("0.50")),
    Offer("Proposed pack", D("4.99"), 250, D("0")),
)


@dataclass(frozen=True)
class Scenario:
    name: str
    commission: Decimal
    included_tax: Decimal
    refund_fraction: Decimal
    credit_utilization: Decimal
    uncharged_provider_overhead: Decimal


SCENARIOS = (
    Scenario("Ordinary, enrolled / no included tax", D(".15"), D("0"), D(".02"), D(".50"), D(".10")),
    Scenario("Ordinary, enrolled / 20% included tax", D(".15"), D(".20"), D(".02"), D(".50"), D(".10")),
    Scenario("Heavy, enrolled / 20% included tax", D(".15"), D(".20"), D(".02"), D("1"), D(".10")),
    Scenario("Stress, 30% / 20% included tax", D(".30"), D(".20"), D(".03"), D("1"), D(".10")),
)


def offer_result(offer, scenario):
    # Refunds reduce proceeds, not previously incurred API costs. For packs use
    # eventual full redemption, irrespective of the subscription utilization.
    utilization = D("1") if "pack" in offer.name else scenario.credit_utilization
    proceeds = offer.price / (1 + scenario.included_tax) * (1 - scenario.commission) * (1 - scenario.refund_fraction)
    credited_spend = offer.credits * CREDIT_USD * utilization
    overhead = credited_spend * scenario.uncharged_provider_overhead
    contribution = proceeds - credited_spend - overhead - offer.variable_infra
    return {"offer": offer.name, "scenario": scenario.name, "proceeds": proceeds,
            "credited_provider_equivalent": credited_spend, "uncharged_provider_overhead": overhead,
            "variable_infra": offer.variable_infra, "contribution_before_fixed": contribution,
            "contribution_fraction_of_proceeds": contribution / proceeds}


def podcast(minutes, january=False):
    spoken_tokens = 200 * minutes
    script = (D(44000 + spoken_tokens) * 2 + D(spoken_tokens + 2000) * 10) / 1_000_000
    speech = (D(spoken_tokens + 500) * (1 if january else D(".5"))
              + D(minutes * 60 * 25) * (18 if january else 9)) / 1_000_000
    clean = script + speech
    # 25% is population-level quality/failed-generation allowance, not permission
    # to retry, and not a sufficient admission hold. Transcription is optional.
    expected = clean * D("1.25") + D(".01") + minutes * D(".003")
    return {"minutes": minutes, "tariff": "2027-01 announced" if january else "2026-10 current",
            "script": script, "speech": speech, "clean_generation": clean,
            "planning_with_quality_runtime_transcription": expected,
            "clean_equivalent_credits": int((clean / CREDIT_USD).to_integral_value(rounding=ROUND_CEILING)),
            "planning_equivalent_credits": int((expected / CREDIT_USD).to_integral_value(rounding=ROUND_CEILING))}


def bound(speech_calls=1):
    # Proposed admission envelope: two script passes, 80k conservative input
    # tokens EACH, output ceilings 6k and 4k, no server fallback or tools;
    # each speech call reserves its full documented serving limits at Jan rates.
    script_max = (D(2 * 80000) * 2 + D(6000 + 4000) * 10) / 1_000_000
    speech_max = D(speech_calls) * (D(8192) + D(16384) * 18) / 1_000_000
    return {"script_max": script_max, "speech_calls": speech_calls,
            "speech_max": speech_max, "provider_max": script_max + speech_max,
            "minimum_credit_hold": int(((script_max + speech_max) / CREDIT_USD).to_integral_value(rounding=ROUND_CEILING))}


def catalog_delivery(minutes=10, episodes=10000, downloads=100000):
    gb_each = D(minutes * 60 * 64000) / 8 / 1_000_000_000  # Decimal GB, mono 64 kbit/s.
    return {"minutes": minutes, "episodes": episodes, "downloads": downloads,
            "gb_each": gb_each, "stored_gb": gb_each * episodes,
            "delivered_gb": gb_each * downloads,
            "storage_marginal": gb_each * episodes * D(".0213"),
            "cached_egress_marginal": gb_each * downloads * D(".03"),
            "uncached_egress_marginal": gb_each * downloads * D(".09")}


def model():
    results = [offer_result(o, s) for s in SCENARIOS for o in OFFERS]
    break_even = []
    for scenario in (SCENARIOS[1], SCENARIOS[3]):
        for prefix in ("Approved", "Proposed"):
            offers = [o for o in OFFERS if o.name.startswith(prefix) and "pack" not in o.name]
            contribution = sum(offer_result(o, scenario)["contribution_before_fixed"] for o in offers) / 2
            for fixed in (D("67"), D("37")):
                break_even.append({"offers": prefix, "scenario": scenario.name, "fixed_scenario": fixed,
                                   "equal_mix_payer_contribution": contribution,
                                   "payers_covering_fixed_only": int((fixed / contribution).to_integral_value(rounding=ROUND_CEILING)) if contribution > 0 else None})
    return {"assumptions": {"credit_usd": CREDIT_USD, "offers": [asdict(o) for o in OFFERS],
                             "scenarios": [asdict(s) for s in SCENARIOS]},
            "offers": results, "break_even": break_even,
            "podcasts": [podcast(m, jan) for jan in (False, True) for m in (5, 10, 20)],
            "podcast_admission_examples": [bound(1), bound(2)], "delivery": catalog_delivery()}


def display(data):
    print("Planning only; fixed costs, support, acquisition, tax on business income and salaries excluded.")
    for scenario in SCENARIOS:
        print("\n" + scenario.name)
        print("| Offer | Proceeds | Provider equiv. | Extra provider | Variable infra | Contribution |")
        print("|---|---:|---:|---:|---:|---:|")
        for r in data["offers"]:
            if r["scenario"] == scenario.name:
                print(f'| {r["offer"]} | ${r["proceeds"]:.2f} | ${r["credited_provider_equivalent"]:.2f} | ${r["uncharged_provider_overhead"]:.2f} | ${r["variable_infra"]:.2f} | ${r["contribution_before_fixed"]:.2f} |')
    print("\nPodcast estimates (script + review + speech; planning includes additional allowances):")
    for r in data["podcasts"]:
        print(f'{r["tariff"]}: {r["minutes"]} min, clean ${r["clean_generation"]:.4f}, planning ${r["planning_with_quality_runtime_transcription"]:.4f}')
    print("\nAdmission bounds:", data["podcast_admission_examples"])
    print("\nFixed-cost coverage (50/50 subscriber mix):")
    for r in data["break_even"]:
        print(f'{r["offers"]}; {r["scenario"]}; ${r["fixed_scenario"]} fixed -> {r["payers_covering_fixed_only"]} payers')
    print("\nAudio storage/egress:", data["delivery"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="Emit exact decimal strings for reuse.")
    args = parser.parse_args()
    data = model()
    if args.json:
        print(json.dumps(data, default=str, indent=2))
    else:
        display(data)
