#!/bin/bash
# Script to process TTL files: convert to N-Triples and extract metadata
# Usage: process-ttl.sh <ttl_file_path>

set -euo pipefail

# Input validation
if [ $# -ne 1 ]; then
    echo "Usage: $0 <ttl_file_path>" >&2
    exit 1
fi

TTL_PATH="$1"
ONTOLOGY_DIR=$(dirname "$TTL_PATH")
NT_FILE="temp.nt"

echo "==> Processing TTL file: $TTL_PATH"

# Convert TTL to N-Triples
echo "Converting TTL to N-Triples..."
rapper -i turtle -o ntriples "$TTL_PATH" > "$NT_FILE"

echo "----- N-Triples Output -----"
cat "$NT_FILE"
echo "----- End Output -----"


# Constants
RDF_TYPE="<http://www.w3.org/1999/02/22-rdf-syntax-ns#type>"
OWL_ONTOLOGY="<http://www.w3.org/2002/07/owl#Ontology>"
SKOS_CONCEPTSCHEME="<http://www.w3.org/2004/02/skos/core#ConceptScheme>"


# Detect vocabulary type & extract "root" IRI
echo "Detecting ontology/vocabulary root IRI..."
VOCAB_TYPE="unknown"

ONTOLOGY_IRI=$(
  awk -v t="$RDF_TYPE" -v o="$OWL_ONTOLOGY" '
    $2==t && $3==o {gsub(/[<>]/,"",$1); print $1; exit}
  ' "$NT_FILE"
)

if [ -n "${ONTOLOGY_IRI:-}" ]; then
  VOCAB_TYPE="owl"
else
  ONTOLOGY_IRI=$(
    awk -v t="$RDF_TYPE" -v o="$SKOS_CONCEPTSCHEME" '
      $2==t && $3==o {gsub(/[<>]/,"",$1); print $1; exit}
    ' "$NT_FILE"
  )
  if [ -n "${ONTOLOGY_IRI:-}" ]; then
    VOCAB_TYPE="skos"
  fi
fi

echo "Detected type: $VOCAB_TYPE"
echo "Root IRI: $ONTOLOGY_IRI"


# Extract version and title
echo "Extracting version and title..."
VERSION_ID=$(grep '<http://www.w3.org/2002/07/owl#versionInfo>' "$NT_FILE" | grep -o '"[^"]*"' | head -1 | tr -d '"')
ONTOLOGY_NAME=$(grep '<http://purl.org/dc/terms/title>' "$NT_FILE" | grep -o '"[^"]*"' | head -1 | tr -d '"')

# Rename N-Triples file
NEW_NT_FILE="${ONTOLOGY_NAME}-${VERSION_ID}.nt"
mv "$NT_FILE" "$NEW_NT_FILE"
NT_FILE="$NEW_NT_FILE"

# Check publication status
echo "Checking publication status..."
if grep -q "<http://purl.org/ontology/bibo/status> <http://purl.org/spar/pso/published>" "$NT_FILE"; then
    IS_PUBLISHED="true"
    echo "Ontology is PUBLISHED - using exact version"
else
    IS_PUBLISHED="false"
    echo "Ontology is NOT published - using SNAPSHOT version"
fi

# Extract OWL imports
#echo "Extracting OWL imports..."
#IMPORTS=$(awk '/<http:\/\/www\.w3\.org\/2002\/07\/owl#imports>/{
#     match($0, /<[^>]*>[[:space:]]+<[^>]*>[[:space:]]+<[^>]*>/)
#     iri = substr($0, RSTART, RLENGTH)
#     gsub(/.*<|>.*/, "", iri)
#     print iri
# }' "$NT_FILE" | jq -R -s -c 'split("\n") | map(select(length > 0))')


# Extract OWL imports (only for OWL; SKOS gets [])
echo "Extracting OWL imports..."
if [ "$VOCAB_TYPE" = "owl" ]; then
  IMPORTS=$(
    awk -v p="$OWL_IMPORTS" '
      $2==p {gsub(/[<>]/,"",$3); print $3}
    ' "$NT_FILE" | jq -R -s -c 'split("\n") | map(select(length > 0))'
  )
else
  IMPORTS='[]'
fi

# Extract Git metadata
echo "Extracting Git metadata..."
COMMITTER_NAME=$(git log -1 --pretty=format:'%an' -- "$TTL_PATH")
COMMITTER_EMAIL=$(git log -1 --pretty=format:'%ae' -- "$TTL_PATH")
COMMIT_DATE=$(git log -1 --pretty=format:'%ai' -- "$TTL_PATH")
COMMIT_HASH=$(git log -1 --pretty=format:'%h' -- "$TTL_PATH")

# Output results to GitHub Actions
echo "==> Writing outputs to GITHUB_OUTPUT"
{
    echo "ttl=$NT_FILE"
    echo "dir=$ONTOLOGY_DIR"
    echo "ontology_iri=$ONTOLOGY_IRI"
    echo "ontology_name=$ONTOLOGY_NAME"
    echo "version_id=$VERSION_ID"
    echo "imports=$IMPORTS"
    echo "is_published=$IS_PUBLISHED"
    echo "committer_name=$COMMITTER_NAME"
    echo "committer_email=$COMMITTER_EMAIL"
    echo "commit_date=$COMMIT_DATE"
    echo "commit_hash=$COMMIT_HASH"
} >> "$GITHUB_OUTPUT"

# Also print to console for visibility
echo "
==> Extracted Metadata:
  - N-Triples file: $NT_FILE
  - Directory: $ONTOLOGY_DIR
  - Ontology IRI: $ONTOLOGY_IRI
  - Ontology name: $ONTOLOGY_NAME
  - Version: $VERSION_ID
  - Published: $IS_PUBLISHED
  - Imports: $IMPORTS
  - Committer: $COMMITTER_NAME <$COMMITTER_EMAIL>
  - Commit: $COMMIT_HASH ($COMMIT_DATE)
"

echo "==> TTL processing completed successfully"