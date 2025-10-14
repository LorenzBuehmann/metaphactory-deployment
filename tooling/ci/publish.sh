#!/usr/bin/env bash
set -euo pipefail

# ====== CONFIG ======
: "${GROUP_ID:=com.example.ont}"
: "${ARTIFACTORY_ID:=local-repo}"         # matches <server><id> in ~/.m2/settings.xml
: "${RELEASE_REPO_URL:=file://${PWD}/local-mvn-repo}"
: "${SNAPSHOT_REPO_URL:=file://${PWD}/local-mvn-repo}"
: "${OUT_MANIFEST:=target/published.txt}"
: "${ALLOW_BASE_IRI:=false}"              # allow unversioned imports?
: "${IMPORT_FALLBACK_VERSION:=}"          # used only if ALLOW_BASE_IRI=true
: "${CLASSIFIER:=ontology}"
: "${PACKAGING:=jar}"                     # publish as Turtle
: "${RAPPER:=rapper}"                     # CLI from raptor2-utils
: "${SNAPSHOT_REPO_ID:=file}"
: "${RELEASE_REPO_ID:=file}"

mkdir -p "$(dirname "$OUT_MANIFEST")"
: > "$OUT_MANIFEST"

# ====== Helpers ======

find_ontology_file() {
  # NAME/VERSION/NAME.ttl
  local f
  f="$(find . -maxdepth 3 -path "./config" -prune -o -type f -name '*.ttl' -print | grep -E './[^/]+/[^/]+/[^/]+\.ttl$' | head -n1 || true)"
  echo "$f"
}

derive_name_and_version_from_path() {
  local path="$1"
  local filename name version
  filename="$(basename "$path")"
  name="${filename%.ttl}"
  version="$(basename "$(dirname "$path")")"
  echo "$name|$version"
}

# SemVer-ish (also accepts dotted date-like versions)
looks_like_version() {
  [[ "$1" =~ ^[0-9]+([.-][0-9A-Za-z]+)*$ ]]
}

# Parse TTL -> N-Triples (no fetching). rapper expands prefixes for us.
to_nt() {
  # -i turtle input, -o ntriples output, -q quiet
  "$RAPPER" -i turtle -o ntriples -q "$1" || {
    echo "Syntax error parsing $1 (rapper)" >&2
    exit 2
  }
}

extract_imports() {
  local ttl="$1"
  to_nt "$ttl" \
    | awk '$2=="<http://www.w3.org/2002/07/owl#imports>" { gsub(/[<>]/,"",$3); print $3 }' \
    | sort -u
}

extract_version_info() {
  local ttl="$1"
  local versionInfo versionIRI
  versionInfo="$(to_nt "$ttl" | awk '$2=="<http://www.w3.org/2002/07/owl#versionInfo>" { for(i=3;i<=NF;i++) printf "%s ",$i; print"" }' | sed 's/ \.$//' | sed 's/^"//; s/"$//' | head -n1 || true)"
  versionIRI="$(to_nt "$ttl" | awk '$2=="<http://www.w3.org/2002/07/owl#versionIRI>" { gsub(/[<>]/,"",$3); print $3 }' | head -n1 || true)"
  echo "${versionInfo}|${versionIRI}"
}

