```
Internet
  └── Traefik (proxy ns)
        ├── matrix.julien-ivs.com  ─── /_matrix/client/v3/login|logout|refresh ──► MAS
        │                    └── everything else ──────────────────────────► Synapse
        ├── auth.julien-ivs.com    ──────────────────────────────────────────────► MAS
        ├── julien-ivs.com/.well-known/ ────────────────────────────────────────► nginx (wk ns)
        └── dashboard.julien-ivs.com ──────────────────────────────────────────► Traefik dashboard
```
