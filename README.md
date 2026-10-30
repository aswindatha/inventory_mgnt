# Electronics Inventory Management

Multi-user, multi-site electronics inventory and project management. Flutter
client, Supabase (Postgres) backend, offline-first local cache.

---

## Backend decision: Supabase

The spec offered Turso (libSQL) or Supabase (Postgres). **Supabase was chosen.**

| | Supabase (chosen) | Turso (rejected) |
|---|---|---|
| Database | Postgres | SQLite / libSQL |
| Auth | Bundled (email+password, magic link, OAuth) | None — self-rolled JWT |
| Authorisation | Row Level Security enforced **in the database** | App-layer checks only |
| Object storage | Supabase Storage (component images) | None — needs a third party |
| Schema distance from v1 | Moderate (Postgres dialect) | Minimal (SQLite-compatible) |

**The deciding factor is §2's permission model.** The spec requires every write to
be scoped by `company_id` and permission-checked. With Turso that check lives in
Dart, which means every client is trusted and any future web/admin client must
reimplement it. With Supabase the rules are expressed once as RLS policies
(`supabase/migrations/0002_rls.sql`) and hold no matter which client is talking
to the database — a malicious or buggy client cannot read another company's
inventory, cannot promote itself to owner, and cannot move stock without writing
an audit row.

The cost is that the v1 SQLite DDL does not port verbatim: `AUTOINCREMENT`
becomes `uuid default gen_random_uuid()`, `TEXT` enums become real enum types,
and `DATETIME` becomes `timestamptz`. This is a one-time translation, already
done in `supabase/migrations/0001_schema.sql`.

---

## Architecture

Five layers, each replaceable without touching the others:

```
UI            lib/features/**            screens + widgets, Riverpod consumers
Domain        lib/data/repositories/**   business rules, permission checks
Local cache   lib/data/local/**          drift (SQLite) mirror for offline use
Remote        lib/data/remote/**         Supabase client wrapper
Services      lib/services/**            MPN metadata, price scraping, cart automation
```

**Offline-first.** Every read serves from the local drift cache immediately and
refreshes from Supabase in the background; every write lands in the cache first
and is queued for push. Rows carry `sync_status`
(`synced` / `pendingCreate` / `pendingUpdate` / `pendingDelete`) and `updated_at`.
Conflicts resolve last-write-wins on `updated_at`, per §1.

`sync_status` is deliberately **local-only** — the server is the source of truth
and has no meaningful notion of "pending". `updated_at` exists on both sides, and
on the server it is maintained by the `touch_updated_at` trigger rather than by
the client, so a device with a skewed clock cannot win a conflict by lying.

---

## Setup

### 1. Create the Supabase project