# IRI -> artifactId|version
iri_to_artifact_and_version() {
  local iri="$1"
  # strip fragment / query
  iri="${iri%%\#*}"; iri="${iri%%\?*}"
  # cut to path after scheme://host/
  local path="${iri#*://}"; path="${path#*/}"
  IFS='/' read -r -a seg <<< "$path"
  local n=${#seg[@]}
  if (( n==0 )); then echo "ERROR|"; return; fi
  local last="${seg[$((n-1))]}"
  if looks_like_version "$last"; then
    local art="${seg[$((n-2))]}"
    echo "$art|$last"
  else
    if [[ "$ALLOW_BASE_IRI" == "true" && -n "$IMPORT_FALLBACK_VERSION" ]]; then
      echo "${last}|${IMPORT_FALLBACK_VERSION}"
    else
      echo "BASE_NO_VERSION|"
    fi
  fi
}

generate_pom() {
  local groupId="$1" artifactId="$2" version="$3" outfile="$4"; shift 4
  local deps=("$@")
  cat > "$outfile" <<EOF
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>${groupId}</groupId>
  <artifactId>${artifactId}</artifactId>
  <version>${version}</version>
  <packaging>pom</packaging>
  <name>${artifactId} ontology</name>
  <dependencies>
EOF
  for gav in "${deps[@]}"; do
    IFS=: read -r g a v <<<"$gav"
    cat >> "$outfile" <<EOD
    <dependency>
      <groupId>${g}</groupId>
      <artifactId>${a}</artifactId>
      <version>${v}</version>
      <type>${PACKAGING}</type>
    </dependency>
EOD
  done
  cat >> "$outfile" <<'EOF'
  </dependencies>
</project>
EOF
}

# Catalog maps exact import IRIs -> deps/<artifact>.ttl and self versionIRI -> self.ttl
generate_catalog() {
  local self_name="$1" self_versioniri="$2" deps_dir="$3" out="$4"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<catalog xmlns="urn:oasis:names:tc:entity:xmlns:xml:catalog" prefer="public">'
    if [[ -n "$self_versioniri" ]]; then
      echo "  <uri name=\"$self_versioniri\" uri=\"file:${self_name}.ttl\"/>"
    fi
    if [[ -d "$deps_dir" ]]; then
      # For each fetched dep, we also need its IRI(s). We’ll map only the exact import IRIs we saw.
      # The caller will pass a list of "IRI|artifact" lines in ${deps_dir}/_iri_map.txt.
      if [[ -f "$deps_dir/_iri_map.txt" ]]; then
        while IFS='|' read -r importIri art; do
          echo "  <uri name=\"$importIri\" uri=\"file:${deps_dir}/${art}.ttl\"/>"
        done < "$deps_dir/_iri_map.txt"
      fi
    fi
    echo '</catalog>'
  } > "$out"
}

choose_repo_url() {
  [[ "$1" == *-SNAPSHOT ]] && echo "$SNAPSHOT_REPO_URL" || echo "$RELEASE_REPO_URL"
}

# ---- Generic Maven fetch + manual copy (no central verification) ----

# maven_fetch_to() resolves a single artifact into a *clean local repo dir*
# and copies the resolved file into an output directory with a stable name.
# GAV inputs:
#   $1 = groupId
#   $2 = artifactId
#   $3 = version        (supports releases *and* -SNAPSHOT)
#   $4 = packaging      (e.g., ttl, owl, jar)
#   $5 = classifier     (may be empty "")
#   $6 = remote repo URL (e.g., file:///abs/path/to/local-mvn-repo or https://.../artifactory/...)
#   $7 = local repo dir for this step (e.g., "$(pwd)/.m2-tmp")
#   $8 = output dir to place the file (e.g., "target/deps")
maven_fetch_to() {
  local G="$1" A="$2" V="$3" P="$4" C="$5" REMOTE="$6" LREPO="$7" OUTDIR="$8"
  local ART="${G}:${A}:${V}:${P}${C:+:${C}}"

  # 1) Fetch into isolated local repo (forces refresh; uses only the REMOTE we pass here)
  mvn -U -q -Dmaven.repo.local="$LREPO" \
    org.apache.maven.plugins:maven-dependency-plugin:3.6.1:get \
    -Dartifact="$ART" \
    -DremoteRepositories="only::default::${REMOTE}" \
    -Dtransitive=false

  # 2) Compute the actual file path in the local repo and copy it out
  local GP="${G//.//}"
  local VDIR="${LREPO}/${GP}/${A}/${V}"
  local FILE_BASENAME
  if [[ "$V" == *-SNAPSHOT ]]; then
    # Timestamped snapshot: pick the newest matching file
    if [[ -n "$C" ]]; then
      FILE_BASENAME="$(ls -t "${VDIR}/${A}-"*"-${C}.${P}" 2>/dev/null | head -n1)"
    else
      FILE_BASENAME="$(ls -t "${VDIR}/${A}-"*".${P}" 2>/dev/null | head -n1)"
    fi
  else
    # Release: deterministic filename
    if [[ -n "$C" ]]; then
      FILE_BASENAME="${VDIR}/${A}-${V}-${C}.${P}"
    else
      FILE_BASENAME="${VDIR}/${A}-${V}.${P}"
    fi
  fi

  [[ -n "$FILE_BASENAME" && -f "$FILE_BASENAME" ]] || {
    echo "ERROR: resolved artifact file not found for $ART in $VDIR" >&2
    return 1
  }

  mkdir -p "$OUTDIR"
  cp -f "$FILE_BASENAME" "${OUTDIR}/${A}.${P}"
}

