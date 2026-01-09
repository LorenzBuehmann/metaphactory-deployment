#!/bin/bash
# Resolve referenced SKOS vocabularies via SPARQL (single query)
# Usage: resolve-referenced-vocabs.sh <ontology_iri> <is_published>
#
# Produces: vocab-dependencies.xml  (Maven <dependencies>...</dependencies>)

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <ontology_iri> <is_published>" >&2
  exit 1
fi

ONTOLOGY_IRI="$1"
IS_PUBLISHED="$2"
GROUP_ID="datev.dataintegration.ontologies"

log() { echo "$@" >&2; }
error() { echo "❌ $*" >&2; exit 1; }

to_artifact_id() {
  local iri="$1"
  iri=$(echo "$iri" | sed -E 's/[#\/]+$//')
  echo "$iri" | awk -F'[/#]' '{ print tolower($(NF-1)) }'
}

run_sparql_query() {
  local query="$1"

  if [[ -z "${SPARQL_AUTH_TOKEN:-}" ]]; then
    error "SPARQL_AUTH_TOKEN is not set"
  fi
  if [[ -z "${SPARQL_ENDPOINT:-}" ]]; then
    error "SPARQL_ENDPOINT is not set"
  fi

  local response
  if ! response=$(
    curl -sS -G \
      --fail-with-body \
      --connect-timeout 5 \
      --max-time 30 \
      --data-urlencode "query=$query" \
      -H "Content-Type: application/sparql-query" \
      -H "Accept: application/sparql-results+json" \
      -H "Authorization: Basic $SPARQL_AUTH_TOKEN" \
      "$SPARQL_ENDPOINT"
  ); then
    error "SPARQL connection/query failed (endpoint: $SPARQL_ENDPOINT)"
  fi

  if ! echo "$response" | jq -e . >/dev/null 2>&1; then
    log "Raw SPARQL response (non-JSON):"
    log "$response"
    error "SPARQL response is not valid JSON"
  fi

  echo "$response"
}

build_referenced_vocab_query() {
  local graph_iri="${ONTOLOGY_IRI}/graph"

  jq -rn --arg g "$graph_iri" '
"PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX owl:  <http://www.w3.org/2002/07/owl#>
PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
PREFIX sh:   <http://www.w3.org/ns/shacl#>
PREFIX bibo: <http://purl.org/ontology/bibo/>

SELECT DISTINCT ?vocab ?name ?version ?status WHERE {
  GRAPH <\($g)> {
    {
      [ sh:class skos:ConceptScheme ;
        sh:path  skos:inScheme ;
        sh:hasValue ?vocab
      ]
    } UNION {
      [ sh:class skos:Concept ;
        sh:path  ?p ;
        sh:hasValue ?term
      ]
      GRAPH ?vocab_graph {
        ?term  a skos:Concept .
        ?vocab a skos:ConceptScheme .
      }
    } UNION {
      [ sh:class skos:Collection ;
        sh:path  ?p ;
        sh:hasValue ?coll
      ]
      GRAPH ?vocab_graph {
        ?coll  a skos:Collection .
        ?vocab a skos:ConceptScheme .
      }
    }
  }

  ?vocab bibo:status  ?status ;
         owl:versionInfo ?version ;
         rdfs:label ?name .
}"
  '
}

build_dependency_block() {
  local dependencies="$1"
  if [ -n "$dependencies" ]; then
    printf '<dependencies>\n%s\n</dependencies>\n' "$dependencies"
  else
    echo "<dependencies/>"
  fi
}

# ---- Main ----
log "==> Resolving referenced vocabularies for: $ONTOLOGY_IRI"

query=$(build_referenced_vocab_query)
response=$(run_sparql_query "$query")

# If none found: treat as OK (no referenced vocabs).
count=$(echo "$response" | jq -r '.results.bindings | length')
if [[ "$count" == "0" ]]; then
  log "No referenced vocabularies found."
  echo "<dependencies/>" > vocab-dependencies.xml
  exit 0
fi

# Fail fast if any row is missing required fields
missing=$(echo "$response" | jq -r '
  [.results.bindings[]
    | select((.vocab.value? == null) or (.version.value? == null) or (.status.value? == null))
  ] | length
')
if [[ "$missing" != "0" ]]; then
  log "SPARQL response:"
  log "$response"
  error "Referenced vocabulary rows missing vocab/version/status (cannot build dependencies)."
fi

# Build dependencies (dedupe by vocab IRI)
deps=""
echo "$response" \
  | jq -r '.results.bindings[] | [.vocab.value, .version.value, .status.value] | @tsv' \
  | sort -u \
  | while IFS=$'\t' read -r vocab version status; do
      artifact_id=$(to_artifact_id "$vocab")

      if [[ "$status" != "http://purl.org/spar/pso/published" ]]; then
        if [[ "$IS_PUBLISHED" == "true" ]]; then
          error "Ontology is published, but referenced vocabulary '$artifact_id' is not published (SNAPSHOT)"
        fi
        version="${version}-SNAPSHOT"
      fi

      deps+="
    <dependency>
      <groupId>$GROUP_ID</groupId>
      <artifactId>$artifact_id</artifactId>
      <version>$version</version>
    </dependency>"
      echo "$deps"
    done > /tmp/_vocab_deps_fragment.txt

# The loop runs in a subshell (pipe), so read back the fragment
deps="$(cat /tmp/_vocab_deps_fragment.txt || true)"
rm -f /tmp/_vocab_deps_fragment.txt

deps_block=$(build_dependency_block "$deps")
echo "$deps_block" > vocab-dependencies.xml

log "==> Written vocab dependencies to vocab-dependencies.xml"
log "$deps_block"
