# Cipherbox Standard Optimization and Rollout

This release improves the standard Perl/Vue application without changing the password login, server-assisted AES-GCM protocol, database row formats, or stored ciphertext. It does not add post-quantum crypto or make the server unable to decrypt.

## What is now loaded in pages

| Screen | First request and follow-up |
| --- | --- |
| Rooms | 30 joined rooms in activity order. Load more with a cursor; room, channel, and private filters run on the server. |
| Chat history | 50 messages or the configured server cap, whichever is smaller. Load older messages by ID. |
| Chat search | Decrypts and searches one page at a time in the browser. Search older messages explicitly; selecting an unloaded result opens its history page. |
| Library | Up to 30 roots, children, or items per request, subject to the server cap. Sidebar branches load when expanded. Direct links fetch only the category, its breadcrumb path, and first pages. |
| Admin reports | 30 open reports per page; the read-only room viewer uses 50-message history requests, subject to the server cap. |

The room list replaces a database-wide message aggregation with one indexed latest-message lookup per joined room. Member and unread counts are calculated only for the selected page plus at most one look-ahead row. The browser imports each room’s nonextractable AES key once per room load and reuses it. Room-list refreshes from bursts of WebSocket events are coalesced and do not fetch the list when the screen is closed. No production timing or throughput benchmark was run.

## Deploying the update

1. Back up PostgreSQL and file storage, and preserve the existing `cipherbox.conf` and its `master_key`. The ZIP omits your live configuration, credentials, database, storage, and Git history.
2. Run `carton install` as needed, then `npm ci` and `npm run build` in `frontend/`. Use the existing production DSN and follow the install steps in `README.md` for a new instance.
3. Apply `carton exec -- ./script/migrate` from the application root before swapping in the new backend and frontend. Migration `012_pagination_indexes.sql` adds four indexes; it does not rewrite app rows. Index construction can block writes on busy tables, so schedule it in a maintenance window and test on a copy first.
4. Deploy the rebuilt frontend with the new backend. Check login, rooms, older chat history, library pages, and an open admin report. If reverting, deploy the previous frontend and backend together; they can continue to use the added indexes.

If you applied older schema SQL manually and have missing `schema_migrations` entries, do not replay SQL against populated tables. First compare the actual schema with migrations `001`, `008`, `009`, `010`, and `011` on a test restore. Record only migrations that are verified as already present, then apply the remaining ones.

## API notes

- **Rooms:** `GET /api/rooms?limit=30&type=all&cursor=…` returns `rooms` and `next_cursor`. Omit the cursor on the first request; keep the same filter for subsequent pages. A room that receives new activity can move above the current cursor. Refresh the first page to see the latest order.
- **Messages:** `GET /api/rooms/:id/messages?limit=50&before=…` and the corresponding admin viewer return messages in chronological order and `next_cursor` for the next older page. Treat cursors as strings and stop when the continuation is `null`.
- **Library:** Category and item lists return `next_offset`, or `null` at the end. Category details include `path`, from the root to the current category. The original `/api/library/tree` remains available for external callers, but the Vue app no longer uses it. Offset-based lists may shift between requests when an item is added or deleted.
- **Validation:** Invalid page parameters return HTTP 400. Default and maximum sizes remain configurable. Responses on newly paginated routes are intentionally bounded, so API clients that need every row must follow the continuation.

## Verification

Use `prove -l t/pagination_upgrade.t` on the configured disposable test database. The regression test covers tied sort values, page edges, authorization and banned-room exclusion, category breadcrumbs, the report queue, and malformed paging parameters. The existing Perl suite covers login, chat, moderation, library upload/download, and more. The Vue production build and local browser checks use a separate synthetic database.
