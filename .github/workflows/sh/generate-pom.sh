#!/bin/bash
# Script to generate Maven POM file from template
# Usage: generate-pom.sh <ontology_dir> <nt_file> <ontology_iri> <ontology_name> <maven_version> <committer_name> <committer_email> <commit_date> <commit_hash>

set -euo pipefail

# Input validation
if [ $# -ne 9 ]; then
    echo "Usage: $0 <ontology_dir> <nt_file> <ontology_iri> <ontology_name> <maven_version> <committer_name> <committer_email> <commit_date> <commit_hash>" >&2
    exit 1
fi

ONTOLOGY_DIR="$1"
NT_FILE="$2"
ONTOLOGY_IRI="$3"
ONTOLOGY_NAME="$4"
MAVEN_VERSION="$5"
COMMITTER_NAME="$6"
COMMITTER_EMAIL="$7"
COMMIT_DATE="$8"
COMMIT_HASH="$9"

echo "==> Preparing Maven project structure"

# Create resources directory
mkdir -p "$ONTOLOGY_DIR/src/main/resources"

# Copy N-Triples file to resources
cp "$NT_FILE" "$ONTOLOGY_DIR/src/main/resources/"
echo "Copied $NT_FILE to resources"

# Generate the group ID here
# we have to use anything after the meta segment, to be able to distinguish between
# different ontologies with the same name but in different domains
BASE_GROUP_ID="datev.dataintegration.ontologies"

group_id=$(
  echo "$ONTOLOGY_IRI" \
    | sed -E 's#[/#]+$##' \
    | awk -F'[/#]' '
        {
          # Find "meta" segment and print segments after it up to (but excluding) artifact and version.
          # Layout: ... / meta / <group...> / <artifact> / <version>
          meta_idx = 0
          for (i=1; i<=NF; i++) if ($i == "meta") { meta_idx = i; break }

          if (meta_idx == 0) {
            # no "meta" segment -> print nothing (handled later)
            exit
          }

          # group segments are from meta_idx+1 to NF-2
          out = ""
          for (i = meta_idx+1; i <= NF-2; i++) {
            if ($i == "") continue
            if (out == "") out = $i
            else out = out "/" $i
          }
          print out
        }
      ' \
    | tr '/' '.' \
    | tr '[:upper:]' '[:lower:]'
)

if [[ -z "${group_id:-}" ]]; then
  echo "❌ Could not derive groupId from ONTOLOGY_IRI='$ONTOLOGY_IRI' (expected '/meta/.../<artifact>/<version>')" >&2
  exit 1
fi

GROUP_ID="${BASE_GROUP_ID}.${group_id}"



# Generate artifact ID
artifact_id=$(
        echo "$ONTOLOGY_IRI" \
        | sed -E 's#[/#]+$##' \
        | awk -F'[/#]' '{print $(NF-1)}' \
        | sed -E 's/([a-z0-9])([A-Z])/\1-\2/g' \
        | tr '_' '-' \
        | tr '[:upper:]' '[:lower:]'
    )


# Generate POM from template
echo "Generating POM file from template..."
sed -e "s/__GROUP_ID__/$group_id/g" \
    -e "s/__ARTIFACT_ID__/$artifact_id/g" \
    -e "s/__VERSION_ID__/$MAVEN_VERSION/g" \
    -e "s/__COMMITTER_NAME__/$COMMITTER_NAME/g" \
    -e "s/__COMMITTER_EMAIL__/$COMMITTER_EMAIL/g" \
    -e "s/__COMMIT_DATE__/$COMMIT_DATE/g" \
    -e "s/__COMMIT_HASH__/$COMMIT_HASH/g" \
    ./pom-template.xml > "$ONTOLOGY_DIR/pom.xml.in"

# Insert dependencies block from file
awk '
    /__OWL_IMPORT_DEPENDENCIES__/ {
        while ((getline line < "dependencies.xml") > 0) print line
        next
    }
    { print }
' "$ONTOLOGY_DIR/pom.xml.in" > "$ONTOLOGY_DIR/pom.xml"

# Display generated POM
echo ""
echo "----- Generated pom.xml -----"
cat "$ONTOLOGY_DIR/pom.xml"
echo "----- End pom.xml -----"
echo ""

# List resources
echo "Resources in $ONTOLOGY_DIR/src/main/resources/:"
ls -lh "$ONTOLOGY_DIR/src/main/resources/"

echo ""
echo "==> Maven project preparation completed successfully"