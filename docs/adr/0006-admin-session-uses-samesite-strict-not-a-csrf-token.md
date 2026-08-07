# ADR-0006: The admin session relies on SameSite=Strict, not a CSRF token

- **Status:** Accepted
- **Date:** 2026-08-07
- **Design reference:** DESIGN.md §13.4 (admin), §13.1 (surface map), §9.1 (API surface), §10.6 (apply to store)

## Context

§13.4 specifies a **cookie session** for the admin surface: one `admin_users` row, no
roles, no signup. Build step 4 requires it before the first deploy, because
`PATCH /admin/scheduler_config` changes live scheduler behaviour.

Cookies are sent by the browser automatically, which is what makes them convenient and
also what makes them forgeable: any page on the internet can cause a request to our
`PATCH` endpoint, and the browser will attach the session. Every other authenticated
surface in this app is immune by construction — the KDS sends an explicit bearer token
(§13.3), and nothing else is authenticated at all (§13.1). Admin is the only place this
question arises.

The app is `config.api_only = true`, so `ActionDispatch::Cookies` and the session
middleware are added back deliberately rather than inherited.

## Decision

**The session cookie is `SameSite=Strict`, `httponly`, and `secure` in production. There is
no synchroniser token.**

`SameSite=Strict` means the browser does not attach the cookie to *any* cross-site request,
including top-level navigations. A forged `PATCH` from another origin therefore arrives
with no session and is rejected by `authenticate_admin!` like any other anonymous request.
This is a browser-enforced property, not something the application has to remember to check
on each new endpoint — which is the failure mode of token schemes: the token is verified on
nine endpoints and forgotten on the tenth.

The admin dashboard is served from the same origin as the API in every environment that
matters. In production the ingress puts `/api` and the bundle behind one host (§14.2), and
in development Vite proxies `/api` so the browser only ever talks to one origin (build step
3). So `Strict` costs nothing: there is no legitimate cross-site request to break.

Two supporting decisions:

- **`reset_session` on login.** The session id rotates when privileges change, so a session
  fixated before sign-in is not the one that ends up authenticated.
- **Wrong email and wrong password return the same error.** Distinguishing them turns the
  endpoint into an oracle for "does this address have an account" — a small leak, but a
  free one to avoid on a surface with exactly one user.

Rejected alternatives:

- **`protect_from_forgery` with a synchroniser token.** The standard Rails answer, and the
  right one for a form-rendering app. Here it means adding
  `ActionController::RequestForgeryProtection` back into an API-only app, exposing a token
  endpoint, and threading the header through every client call — real complexity whose only
  benefit over `Strict` is covering browsers that do not implement `SameSite`. Every
  browser in support has for years.
- **`SameSite=Lax`** (the Rails default). Also blocks cross-site `PATCH`, since `Lax` only
  attaches cookies on top-level `GET` navigations. `Strict` is chosen anyway because the
  difference costs nothing here and `Lax`'s carve-out is a detail nobody should have to
  hold in their head while adding a `GET /admin/...` route later.
- **Bearer tokens, matching the KDS (§13.3).** Consistent, and it would sidestep CSRF
  entirely — but §13.4 says cookie session, and a token means the dashboard stores a
  credential in JavaScript-reachable storage. `httponly` is strictly better than that for a
  long-lived browser session.

## Consequences

**Any future non-browser admin client needs a different mechanism.** A CLI or a CI job
cannot hold a `SameSite` cookie meaningfully. If one is ever needed, it gets a bearer token
against the same `admin_users` row — not a relaxation of this cookie.

**The dashboard must be same-origin.** It already is, and §14.2's ingress keeps it that
way. Serving the admin UI from a different host would silently break sign-in, which is a
loud enough failure to catch immediately, but it is a constraint worth knowing before
someone reaches for a separate admin subdomain.

**Session invalidation is limited.** A `CookieStore` session cannot be revoked server-side;
changing the admin's password does not log out an existing session. With one user and no
signup, the mitigation is `reset_session` on sign-out and rotating `RAILS_MASTER_KEY` in a
genuine compromise. If admin ever grows past one user, this is the first thing that has to
change.
