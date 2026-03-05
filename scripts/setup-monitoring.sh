#!/bin/bash

CLIENT_SECRET=""

# Read parameter input
while [[ "$#" -gt 0 ]]; do
    case $1 in
      --client-secret) CLIENT_SECRET="$2"; shift ;;
      *) echo "Unbekanntes Argument: $1"; exit 1 ;;
    esac
    shift
done

# Check if paramter was given
# If not ask the user to input it
if [[ -z "$CLIENT_SECRET" ]]; then
    echo -e "Pls enter keycloak client secret for Grafana:"
    read -s -r CLIENT_SECRET
fi

# Create the new secret or replace the old one
kubectl create secret generic grafana-keycloak-secret \
    --from-literal=client-secret="$CLIENT_SECRET" \
    -n monitoring \
    --dry-run=client -o yaml | kubectl apply -f -

echo "================================="
echo "grafana-keycloak-secret created  "
echo "================================="
