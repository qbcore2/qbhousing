# qbhousing

Server-authoritative QBCore housing and real-estate listings for the test server.

## Commands

- `/realestate` opens the market for players and the realtor dashboard for the configured `realestate` job.
- `/home` opens the homeowner menu.

The resource uses qblib for interaction zones, notifications, text prompts, callbacks, and all menu/input UI. It uses the supplied `qbinterior` shell catalog, `qbsql` persistence, QBCore money, `qbbanking` society accounts, and `qbgarages` exports. Property data is stored as JSON so the schema can evolve without losing furniture, stash, wardrobe, or door configuration fields.

The realtor creation flow uses qblib's in-world polygon creator for MLO outside zones. MLO doorlock authoring, furniture placement, stash placement, and clothing placement are intentionally persisted through the server `update` callback but need to be connected to the server's preferred placement/doorlock UI before being exposed to players.
