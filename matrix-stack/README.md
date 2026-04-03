# Matrix.org

The synapse instance is delegating auth to MAS. We're sharing a database as it reduce ressources needed and also because if Synapse is down MAS is probably useless.

To host a matrix.org homeserver you will need to configure a few things:

## Secret

Create a `01-secrets.yaml` file with the following structure

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: matrix-db-secrets
  namespace: matrix-db-root
type: Opaque
stringData:
  # Root database config
  DB_ROOT_USERNAME: "<matrix_db_username>"
  DB_ROOT_PASSWORD: "<matrix_db_password>"
  DB_ROOT_NAME: "<matrix_db_name>"
---
apiVersion: v1
kind: Secret
metadata:
  name: matrix-secrets
  namespace: matrix
type: Opaque
stringData:
  DB_HOST: "postgres-svc"
  # Matrix specific secrets
  MX_DB_USERNAME: ""
  MX_DB_PASSWORD: ""
  MX_DB_NAME: ""
  MX_REGISTRATION_SECRET: "<matrix_registration_secret>"
  MX_MACAROON_SECRET: "<matrix_macaroon_secret>"
  MX_FORM_SECRET: "<matrix_form_secret>"
  # MAS specific secrets
  MAS_DB_USERNAME: ""
  MAS_DB_PASSWORD: ""
  MAS_DB_NAME: ""
  # Shared secret bewteen MAS and MX
  MX_MAS_EXCHANGE_TOKEN: ""
```
