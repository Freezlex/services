```
Internet
  └── Traefik (proxy ns)
        ├── matrix.polarys.im  ─── /_matrix/client/v3/login|logout|refresh ──► MAS
        │                    └── everything else ──────────────────────────► Synapse
        ├── auth.polarys.im    ──────────────────────────────────────────────► MAS
        ├── polarys.im/.well-known/ ────────────────────────────────────────► nginx (wk ns)
        └── dashboard.polarys.im ──────────────────────────────────────────► Traefik dashboard
```