# Fetch import JARs into a job-scoped local repo, then extract the embedded TTL to target/deps/<artifactId>.ttl
maven_fetch_jar_and_extract_ttl() {
  local G="$1" A="$2" V="$3" REMOTE_SPEC="$4" LREPO="$5" OUTDIR="$6"
  local ART="${G}:${A}:${V}:jar"

  # resolve into isolated local repo (auth via repo id in REMOTE_SPEC)
  mvn -q -Dmaven.repo.local="$LREPO" \
    org.apache.maven.plugins:maven-dependency-plugin:3.6.1:get \
    -Dartifact="$ART" \
    -DremoteRepositories="$REMOTE_SPEC" \
    -Dtransitive=false

  # compute jar path
  local GP VDIR JAR
  GP="${G//.//}" 
  VDIR="${LREPO}/${GP}/${A}/${V}"
  if [[ "$V" == *-SNAPSHOT ]]; then
    JAR="$(ls -t "${VDIR}/${A}-"*.jar 2>/dev/null | head -n1)"
  else
    JAR="${VDIR}/${A}-${V}.jar"
  fi
  [[ -f "$JAR" ]] || { echo "Jar not found for $ART in $VDIR"; return 1; }

  # extract TTL from META-INF/ontology/<artifactId>.ttl
  mkdir -p "$OUTDIR"
  if unzip -p "$JAR" "META-INF/ontology/${A}.ttl" > "${OUTDIR}/${A}.ttl" 2>/dev/null; then
    return 0
  fi

  echo "ERROR: ${A}.ttl not found inside $JAR (expected META-INF/ontology/${A}.ttl)"; return 1
}

remote_for() {
  local v="$1"
  if [[ "$v" == *-SNAPSHOT ]]; then
    echo "${SNAPSHOT_REPO_ID}::default::${SNAPSHOT_REPO_URL}"
  else
    echo "${RELEASE_REPO_ID}::default::${RELEASE_REPO_URL}"
  fi
}

