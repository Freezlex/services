```
Internet
  └── Traefik (proxy ns)
        ├── matrix.k8s.test  ─── /_matrix/client/v3/login|logout|refresh ──► MAS
        │                    └── everything else ──────────────────────────► Synapse
        ├── auth.k8s.test    ──────────────────────────────────────────────► MAS
        ├── k8s.test/.well-known/ ────────────────────────────────────────► nginx (wk ns)
        └── dashboard.k8s.test ──────────────────────────────────────────► Traefik dashboard
```
