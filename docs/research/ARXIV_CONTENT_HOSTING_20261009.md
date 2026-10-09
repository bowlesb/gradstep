# arXiv content hosting and commercial sync review

Reviewed 2026-10-09 for the paid Timestep/Science Reader launch. This is a product and engineering review,
not a legal opinion. The launch decision should be confirmed by counsel familiar with copyright licensing and
the jurisdictions in which the service will operate.

## Conclusion

The current server-side design is **not cleared for launch for most arXiv papers**. arXiv's API Terms of Use
say that a client must not store and serve e-prints (including PDFs, source files, or other content) from its
own servers unless the copyright holder has given permission or the e-print's license permits it. arXiv also
says it is not the copyright holder for the e-prints. The default arXiv license gives arXiv a perpetual,
non-exclusive right to distribute; it does not give other services a redistribution license.

The current `owner_private` path—download on our worker, retain an original and converted reader bundle on
Supabase, and serve it to one account—still stores and serves the e-print from our servers. Account isolation,
encryption, a paid subscription, and the fact that the copy is not shared with another customer are valuable
security and privacy controls, but they do not themselves create a copyright license.

## What the sources say

- arXiv says every article can be viewed and downloaded freely, but the submitter chooses the license and retains
  copyright in all licenses except CC0. It also warns that different versions can have different licenses and that
  the chosen license is irrevocable: [arXiv license information](https://info.arxiv.org/help/license/index.html).
- The default arXiv license says only: the submitter grants **arXiv** a perpetual, non-exclusive license to
  distribute the article. It does not grant that right to Timestep: [default arXiv license](https://arxiv.org/licenses/nonexclusive-distrib/1.0/license.html).
- arXiv's API terms expressly distinguish metadata from full text. Metadata may be stored and used under CC0;
  e-print content may be used for personal or research purposes, but the API terms say not to store and serve
  e-prints from our servers without copyright-holder or license permission: [API Terms of Use](https://info.arxiv.org/help/api/tou.html).
- arXiv's reuse FAQ says the overwhelming majority of e-prints use the default license and that, in those cases,
  a service seeking to repost the full text should contact the author or copyright holder: [Reuse Requests](https://info.arxiv.org/help/license/reuse.html).
- arXiv describes paid products as commercial projects, asks them to review the API documentation and consider
  becoming an affiliate, and requires all API users to acknowledge its interoperability and avoid implying
  endorsement: [commercial API projects and acknowledgements](https://info.arxiv.org/help/api/index.html).

## Product behavior by rights status

| Source/license | Server copy and cross-device sync | Mathpix/HTML conversion | Shared cache or podcast |
|---|---|---|---|
| CC0 | Generally permitted; preserve provenance | Generally permitted | Generally permitted, subject to attribution/provenance and other rights |
| CC BY 4.0 | Permitted with attribution, license link, source link, and change notice | Permitted commercially; the transformed reader is an adaptation/modified format and must be marked | Permitted with the same attribution and no implication of endorsement |
| CC BY-SA 4.0 | Permitted with attribution; adapted outputs must carry compatible ShareAlike terms | Possible, but the resulting reader/audio and distribution terms need a deliberate ShareAlike implementation | Possible only if recipients receive the required license freedoms |
| CC BY-NC / BY-NC-SA / BY-NC-ND | Do not use for a paid product without specific permission; NC restricts commercial purpose | NC blocks the paid-service use; ND also blocks adaptations | Do not share or generate paid derived media without permission |
| Default/assumed arXiv license or missing/uncertain license | Do not retain or serve from our servers by default | Do not send to server-side Mathpix or retain a server-derived reader by default | Do not share, podcast, or reuse across accounts |
| Explicit author/publisher permission | Follow the written scope exactly, including version, format, territory, duration, attribution, and takedown terms | Only if the permission covers transformation and the service's commercial use | Only if the permission covers redistribution to other users |

CC BY's official terms allow commercial sharing and adaptation subject to attribution; CC BY-SA adds the
ShareAlike obligation. The Creative Commons license does not remove separate privacy, moral-rights, third-party
material, or publisher-rights issues: [CC BY 4.0 deed](https://creativecommons.org/licenses/by/4.0/deed.en).

## Implications for our planned flows

1. **Metadata, search, and Feed:** The low-risk path. Store identifiers, title, authors, abstract, categories,
   dates, license URI, and links. Keep the arXiv abstract page as the canonical source.
2. **Direct reading from arXiv:** The safest fallback for a non-permissive paper. Link to arXiv and let the device
   retrieve it directly, subject to arXiv's rate limits and the user's device/network. This does not provide our
   promised server-backed cross-device reader copy.
3. **Server-backed private library:** Not safe to promise for default-license papers without rights clearance.
   “Private” is an access-control property, not a copyright exception.
4. **Mathpix:** Server-side OCR/rendering creates another copy and likely a transformed/derivative output. It is
   safe only when the source license or written permission covers that use, or after counsel confirms a separate
   exception. The current policy must not treat an unverified/default license as sufficient merely because the
   rendered bundle is private.
5. **Shared paper conversions:** Restrict to rights-verified licenses whose conditions we can satisfy. Our current
   shared implementation recognizes CC BY 4.0 and CC0; it should remain closed for every other license until its
   terms and attribution/share-alike behavior are implemented and reviewed.
6. **Podcasts and generated diagrams:** Treat these as derived uses of the paper. Do not generate or share them
   from a default-license paper through the paid server pipeline without permission. A podcast's script, audio,
   quotations, and source attribution need their own rights review.
7. **Withdrawals and takedowns:** Pin the exact arXiv version and license evidence, detect withdrawals/replacements,
   preserve a takedown path, and remove or disable server copies when the rights basis ends. arXiv's submission
   agreement permits arXiv to remove or block access to submissions.

## Operational and launch obligations

- The API terms limit legacy API/OAI/RSS usage to one request every three seconds across all machines under our
  control and prohibit attempts to evade the limit. Our worker's global pacing must remain enabled.
- Put the required arXiv acknowledgement in the About/legal surface, link every hosted paper back to its arXiv
  abstract page, retain author/license/source attribution, and avoid arXiv logos or language implying endorsement.
- If we host user-supplied or otherwise user-directed files, obtain counsel's view on the applicable safe harbor,
  publish a copyright/takedown policy, designate a DMCA agent where appropriate, and implement fast account/object
  takedown. U.S. DMCA §512(c) is a liability limitation with conditions, not a license to copy: [U.S. Copyright
  Office §512 guidance](https://www.copyright.gov/title17/92chap5.html).
- Do not rely on a U.S. fair-use or EU text-and-data-mining theory as the product's blanket authorization for
  server sync. Those exceptions are fact- and jurisdiction-dependent and do not answer the API contract's direct
  storage/serving restriction.

## Recommendation and contact plan

**Yes, contact arXiv before launch.** Contacting arXiv is necessary for the commercial/API relationship, but an
arXiv response alone may not grant rights in default-license papers because arXiv says it is not their copyright
holder. Ask arXiv User Support and the commercial/affiliate contact for a written response to these exact questions:

1. May a paid app fetch an arXiv e-print after a user requests it, retain an encrypted per-account copy on its
   servers, and serve that copy to the same user's approved devices?
2. May the app send that copy to a contracted OCR provider and retain a private equation-aware HTML/MathML reader?
3. Is a license-filtered shared cache limited to CC BY/CC0 acceptable, with attribution and links, and what terms
   would arXiv expect for CC BY-SA or other licenses?
4. What request pacing, caching, version/withdrawal behavior, acknowledgement text, and commercial-affiliate steps
   should a paid product follow?
5. Does arXiv have a preferred partnership, affiliate, or arXivLabs route for this kind of reader?

In parallel, have counsel review author/publisher permissions and the non-arXiv PDF path. Until that review or
written clearance is complete, the launch-safe product policy is:

- server-store and cross-device sync only for CC0/CC BY (and later, explicitly implemented compatible licenses);
- direct arXiv links/device retrieval for default or uncertain licenses;
- no server-side Mathpix, shared conversion, or podcast for those papers; and
- do not advertise “every arXiv paper syncs across devices” as a launch promise.

This is a substantive product constraint, not a wording change. It should be resolved before public paid launch.