# ====== Publish one ontology ======
publish_one() {
  local ttl="$1"

  IFS='|' read -r name version <<<"$(derive_name_and_version_from_path "$ttl")"

  # 1) Extract imports (pure local parse)
  mapfile -t import_iris < <(extract_imports "$ttl")

  # 2) Derive GAVs from IRIs
  deps=()
  mkdir -p target/deps
  : > target/deps/_iri_map.txt
  for iri in "${import_iris[@]}"; do
    IFS='|' read -r art ver <<<"$(iri_to_artifact_and_version "$iri")"
    if [[ "$art" == "BASE_NO_VERSION" && -z "$ver" ]]; then
      echo "ERROR: Import IRI has no version (and ALLOW_BASE_IRI=false): $iri" >&2
      exit 3
    fi
    if [[ "$art" == "ERROR" ]]; then
      echo "ERROR: Could not parse import IRI: $iri" >&2
      exit 3
    fi
    deps+=("${GROUP_ID}:${art}:${ver}")
    echo "${iri}|${art}" >> target/deps/_iri_map.txt
  done

# Prefetch dependency files into target/deps (offline-friendly, no central verification)
DEPS_OUT="target/deps"
JOB_LREPO="$(pwd)/.m2-tmp"   # job-scoped local repo to avoid stale cache
rm -rf "$JOB_LREPO"
mkdir -p "$DEPS_OUT"

#for gav in "${deps[@]}"; do
#  IFS=: read -r g a v <<<"$gav"
#  maven_fetch_to "$g" "$a" "$v" "$PACKAGING" "$CLASSIFIER" \
#                 "$RELEASE_REPO_URL" "$JOB_LREPO" "$DEPS_OUT" \
#    || { echo "Failed to fetch $gav from $RELEASE_REPO_URL" >&2; exit 4; }
#  [[ -f "${DEPS_OUT}/${a}.${PACKAGING}" ]] || {
#    echo "Missing ${DEPS_OUT}/${a}.${PACKAGING} after fetch for $gav" >&2; exit 4; }
#done

for gav in "${deps[@]}"; do
  IFS=: read -r g a v <<<"$gav"
  maven_fetch_jar_and_extract_ttl "$g" "$a" "$v" "$(remote_for "$v")" "$JOB_LREPO" "$DEPS_OUT" \
    || { echo "Failed to extract TTL from JAR for $gav"; exit 4; }
done

  # 4) Lightweight validation: syntax only (does NOT load imports)
  "$RAPPER" -i turtle -c -q "$ttl"

  # 5) Version IRIs (optional, for catalog self-entry)
  IFS='|' read -r versionInfo versionIRI <<<"$(extract_version_info "$ttl")"

  # 6) Generate catalog that maps exact import IRIs -> local dep files
  generate_catalog "$name" "$versionIRI" "target/deps" "target/catalog-v001.xml"

  # 7) Generate POM with dependency list
  tmp_pom="$(mktemp).xml"
  generate_pom "$GROUP_ID" "$name" "$version" "$tmp_pom" "${deps[@]}"
  
# stage jar contents
STAGE="target/jar-stage"
mkdir -p "${STAGE}/META-INF/ontology"

# put the ontology into the jar at a stable classpath location
cp "$ttl" "${STAGE}/META-INF/ontology/${name}.ttl"

# (optional) also embed the catalog
if [[ -f target/catalog-v001.xml ]]; then
  cp target/catalog-v001.xml "${STAGE}/META-INF/ontology/catalog.xml"
fi

# create the jar
JAR_PATH="target/${name}-${version}.jar"
jar -cf "${JAR_PATH}" -C "${STAGE}" .


# 8) Deploy ontology JAR (main) + attach raw TTL and catalog as sidecars
repoUrl="$(choose_repo_url "$version")"

mvn -B org.apache.maven.plugins:maven-deploy-plugin:3.1.2:deploy-file \
  -Durl="$repoUrl" \
  -DrepositoryId="$ARTIFACTORY_ID" \
  -Dfile="${JAR_PATH}" \
  -DgroupId="$GROUP_ID" \
  -DartifactId="$name" \
  -Dversion="$version" \
  -Dpackaging=jar \
  -DgeneratePom=false \
  -DpomFile="$tmp_pom" \
  -Dfiles="$ttl,target/catalog-v001.xml" \
  -Dclassifiers="ontology,catalog" \
  -Dtypes="ttl,xml"

  echo "${GROUP_ID}:${name}:${version}" >> "$OUT_MANIFEST"
}

main() {
  command -v "$RAPPER" >/dev/null || { echo "rapper not found. Install raptor2-utils." >&2; exit 1; }
  ttl="$(find_ontology_file)"
  if [[ -z "$ttl" ]]; then
    echo "No ontology found at NAME/VERSION/NAME.ttl" >&2
    exit 0
  fi
  publish_one "$ttl"
}
main "$@"
