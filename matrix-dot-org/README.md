# Matrix.org

To host a matrix.org homeserver you will need to configure a few things:

## Secret

Create a `01-secrets.yaml` file with the following structure

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: matrix-secrets
  namespace: matrix-dot-org
type: Opaque
stringData:
  DB_USERNAME: "<matrix_db_username>"
  DB_PASSWORD: "<matrix_db_password>"
  DB_NAME: "<matrix_db_name>"
  DB_HOST: "postgres-svc"
  MX_REGISTRATION_SECRET: "<matrix_registration_secret>"
  MX_MACAROON_SECRET: "<matrix_macaroon_secret>"
  MX_FORM_SECRET: "<matrix_form_secret>"
```
