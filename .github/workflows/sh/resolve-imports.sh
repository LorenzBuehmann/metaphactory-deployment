#!/bin/bash
# Script to resolve OWL import versions via SPARQL queries
# Usage: resolve-imports.sh <imports_json> <is_published>

set -euo pipefail

# Input validation
if [ $# -ne 2 ]; then
    echo "Usage: $0 <imports_json> <is_published>" >&2
    exit 1
fi

IMPORTS="$1"
IS_PUBLISHED="$2"
GROUP_ID="datev.dataintegration.ontologies"
DATE_SUFFIX=$(date -u +%Y%m%d)

# Helper functions
log() { echo "$@" >&2; }
error() { echo "❌ $*" >&2; exit 1; }

# Convert IRI to artifact ID
to_artifact_id() {
    local iri="$1"

    # Remove trailing / or #
    iri=$(echo "$iri" | sed -E 's/[#\/]+$//')

    # Split on / or # and print the second-to-last field
    echo "$iri" \
      | awk -F'[/#]' '{ print tolower($(NF-1)) }'
}


# Build SPARQL query for a given IRI
build_sparql_query() {
    local iri="$1"
    jq -rn --arg iri "$iri" '
        "SELECT ?version ?status WHERE {
            GRAPH <\($iri)/graph> {
                ?s a <http://www.w3.org/2002/07/owl#Ontology> ;
                <http://www.w3.org/2002/07/owl#versionInfo> ?version ;
                <http://purl.org/ontology/bibo/status> ?status .
            }
        }"
    '
}

# Execute SPARQL query
run_sparql_query() {
    local query="$1"
    local auth_header=""

    if [[ -z "${SPARQL_AUTH_TOKEN:-}" ]]; then
        log "GRAPHDB_USER_PASSWORD_HASH is not set"
        return 1
    fi

    log "Running SPARQL query..."
    log "Query: $query"

    curl -sG --data-urlencode "query=$query" \
         -H "Content-Type: application/sparql-query" \
         -H 'Accept: application/sparql-results+json' \
         -H "Authorization: Basic $SPARQL_AUTH_TOKEN" \
        "$SPARQL_ENDPOINT"
}

# Resolve version for a single import IRI
resolve_import_version() {
    local import_iri="$1"
    local artifact_id version status response query group_path latest_snapshot_version

    artifact_id=$(to_artifact_id "$import_iri")
    log "Resolving version for import IRI: $import_iri (artifact_id: $artifact_id)"

    # Query SPARQL endpoint
    query=$(build_sparql_query "$import_iri")
    response=$(run_sparql_query "$query")

    log "SPARQL response: $response"
    version=$(echo "$response" | jq -r '.results.bindings[0].version.value // empty')
    status=$(echo "$response" | jq -r '.results.bindings[0].status.value // empty')
    log "Parsed version: $version"
    log "Parsed status: $status"

    # Handle missing version
    if [[ -z "$version" ]]; then
        log "Could not resolve version for $artifact_id. Using fallback: LATEST"
        echo "LATEST"
        return
    fi

    # Check if dependency is published
    if [[ "$status" == "http://purl.org/spar/pso/published" ]]; then
        echo "$version"
        return
    fi

    # Validate that published ontologies don't depend on unpublished ones
    if [[ "$IS_PUBLISHED" == "true" ]]; then
        error "Ontology is published, but dependency '$artifact_id' is not published (SNAPSHOT)"
    fi

    # Unpublished ontology → return <version>-SNAPSHOT
    log "Ontology not published; using SNAPSHOT version for $artifact_id"
    echo "${version}-SNAPSHOT"
}

# Build Maven dependency block
build_dependency_block() {
    local dependencies="$1"
    if [ -n "$dependencies" ]; then
        printf '<dependencies>\n%s\n</dependencies>\n' "$dependencies"
    else
        echo "<dependencies/>"
    fi
}

# Main processing
log "==> Starting dependency resolution"
log "Imports to resolve: $IMPORTS"

dependencies=""
for iri in $(echo "$IMPORTS" | jq -r '.[]'); do
    log ""
    log "Processing import: $iri"
    artifact_id=$(to_artifact_id "$iri")
    resolved_version=$(resolve_import_version "$iri")
    log "Resolved version for $artifact_id: $resolved_version"

    dependencies+="
    <dependency>
      <groupId>$GROUP_ID</groupId>
      <artifactId>$artifact_id</artifactId>
      <version>$resolved_version</version>
    </dependency>"
done

log ""
log "==> All dependencies resolved"

dependencies_block=$(build_dependency_block "$dependencies")

# Write output
echo "$dependencies_block" > dependencies.xml

log ""
log "==> Dependencies block written to dependencies.xml:"
log "$dependencies_block"
log ""
log "==> Import resolution completed successfully"
