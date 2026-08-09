# ADR-0018: The dev cluster serves https only, and the probes are excluded from the redirect

- **Status:** Accepted
- **Date:** 2026-08-09
- **Design reference:** DESIGN.md §14.5 (cert-manager, TLS), §13.4 (admin session), §12 step 9

## Context

§14.5 requires TLS before the step 9 dashboard, and names two failure modes that are silent
on plain http: ActionCable refuses the websocket upgrade, and the admin session cookie is
dropped by the browser.

The second was live on the kind cluster. Signing in through the ingress returned:

```
HTTP/1.1 200 OK
set-cookie: _boba_gals_admin=<redacted>; path=/; secure; httponly; samesite=strict
```

`curl` keeps that cookie. No browser does — it is marked `Secure` and the origin was
`http://localhost:8080`. So admin sign-in passed in CI and could not work in a browser, and
nothing reported it. The dashboard (§10.6) is the first browser surface behind that cookie,
which is why §14.5 puts TLS ahead of it rather than in step 10's hardening.

How TLS arrives is specified. Three things it implies are not, and each had a plausible
alternative that would have looked fine.

## Decision

### 1. The dev cluster publishes 443 only. Port 80 is not mapped at all.

kind published `80 → 8080`. The obvious move is to keep it and redirect, but the ports do
not line up on a laptop: a redirect preserves the host header, so `http://…:8080` would
redirect to `https://…:8080`, a port nothing listens on. Making that work needs a
port-rewriting redirect that exists in no real deploy, and testing it would test the
workaround.

Not publishing 80 means the dev cluster has no plain-http surface to get wrong. Hitting it
is a refused connection — unmistakable, and unmistakable is the entire point, given that
what went wrong was something that appeared to work.

Rejected: publish 80 and rely on `ssl-redirect`. It leaves a port that serves a redirect on
a laptop and would serve the app if the TLS block were ever removed, which is the silent
failure again with an extra step.

### 2. `assume_ssl` is off, and `force_ssl` redirects — but never on `/up` or `/readyz`.

`config.assume_ssl = true` tells Rails every request is secure whether or not it was. That
is what let a `Secure` cookie be issued over http in the first place: Rails had no way to
know, so it never redirected and never complained. Reading `X-Forwarded-Proto` from the
ingress instead makes an unterminated request redirect rather than be served.

That change reaches the probes, and this is the part worth stating plainly. The kubelet
reaches the pod directly on `:3000` with no `X-Forwarded-Proto`, so both probes would be
redirected — **and a redirect is a passing probe**, because the kubelet counts any 2xx or
3xx as success. `/readyz` would answer 301 while Postgres was down, report healthy, and
quietly undo ADR-0008. The failure would show up as pods serving traffic with no database,
which is the exact symptom ADR-0008 was written about.

So `ssl_options` excludes exactly `/up` and `/readyz`, and CI asserts the status code
rather than success — a redirect and a healthy probe are indistinguishable to `curl -f`.

Rejected: leave `assume_ssl = true` and let ingress-nginx do all the redirecting. It works
today and depends entirely on an annotation default; the guarantee should not evaporate
when someone edits the Ingress.

### 3. A self-signed **CA**, not a self-signed leaf, and it lives in the dev overlay.

cert-manager can sign a certificate directly from a `selfSigned` issuer. Then every reissue
is a new untrusted certificate and the browser warning comes back. The three-object
bootstrap — self-signed issuer, CA certificate, CA issuer — gives one certificate to trust
once, after which everything the cluster issues is trusted. `bin/k8s-up` writes it to
`tmp/boba-ca.crt` and prints how to trust it.

The chain sits in `k8s/overlays/dev/`, not in `base`. The Ingress refers to an issuer by
name and to a certificate by Secret; neither reference cares what kind of issuer filled it
in, so a real deploy replaces `tls.yaml` with an ACME `ClusterIssuer` and touches nothing
else.

The host is `boba.localtest.me`, a public DNS name resolving to 127.0.0.1. No `/etc/hosts`
entry, and — the reason it matters — a real origin. Both behaviours being fixed here key off
the origin, and an origin that exists only on one laptop proves less.

## Consequences

**`bin/k8s-up` now needs the cluster recreated, not just redeployed.** Port mappings are
fixed at `kind create cluster`. Anyone with an existing cluster runs `bin/k8s-down` first;
the script cannot detect this, and the symptom is a connection refused on 8443.

**Browsers warn until the CA is trusted.** One command, printed at the end of every
bring-up. The alternative — clicking through a warning each time — trains the habit TLS is
here to remove.

**CI validates against the real CA** via `CURL_CA_BUNDLE`, with no `-k` anywhere. `-k`
would pass against the fake certificate ingress-nginx serves when issuance fails, which is
the one thing those steps exist to catch.

**ActionCable's allowed origin is still named explicitly**, even though the strict default
is now satisfiable. The default compares the `Origin` header against a scheme Rails infers
behind a terminating proxy; explicit fails closed on a hostname change, the default fails
silently on a proxy-header change, and the cost of being wrong is a websocket that never
connects with nothing in the UI to say so.

**This does not contradict DESIGN.md.** §14.5 asked for cert-manager and real TLS before
step 9; this is that, plus the three choices it left open.
