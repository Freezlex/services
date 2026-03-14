# Host Matrix.org homeserver instance

## Synapse instance

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: synapse-secrets
type: Opaque
stringData:
  DB_USERNAME: "<db_username>"
  DB_PASSWORD: "<db_password>"
  DB_NAME: "<db_name>"
  DB_HOST: "<db_host>"
  MX_REGISTRATION_SECRET: "<matrix_registration_secret>"
  MX_MACAROON_SECRET: "<matrix_macaroon_secret>"
  MX_FORM_SECRET: "<matrix_form_secret>"
```
