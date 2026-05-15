To use metallb as a loadbalancer for k8s you should install Resource Definiton and RBAC

# Install Metallb Resource Definitions:
```
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml
```