1. Create a project at [supabase.com](https://supabase.com) (free tier).
2. Open **SQL Editor** and run, in order:
   - `supabase/migrations/0001_schema.sql`
   - `supabase/migrations/0002_rls.sql`
3. Confirm under **Storage** that a public `component-images` bucket exists.
4. Under **Authentication → Providers**, ensure **Email** is enabled. For
   frictionless dev, turn **Confirm email** off (Authentication → Sign In /
   Providers → Email); otherwise every test account needs a real inbox.

### 2. Collect credentials

From **Project Settings → API**:

- **Project URL** — `https://<ref>.supabase.co`
- **anon public key** — safe to ship in the client. It only grants what RLS
  allows, which is the entire point of choosing Supabase.

> The **service_role key must never be placed in this app.** It bypasses RLS
> completely. It is not needed here.

### 3. Run the app

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs

flutter run \
  --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon-key>
```

Or copy `dart_define.example.json` and use `--dart-define-from-file`.

Without credentials the app still launches, but the auth screen shows a
"backend not configured" notice and no remote calls are attempted. This keeps
the app runnable for UI work and tests.

---

## Schema overview

```
companies ──┬── users (role: owner|admin|member)
            ├── inventories ── components ──┬── vendor_price_cache
            │                               ├── stock_transactions
            │                               └── cart_items (per user)
            └── projects ── project_components ──> components (source inventory)
```

Two invariants are enforced in the database rather than in Dart, because a
client-side check would be advisory only:

- **`components.quantity` is read-only to clients.** The `guard_component_quantity`
  trigger rejects any direct `UPDATE`. Stock moves only through
  `adjust_component_quantity()`, which writes a `stock_transactions` row in the
  same transaction. The audit trail cannot be bypassed.
- **`users.company_id` / `users.role` cannot be self-edited.** The
  `guard_user_self_update` trigger blocks privilege escalation; the
  `create_company` / `join_company_by_invite` / `update_member_role` RPCs flip a
  transaction-local `app.internal` flag to perform the legitimate version.

`proceed_with_project(project_id, allow_partial)` does the §3.6 deduction
atomically. It defaults to all-or-nothing: if any line is short it deducts
nothing and returns the shortfall list for the purchasing flow. Pass
`allow_partial => true` to commit what is available.

---

## Permissions

| Action | owner | admin | member |
|---|---|---|---|
| Read company data | ✓ | ✓ | ✓ |
| Create/edit components | ✓ | ✓ | ✓ |
| Create/edit projects | ✓ | ✓ | ✓ |
| Delete inventory | ✓ | ✓ | ✗ |
| Delete project | ✓ | ✓ | ✗ |
| Invite / remove members | ✓ | ✓ | ✗ |
| Change roles | ✓ | ✓ | ✗ |
| Promote to owner | ✓ | ✗ | ✗ |

Mirrored in `lib/core/permissions.dart` so the UI can hide what it cannot do —
but RLS is the authority. The UI check is for affordance, not security.

---

## Vendor scraping & cart automation

`lib/services/scraper/` implements `fetchRobuPrice` / `fetchRobocrazePrice`
against the WooCommerce search page, parsing `.woocommerce-Price-amount` and
`.stock` with the `html` package.

**Failure is a first-class outcome.** Cloudflare and friends return 403/503 to
non-browser clients regularly. That path sets `in_stock = null` and surfaces
"Price unavailable (Bot Protection)" — never a crash, and never a fabricated
price. `vendor_price_cache.in_stock` is nullable precisely so "we don't know" is
representable and distinct from "out of stock".

Cart automation (§6) is best-effort by design. Adding to a real vendor cart from
a mobile client is fragile, so:

1. Direct add-to-cart is attempted where the vendor's form supports it.
2. On failure the item is marked `failed` with a reason, and
3. a `webview_flutter` fallback opens the real product/cart page so the user can
   finish manually.

A `cart_items` row only reaches `added_to_cart` on confirmed success. Batch runs
are staggered and rate-limited, and reuse the scraper's User-Agent.

---

## Verification status

| Check | Result |
|---|---|
| `flutter analyze` | Clean — 0 issues |
| `flutter test` | 71 passing |
| `flutter build apk --debug` | Built |
| `flutter build apk --release` | Built (63.9 MB) |
| `flutter build web` | Built — sqlite3 WASM + drift worker, IndexedDB fallback |
| `INTERNET` permission in release APK | Present (`aapt2 dump permissions`) |
| `supabase/tests/e2e_rls_and_rpc.sql` | **51 assertions passing against a live database** |
| App running on a device against a live backend | Not yet run — needs the anon key |
| iOS build | **Not verified** — requires macOS/Xcode |

### What the database suite covers

Run it with:

```bash
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/e2e_rls_and_rpc.sql
```

It executes against a real project as the real `authenticated` role, simulating
the JWT `sub` claim that `auth.uid()` reads, and rolls back so nothing persists.
Coverage: the signup trigger, `create_company` / `join_company_by_invite`,
cross-tenant RLS isolation, role capabilities (member cannot delete an inventory,
owner can), privilege-escalation guards, the quantity guard, the audit trail,
`proceed_with_project` in both its all-or-nothing and partial modes, per-user
cart isolation, and `updated_at` maintenance.

### Bugs this found

Four real defects, none of which static analysis or the Dart tests could see:

1. **All stock movement was dead.** `adjust_component_quantity` and
   `proceed_with_project` write `components.quantity`, but `guard_component_quantity`
   rejects every such UPDATE — including theirs. Neither flipped the `app.internal`
   flag the guard checks, so every adjustment raised
   `quantity is read-only; call adjust_component_quantity() instead` from *inside*
   `adjust_component_quantity`. Shipping this would have made the app's core
   action unusable.
2. **A column-level `REVOKE` was a silent no-op.** `revoke update (quantity)` does
   nothing while a table-level `GRANT` exists, because privileges are additive.
3. **`package:html` throws `UnimplementedError` on `:checked`** — would have
   crashed Shopify variant resolution at runtime.
4. **`replaceSynced` compared the remote table name against the local drift name**,
   so every refresh silently discarded unsynced offline work.

## Deliberate deviations from the spec

- **`dio` only, not `dio` + `http`.** The spec listed both. Cart automation needs
  redirect control and a cookie jar, which `http` does not offer; carrying two
  HTTP clients would be redundant.
- **No `pg_trgm` index on `components`.** The spec did not ask for one; it was
  added here and then removed. The client mirrors components into SQLite and
  searches locally, so the server never runs a text search, and the extension
  would only add a setup failure mode.
- **`sync_status` is local-only.** It is present on every cached row as §1 asks,
  but there is no server column for it — the server is the source of truth and
  has no meaningful notion of a "pending" row. The write queue (`pending_ops`) is
  what actually tracks unsynced work.
- **`local_image_path` is absent from the remote schema.** It is a per-device
  path and meaningless to other clients; it lives only in the drift cache. The
  remote row carries the canonical `image_url`.
- **`users` is a profile table over `auth.users`.** Supabase owns credentials;
  `public.users` holds company membership and role, keyed on the same id.

