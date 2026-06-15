# splunk_test — licensing notes

`splunk_test` runs the official **`splunk/splunk`** Docker image. That image is
**proprietary Splunk Enterprise software**, not open source. This file records
what we're allowed to do with it and why the script is configured the way it is.

> Not legal advice. If `splunk_test` ever feeds anything customer-facing, a
> shipped product, or published benchmarks, run it past whoever owns legal.

## What we agreed to

The image is "licensed under and subject to the **Splunk General Terms**":
<https://www.splunk.com/en_us/legal/splunk-general-terms.html>

The script passes these on every `up`, which *is* accepting those terms:

```
SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com
SPLUNK_START_ARGS=--accept-license
```

The General Terms cover this under **§1.4 Free / Trial Offerings**: provided
**AS-IS**, no warranty, no support, no SLA, and Splunk may terminate the offering
at any time without notice.

## Is local testing allowed? Yes.

Free / Trial offerings are for **evaluation and limited, non-production** use.
A disposable local container to poke at events and SPL is squarely inside that.

**Stay inside the lines — do NOT:**
- run it in production, or as part of a service we operate for customers;
- bake it into a product we ship;
- **publish performance / benchmark numbers** without Splunk's written OK
  (the General Terms restrict this);
- leave one container alive past the trial window expecting full features
  (see below).

## Which license actually runs: Trial (default) vs Free

By default the container ships **no license key**, so Splunk Enterprise boots on
the **Trial license**:

| | **Trial** (our default) | **Free** (`SPLUNK_LICENSE_URI=Free`) |
|---|---|---|
| Cost | **$0** | $0 |
| Ingest cap | 500 MB/day | 500 MB/day |
| Expiry | ~30 days, then drops to Free | never expires |
| Features | **full** (auth, alerting, dist. search, multi-user) | limited |
| **Authentication** | **yes — admin/password works** | **NO auth at all** |

**Both are free of charge.** Trial is *not* "the paid enterprise version" — it is
the no-cost, full-feature edition for 30 days. For a throwaway container we
`reset` regularly, we never reach the 30-day cliff, so **Trial is the right
default** and the script uses it.

### Why we do NOT default to Free

Splunk **Free removes all authentication** — no users, no roles, no login. The
REST API then refuses remote calls by default:

> `HTTP 401 — Remote login disabled because you are using a free license which
> does not provide authentication.`

`splunk_test` drives Splunk entirely over REST with `-u admin:<password>`
(`curl_mgmt`, HEC token, `send`, `search`). Under Free those calls **401 and the
script breaks**, unless you force `allowRemoteLogin = always` in `server.conf` —
which means anything on the host can control Splunk with zero auth. Not worth it
for a disposable box that already works on Trial.

## If you really want Free

Opt in per-run:

```sh
SPLUNK_TEST_LICENSE=Free splunk_test up
```

This sets `SPLUNK_LICENSE_URI=Free`. Note the script's auth-based REST commands
(`send`, `search`, `hec-token`) will **not** work until you also enable
`allowRemoteLogin = always` in the container's `server.conf` and restart splunkd.
Use the Web UI (`splunk_test ui`) instead, or stay on the default Trial.

## Sources

- Image page: <https://hub.docker.com/r/splunk/splunk/>
- Splunk General Terms (§1.4): <https://www.splunk.com/en_us/legal/splunk-general-terms.html>
- Free-license behavior & no-auth REST: <https://docs.splunk.com/Documentation/Splunk/latest/Admin/MoreaboutSplunkFree>
- docker-splunk license install (`SPLUNK_LICENSE_URI=Free`): <https://github.com/splunk/docker-splunk/blob/develop/docs/advanced/LICENSE_INSTALL.md>
