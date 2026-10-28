```
Internet
  └── Traefik (proxy ns)
        ├── matrix.polarys.im  ─── /_matrix/client/v3/login|logout|refresh ──► MAS
        │                    └── everything else ──────────────────────────► Synapse
        ├── auth.polarys.im    ──────────────────────────────────────────────► MAS
        ├── polarys.im/.well-known/ ────────────────────────────────────────► nginx (wk ns)
        ├── dashboard.polarys.im ──────────────────────────────────────────► Traefik dashboard
        └── k8s.polarys.im ────────────────────────────────────────────────► Headlamp (headlamp ns)
```

Redeploy all at once :
`kubectl get deployments --all-namespaces | tail +2 | awk '{ cmd=sprintf("kubectl rollout restart deployment -n %s %s", $1, $2) ; system(cmd) }'`
