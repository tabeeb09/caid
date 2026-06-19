path "kv/data/website/prod" {
  capabilities = ["read"]
}

path "kv/data/rustfs/prod" {
  capabilities = ["read"]
}

path "kv/data/oauth2-proxy/prod" {
  capabilities = ["read"]
}

path "kv/data/keycloak/prod" {
  capabilities = ["read"]
}

path "kv/data/print/prod" {
  capabilities = ["read", "update"]
}

path "kv/data/caid/config-requests" {
  capabilities = ["read", "update"]
}

path "kv/data/caid/config-values/*" {
  capabilities = ["read", "update"]
}
