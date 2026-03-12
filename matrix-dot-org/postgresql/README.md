# Deploy a Matrix.org databse instance

## PostgreSql
Secret should be provided to the container through a `01-secret.yaml` file.
Bellow an example of what's need :
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: matrix-db-secret
  namespace: matrix-dot-org
data:
  username: <some-base64-username>
  password: <some-base64-password>
  database: <some-base64-db-name>
```

Then you can run `kubectl apply -f <.yaml>` after making sure that the `matrix-dot-org` namespace already exist.
