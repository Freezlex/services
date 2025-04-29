# Traefik

All ressources used can be found on the official Traefik doc here : https://doc.traefik.io/traefik/

To use traefik as a reverse proxy for k8s you should install `Resource Definiton` and `RBAC`

```
# Install Traefik Resource Definitions:
kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v3.3/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml

# Install RBAC for Traefik:
kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v3.3/docs/content/reference/dynamic-configuration/kubernetes-crd-rbac.yml
```

You can then apply all ressources with the `kubectl apply -f <file>.yaml` command.
