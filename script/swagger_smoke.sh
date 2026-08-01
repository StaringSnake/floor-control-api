#!/bin/sh
set -eu

BASE_URL=${BASE_URL:?BASE_URL must be set}
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d)

cleanup() {
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

check_asset() {
  path=$1
  expected_type=$2
  headers="$TEMP_DIR/headers"
  body="$TEMP_DIR/body"

  curl --fail --silent --show-error --dump-header "$headers" --output "$body" "$BASE_URL$path"
  test -s "$body"
  normalized_headers=$(tr '[:upper:]' '[:lower:]' <"$headers" | tr -d '\r')
  case "$normalized_headers" in
    *"content-type: $expected_type"*) ;;
    *)
      printf 'unexpected content type for %s\n' "$path" >&2
      exit 1
      ;;
  esac
  case "$normalized_headers" in
    *"cache-control: no-cache"*) ;;
    *)
      printf 'unexpected cache policy for %s\n' "$path" >&2
      exit 1
      ;;
  esac
}

curl --fail --silent --show-error "$BASE_URL/swagger" >"$TEMP_DIR/swagger.html"
case "$(cat "$TEMP_DIR/swagger.html")" in
  *'url: "/openapi.yaml"'*) ;;
  *)
    printf 'Swagger page does not reference the relative OpenAPI route\n' >&2
    exit 1
    ;;
esac
case "$(cat "$TEMP_DIR/swagger.html")" in
  *'validatorUrl: null'*) ;;
  *)
    printf 'Swagger page does not disable the remote validator\n' >&2
    exit 1
    ;;
esac
case "$(cat "$TEMP_DIR/swagger.html")" in
  *http://*|*https://*|*validator.swagger.io*)
    printf 'Swagger page contains an external URL\n' >&2
    exit 1
    ;;
esac

check_asset /swagger/swagger-ui-5.11.10.css 'text/css'
check_asset /swagger/swagger-ui-5.11.10-bundle.js 'text/javascript'
check_asset /swagger/swagger-ui-5.11.10-standalone-preset.js 'text/javascript'
check_asset /swagger/Swagger-UI-LICENSE.txt 'text/plain'

curl --fail --silent --show-error "$BASE_URL/openapi.yaml" >"$TEMP_DIR/openapi.yaml"
cmp -s "$ROOT_DIR/OpenApiSpec.yaml" "$TEMP_DIR/openapi.yaml"
case "$(cat "$TEMP_DIR/openapi.yaml")" in
  *'url: /'*) ;;
  *)
    printf 'OpenAPI contract does not use a relative server URL\n' >&2
    exit 1
    ;;
esac

curl --fail --silent --show-error \
  --header 'Content-Type: application/json' \
  --data '{"userId":"swagger-smoke-user","priority":1}' \
  "$BASE_URL/groups/swagger-smoke-group/floor" >"$TEMP_DIR/api-response"
test -s "$TEMP_DIR/api-response"

printf '%s\n' 'Swagger production smoke passed'
