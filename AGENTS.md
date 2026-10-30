# AGENTS.md

Working notes for this repository. See `README.md` for the architecture and
Supabase setup.

## Toolchain

- Flutter **3.47.4** (stable) at `C:\flutter`, Dart 3.13.3.
- Android SDK at `%LOCALAPPDATA%\Android\Sdk` (platforms 34, 36.1; build-tools 36.1.0/37.0.0).
- JDK 17.
- `flutter` and `dart` are on the user PATH. If a shell cannot find them, prepend
  `C:\flutter\bin`.

## Commands

```bash
flutter pub get
dart run build_runner build          # required after editing lib/data/local/tables.dart
flutter analyze                      # must be clean
flutter test                         # 71 tests
flutter build apk --debug            # Android compile check
```

### Web

```bash
flutter run -d web-server --dart-define-from-file=dart_define.json
flutter build web
```

`web/sqlite3.wasm` is the sqlite3.dart release binary (sqlite3-3.6.0 tag) and
`web/drift_worker.dart.js` is compiled from `tool/drift_worker.dart` — rebuild
it after upgrading drift:

```bash
dart compile js -O2 -o web/drift_worker.dart.js tool/drift_worker.dart
```

Without COOP/COEP headers the browser is not cross-origin isolated, so drift
falls back to IndexedDB for the cache instead of OPFS-in-a-worker. That is fine
for dev and `flutter run`; if you ship the build behind your own server, send
`Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp` to get the faster worker path.

Platform-dependent code is behind conditional imports (`dart.library.io` /
`dart.library.js_interop`): the drift connection (`lib/data/local/connection/`),
`SocketException` (`lib/core/io/`), the on-disk image cache
(`lib/services/images/local_image_files*.dart`), `Image.file` thumbnails
(`lib/features/common/local_file_image*.dart`) and the vendor screen
(`lib/features/purchasing/vendor_webview_screen_*.dart`). On web the vendor
flow opens the resolved add-to-cart URL in a new browser tab and relies on the
user pressing "Mark as added" — there is no page probe, same rule applied
manually.

### Database tests

`supabase/tests/e2e_rls_and_rpc.sql` runs 51 assertions against a **real**
database — schema, RPCs, guard triggers and RLS policies, as the real
`authenticated` role, by simulating the JWT `sub` claim that `auth.uid()` reads.

```bash
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/e2e_rls_and_rpc.sql
```

It runs entirely inside one transaction that `ROLLBACK`s, so it is safe against a
live project — nothing survives. Run it after any change to `supabase/`.

Both migrations are **idempotent** (`create table if not exists`,
`create or replace function`, `drop trigger if exists`, enums wrapped in
`do $$ ... exception when duplicate_object`). Re-running them is how you apply a
fix to a database that already has the old version.

## Things that will bite you

### Database

- **Any routine that writes `components.quantity` must flip `app.internal` on
  first.** `guard_component_quantity` rejects *every* UPDATE to that column,
  including the one inside `adjust_component_quantity` and
  `proceed_with_project`. Forgetting it does not fail at migration time — it
  fails at runtime, with a misleading `quantity is read-only; call
  adjust_component_quantity() instead` raised from inside
  `adjust_component_quantity` itself. This shipped broken once and was only
  caught by executing the SQL.

  ```sql
  perform set_config('app.internal', 'on', true);
  update public.components set quantity = ... ;
  perform set_config('app.internal', 'off', true);
  ```

- **A column-level `REVOKE` does not narrow a table-level `GRANT`.** Privileges
  are additive. `revoke update (quantity) on components from authenticated` is a
  silent no-op because Supabase's default privileges already granted table-level
  UPDATE. You must `revoke update on ... ` (table-level) and then grant the
  writable columns back individually.

- **`now()` is fixed for the whole transaction.** You cannot test that
  `touch_updated_at` advanced by comparing `updated_at > created_at` inside one
  transaction — they are equal. Pin the value with the trigger disabled, then
  let a real write move it.

- **`auth.uid()` reads `request.jwt.claim.sub`.** That is how the test suite
  simulates users: `set local role authenticated` + `set_config`.

- **A user with no company cannot read any row of `companies`** — including the
  invite code they need. That is deliberate (no company enumeration).
  `join_company_by_invite` is `SECURITY DEFINER` and resolves the code
  server-side; the app has the user type it in.

### Flutter

- **drift column builders are `boolean()`, not `bool()`.** Using `bool()` makes
  `drift_dev` crash inside `ColumnParser.parse` with a confusing
  `InstanceCreationExpressionImpl is not a subtype of MethodInvocation` error
  rather than a normal analyzer error.

- **drift's generated row classes are singular and have no `Row` suffix.**
  `class CachedVendorPrices extends Table` generates `CachedVendorPrice`.

- **drift exports a class called `Component`**, which collides with the domain
  model in `lib/data/models/inventory.dart`. Any file importing both must use
  `import 'package:drift/drift.dart' hide Component;`.

- **`replaceSynced` takes the *remote* table name** (`inventories`), not the local
  drift name (`cached_inventories`). The write queue records remote names, and a
  mismatch silently discards unsynced rows on every refresh. There is a test for
  this in `test/local_cache_test.dart`.

- **`package:html`'s `querySelector` throws `UnimplementedError` on `:checked`.**
  Avoid that pseudo-class in any selector; it is a runtime crash, not a compile
  error. `test/cart_adapter_test.dart` guards the Shopify variant-picker path.

- **`num` is not a valid `QueryRow.read<T>` type** in drift. Read raw SQL
  aggregates as `int` or `double`.

- **`android/app/src/main/AndroidManifest.xml` needs `INTERNET` explicitly.**
  Flutter only puts it in the debug and profile manifests, so a release build
  loses all network access without it.

## Conventions

- Writes are local-first: update the drift cache, enqueue a `PendingOps` row, then
  attempt `SyncService.push()`. Nothing blocks on the network.
- `components.quantity` is never written directly. It moves through
  `adjust_component_quantity()` (RPC) so the `stock_transactions` audit row is
  always written in the same transaction. A DB trigger rejects direct updates.
- Scrapers and cart adapters must not throw for vendor-side failures. Return a
  `ScrapeResult` / `CartPreparation` describing the failure; "unknown" is
  represented as `null`, never as `false`.
- Cart items reach `added_to_cart` only after the vendor page confirms it. Never
  mark success on the strength of having attempted.
