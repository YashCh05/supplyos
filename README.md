# SupplyOS

**A multi-tenant B2B supply-chain platform — part inventory/ERP system, part two-sided marketplace.**

Suppliers manage catalogs and log dispatches; vendors source stock and post open order requests; both sides share a live inventory ledger. Built as a single-page vanilla-JavaScript app with a Supabase (PostgreSQL) backend, deployed as static files.

<img width="1536" height="1024" alt="ChatGPT Image Jul 15, 2026, 08_48_25 AM" src="https://github.com/user-attachments/assets/132e21df-0a50-4c88-8dc6-2245d3f7f08f" />


---

## Highlights

- **First-to-accept order marketplace.** A vendor posts a request; it goes to every supplier; whoever accepts first is atomically assigned the order. The race is resolved *in the database* (a conditional `UPDATE ... WHERE status = 'open'`), so concurrent clicks can never double-assign.
- **Live inventory ledger.** Stock on hand is computed server-side as **Supplied − Sold − Returned**, aggregated across a vendor's suppliers.
- **Role-based portals.** Separate Supplier and Vendor experiences behind email/password auth, with roles and per-tenant IDs assigned on sign-up.
- **Demand analysis.** Ranks products by recent sell-through velocity and flags restock candidates. *(This is a deterministic, rule-based aggregation; the UI labels it "AI Demand Analysis." It is not a machine-learning model.)*
- **Dark, mobile-first UI.** A single mint-on-near-black design system shared across the hub and the app, with an icon rail + labeled secondary nav on desktop that collapses to a slide-in drawer on mobile.
- **No framework, no build step.** Just HTML, CSS, and vanilla JS served statically — every piece of state and every query is explicit.

---

## Tech stack

| Layer | Technology |
|-------|------------|
| Frontend | Vanilla HTML, CSS, JavaScript (no framework, no bundler) |
| Charts | Chart.js |
| Auth / DB / Logic | Supabase — PostgreSQL, Auth, Postgres functions (RPC), Row Level Security |
| Client SDK | `@supabase/supabase-js` (via CDN) |
| Fonts | Inter + JetBrains Mono (Google Fonts) |
| Hosting | Firebase Hosting (static, HTTPS/CDN) |

---

## Project structure

```
public/                     # Firebase Hosting root (served at /)
├─ index.html               # Hub / landing page
├─ favicon.png
├─ supplyos-glyph.png
├─ supplyos-og.png
└─ supplyos/                # served at /supplyos/
   ├─ index.html            # The SupplyOS application (single file)
   ├─ favicon.png
   ├─ supplyos-glyph.png
   ├─ supplyos-logo.png
   └─ supplyos-og.png
docs/architecture.png       # System diagram
schema.sql                  # Reference DB schema: tables, RLS, RPC functions
firebase.json               # Firebase Hosting config
```

---

## Database

Five core tables, all protected by Row Level Security:

| Table | Purpose |
|-------|---------|
| `profiles` | One row per user: role (`supplier`/`vendor`), assigned ID, business name, location |
| `product_master` | Supplier catalog — SKU, price, qty, delivery lead time, availability |
| `order_requests` | Vendor-posted requests + their accept/fulfilment state |
| `supplier_dispatches` | Every shipment logged from a supplier to a vendor |
| `vendor_returns` | Returned units with reasons |

Key Postgres functions (RPC):

- `accept_order_request(...)` — atomic first-to-accept; assigns the order and logs the dispatch in one transaction.
- `log_dispatch(...)` — records a dispatch and decrements catalog stock.
- `get_live_inventory(...)` — returns the Supplied/Sold/Returned/On-hand ledger for a vendor–supplier pair.
- `generate_supplier_id()` / `generate_vendor_id()` — allocate human-readable tenant IDs.

Full definitions (including RLS policies) are in [`schema.sql`](schema.sql).

> `schema.sql` is a **reference** reconstructed from the application's queries and RPC calls. Reconcile it with your own Supabase project before running it.

---

## Running it yourself

This is a static site with no build step. You need a Supabase project and any static file server.

1. **Create a Supabase project** at [supabase.com](https://supabase.com).
2. **Set up the database.** In the Supabase SQL editor, run [`schema.sql`](schema.sql) (review it first — see the note above).
3. **Add your keys.** In `public/supplyos/index.html`, set:
   - `SUPABASE_URL` — your project URL
   - `SUPABASE_ANON_KEY` — your project's **publishable (anon)** key
4. **Serve the files.** For example:
   ```bash
   npx serve public
   ```
   Then open the printed URL.

### Deploying to Firebase Hosting

```bash
npm install -g firebase-tools
firebase login
firebase deploy --only hosting
```

---

## Security notes

Please read this section before making the repository public.

- **Never commit a `service_role` key.** It bypasses Row Level Security and grants full admin access to your database. If one has ever been committed, **rotate it immediately** in Supabase → Settings → API — rotation is the only real fix, since it stays in git history forever.
- **The publishable (anon) key is safe to expose** — it's designed to run in the browser. Its safety depends entirely on **Row Level Security being enabled** with correct policies (see `schema.sql`). Without RLS, an anon key is effectively public write access.
- Nothing in the browser is ever truly secret. Client-side obfuscation does not protect credentials; correct RLS policies do.

---

## Roadmap

- [ ] Replace the rule-based demand analysis with a real model call (e.g., an LLM in a Supabase Edge Function) so the "AI" label is literal.
- [ ] Real delivery tracking (current arrival dates are estimates from dispatch date + lead time).
- [ ] Notifications when an order request is claimed.
- [ ] Order history and exportable reports.

---

## License

[MIT](LICENSE) © Yash Chauhan
